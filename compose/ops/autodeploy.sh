#!/usr/bin/env bash
# 학교 서버 자동 배포(끌어오기 방식): GHCR에 새 이미지가 올라왔으면 그 서비스만 바꾸고,
# 새 버전이 실제로 응답하는지 확인한 뒤, 안 되면 직전 이미지로 되돌린다.
# GitHub에 서버 접속 키를 두지 않는다. 서버가 밖으로 나가서 받아 오기만 한다(Argo CD와 같은 방향).
#
#   cron 예: */3 * * * * bash ~/gitops/compose/ops/autodeploy.sh >> ~/trace-backups/deploy.log 2>&1
#   autodeploy.sh            한 번 확인하고 바뀐 서비스만 배포
#   autodeploy.sh status     서비스별로 지금 도는 버전과 받아 둔 최신 버전
#   autodeploy.sh pause      자동 배포 멈춤(촬영·시연 전에). 사유를 뒤에 적을 수 있다
#   autodeploy.sh resume     다시 켬
#   autodeploy.sh roll <서비스>          같은 이미지로 무중단 교체를 한 번 해 본다(시험용)
#   autodeploy.sh probe <서비스> [초]    그 서비스의 ping을 0.2초마다 불러 성공·실패 수를 센다(교체 중 끊김 측정)
#
# 한 서비스마다: 그 서비스의 새 이미지 받기 → 지금 컨테이너와 이미지가 다르면 교체 → 최대 TRACE_DEPLOY_WAIT초 동안
#   ① 컨테이너가 죽거나 다시 켜지지 않았는지 ② ping이 응답하는지 ③ 응답의 커밋이 새 이미지의 커밋인지 확인
#   → 실패하면 직전 이미지로 되돌리고 그 이미지를 '실패'로 적어 다음 이미지가 올 때까지 다시 시도하지 않는다.
# 무중단 교체(TRACE_DEPLOY_ROLLING의 서비스): 새 컨테이너를 옆에 하나 더 띄워 준비되면 옛 컨테이너를 내린다.
#   준비되지 않으면 새 컨테이너만 지우므로 서비스는 끊기지 않는다. 부르는 쪽이 새 IP를 찾는 방법:
#   gateway → web nginx를 reload, 서버들 → gateway가 이름을 5초만 기억하고 연결 실패를 다시 보냄(gateway 이미지 표시로 확인).
#   web은 호스트 포트를 쥐고 있어 둘을 띄울 수 없으므로 예전처럼 다시 만든다(1~2초 끊김).
# 바꾸는 것은 앱 이미지뿐이다. compose 파일·.env·DB·모델 파일은 건드리지 않는다.
set -uo pipefail
COMPOSE="${TRACE_COMPOSE_DIR:-$HOME/gitops/compose}"
STATE="${TRACE_DEPLOY_STATE:-$HOME/.cache/trace-deploy}"
PAUSE="${TRACE_DEPLOY_PAUSE:-$HOME/.config/trace-deploy.pause}"
PORT="${WEB_PORT:-8315}"
WAIT="${TRACE_DEPLOY_WAIT:-180}"
STEP="${TRACE_DEPLOY_STEP:-3}"
# inspect-worker는 검사 도중에 다시 켜지지 않게 기본에서 뺐다. 넣으려면 이 변수에 더한다
SERVICES="${TRACE_DEPLOY_SERVICES:-auth-server rental-server capture-server diagnostics-server report-server chat-server gateway web}"
# 무중단으로 바꿀 서비스(호스트 포트를 쓰지 않는 것만). 비우면 모두 예전처럼 다시 만든다
ROLLING="${TRACE_DEPLOY_ROLLING-gateway auth-server rental-server capture-server diagnostics-server report-server chat-server}"
SETTLE="${TRACE_DEPLOY_SETTLE:-8}"          # gateway가 새 IP를 찾을 때까지(이름 기억 5초 + 여유)
STOP_WAIT="${TRACE_DEPLOY_STOP_WAIT:-40}"   # 옛 컨테이너가 처리 중인 요청을 끝낼 시간(Spring graceful 30초 + 여유)
APP_PORT="${TRACE_APP_PORT:-8080}"
ROLL_LABEL="site.gakdo.trace.upstream-rolling"
. "$(dirname "$0")/notify.sh"

now() { date -u +%FT%TZ; }
log() { echo "$(now) $*"; }
c() { docker compose "$@"; }

# 서비스별 확인 주소(web nginx가 입구). 목록에 없는 서비스는 컨테이너 상태만 본다
ping_path() {
  case "$1" in
    gateway) echo /api/v1/gateway/ping ;;
    auth-server) echo /api/v1/auth/ping ;;
    rental-server) echo /api/v1/rentals/ping ;;
    capture-server) echo /api/v1/captures/ping ;;
    diagnostics-server) echo /api/v1/diagnostics/ping ;;
    report-server) echo /api/v1/reports/ping ;;
    chat-server) echo /api/v1/chat/ping ;;
    web) echo /version.txt ;;
  esac
}
fetch() {   # tls/가 있으면 https로 열리므로 둘 다 본다(health.sh와 같음)
  local scheme
  for scheme in http https; do
    curl -fsS -m 5 -k "$scheme://127.0.0.1:$PORT$1" 2>/dev/null && return 0
  done
  return 1
}
# 서비스의 이미지 이름은 지금 떠 있는 컨테이너에서 읽는다(`compose config --images <서비스>`는 depends_on 이미지까지 섞여 나온다).
# 우리 앱 이미지가 아니면 빈 값을 돌려줘 건드리지 않는다(되돌리기의 docker tag가 postgres 같은 인프라 태그를 덮지 않게)
PREFIX="${TRACE_DEPLOY_IMAGE_PREFIX:-ghcr.io/gakdo/}"
image_ref() {
  local cid ref
  cid=$(container "$1"); [ -n "$cid" ] || return 0
  ref=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)
  case "$ref" in "$PREFIX"*) echo "$ref" ;; esac
}
image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null; }
# 이미지에 구운 커밋(APP_COMMIT). 없거나 unknown이면 빈 값
image_commit() {
  local v
  v=$(docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n 's/^APP_COMMIT=//p' | head -n 1)
  [ "$v" = unknown ] && v=""
  echo "$v"
}
short() {   # 사람이 읽을 짧은 이름: 커밋 7자, 없으면 이미지 ID 앞 12자
  local commit; commit=$(image_commit "$1")
  if [ -n "$commit" ]; then echo "${commit::7}"; else local id="${1#sha256:}"; echo "${id::12}"; fi
}
container() { c ps -q "$1" | head -n 1; }
containers() { c ps -q "$1"; }
container_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" 2>/dev/null | awk '{print $1}'; }
# 새 컨테이너에 직접 묻는다(아직 옛 컨테이너도 떠 있어 입구로는 누가 답했는지 알 수 없다). 리눅스 호스트에서만 닿는다
fetch_direct() { local ip; ip=$(container_ip "$1"); [ -n "$ip" ] && curl -fsS -m 5 "http://$ip:$APP_PORT$2" 2>/dev/null; }
reload_web() { c exec -T web nginx -s reload >/dev/null 2>&1; }
# gateway를 다시 만들면 주소가 바뀔 수 있어 web nginx에 알린다(reload가 실패해도 30초 뒤에는 nginx가 스스로 다시 찾는다)
gateway_moved() { [ "$1" != gateway ] || reload_web || true; }
# 무중단으로 바꿀 수 있는가: 목록에 있고, 서버라면 지금 도는 gateway가 교체를 견디는 이미지여야 한다
can_roll() {
  local svc="$1" gw
  case " $ROLLING " in *" $svc "*) ;; *) return 1 ;; esac
  [ "$svc" = gateway ] && return 0
  gw=$(container gateway); [ -n "$gw" ] || return 1
  [ "$(docker inspect -f "{{index .Config.Labels \"$ROLL_LABEL\"}}" "$gw" 2>/dev/null)" = 1 ]
}
# 앞 실행이 중간에 죽어 컨테이너가 둘 남았으면 가장 먼저 만든 것(요청을 받던 것)만 남긴다.
# 나중 것은 준비 확인을 마쳤는지 알 수 없으므로 지우고, 이미지가 다르면 이어지는 배포가 확인부터 다시 한다
# 멈춘 채 남은 컨테이너도 지운다(남아 있으면 --scale 2가 새로 만들지 않고 그것을 다시 켠다).
# 지우지 못하면 실패를 돌려줘 이 서비스를 건너뛰고 다음 실행에서 다시 한다(새 이미지를 실패로 적지 않게)
keep_one() {
  local svc="$1" all every keep="" cid failed=""
  # 목록을 읽지 못하면 아무것도 지우지 않는다(빈 목록으로 보면 도는 컨테이너까지 멈춘 것으로 알고 지운다)
  all=$(containers "$svc") && every=$(c ps -aq "$svc") || { log "[$svc] 컨테이너 목록을 읽지 못해 정리하지 않음"; return 1; }
  for cid in $every; do
    grep -qx "$cid" <<<"$all" && continue
    log "[$svc] 멈춘 채 남은 컨테이너 ${cid::12} 정리"
    docker rm -f "$cid" >/dev/null 2>&1 || { log "[$svc] 멈춘 컨테이너 ${cid::12}를 지우지 못함"; failed=1; }
  done
  [ "$(wc -w <<<"$all")" -gt 1 ] || { [ -z "$failed" ]; return; }
  local made rows=""
  for cid in $all; do
    # 만든 시각을 읽지 못하면 어느 것이 요청을 받던 것인지 알 수 없다. 아무것도 지우지 않고 이 서비스는 건너뛴다
    made=$(docker inspect -f '{{.Created}}' "$cid" 2>/dev/null) && [ -n "$made" ] || { log "[$svc] 컨테이너가 둘인데 만든 시각을 읽지 못해 정리하지 않음. 직접 확인 필요"; return 1; }
    rows="$rows$made $cid"$'\n'
  done
  keep=$(sort <<<"$rows" | sed '/^$/d' | head -n 1 | awk '{print $NF}')
  for cid in $all; do
    [ "$cid" = "$keep" ] && continue
    log "[$svc] 남아 있던 여분 컨테이너 ${cid::12} 정리"
    docker rm -f "$cid" >/dev/null 2>&1 || { log "[$svc] 여분 컨테이너 ${cid::12}를 지우지 못함"; failed=1; }
  done
  [ "$svc" = gateway ] && reload_web
  [ -z "$failed" ]
}
# 알림을 보내지 못하면 남겨 두었다가 다음 실행 때 다시 보낸다(되돌림 알림이 웹훅 장애로 사라지지 않게)
notify_or_queue() { trace_notify "$1" || echo "$1" >> "$STATE/pending-notify"; }
flush_notify() {
  [ -s "$STATE/pending-notify" ] || return 0
  local line rest="" tries=0
  while IFS= read -r line; do
    # 웹훅이 응답하지 않으면 건마다 10초씩 걸리므로 한 번에 5건까지만 다시 보낸다(배포가 밀리지 않게)
    if [ "$tries" -ge 5 ]; then rest="$rest$line"$'\n'; continue; fi
    tries=$((tries + 1))
    trace_notify "$line" || rest="$rest$line"$'\n'
  done < "$STATE/pending-notify"
  printf '%s' "$rest" > "$STATE/pending-notify"
}

# 새 컨테이너가 제대로 떴는지: $1 서비스, $2 기대하는 이미지 ID, $3(있으면) 그 컨테이너에 직접 묻는다
wait_ready() {
  local svc="$1" want="$2" only="${3:-}" path commit start=$SECONDS cid st body
  path=$(ping_path "$svc"); commit=$(image_commit "$want")
  while :; do
    cid="${only:-$(container "$svc")}"
    if [ -n "$cid" ]; then
      st=$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$cid" 2>/dev/null)
      case "$st" in
        "running 0")
          if [ "$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)" = "$want" ]; then
            if [ -z "$path" ]; then
              # 확인 주소가 없는 서비스는 10초 동안 죽지 않으면 통과
              [ $((SECONDS - start)) -ge 10 ] && return 0
            elif body=$(if [ -n "$only" ]; then fetch_direct "$cid" "$path"; else fetch "$path"; fi); then
              # web의 version.txt는 이미지에 커밋 환경 변수가 없어 응답 여부만 본다
              if [ -z "$commit" ] || grep -q "$commit" <<<"$body"; then return 0; fi
            fi
          fi ;;
        "created 0"|"restarting 0"|"") ;;   # 아직 켜지는 중
        *) log "[$svc] 새 컨테이너가 죽었거나 다시 켜짐($st)"; return 1 ;;
      esac
    fi
    [ $((SECONDS - start)) -ge "$WAIT" ] && { log "[$svc] ${WAIT}초 안에 준비되지 않음"; return 1; }
    sleep "$STEP"
  done
}

# 무중단 교체: $1 서비스, $2 띄울 이미지 ID(태그가 이미 그 이미지를 가리켜야 한다).
# 0 성공, 1 새 컨테이너가 준비되지 않음(옛 컨테이너는 그대로라 끊기지 않았다), 2 옛 컨테이너를 내린 뒤 입구 확인 실패
roll() {
  local svc="$1" want="$2" old new="" cid
  old=$(containers "$svc")
  if ! c up -d --no-deps --no-recreate --scale "$svc=2" "$svc" >/dev/null 2>&1; then
    # 실패해도 새 컨테이너가 만들어졌을 수 있다. 옛 것만 남긴다
    for cid in $(containers "$svc"); do grep -qx "$cid" <<<"$old" || docker rm -f "$cid" >/dev/null 2>&1; done
    return 1
  fi
  for cid in $(containers "$svc"); do grep -qx "$cid" <<<"$old" || new="$cid"; done
  [ -n "$new" ] || { log "[$svc] 새 컨테이너가 만들어지지 않음"; return 1; }
  if ! wait_ready "$svc" "$want" "$new"; then
    docker logs --tail=30 "$new" 2>&1 | sed "s/^/[$svc] /" || true
    docker rm -f "$new" >/dev/null 2>&1
    return 1
  fi
  # 부르는 쪽이 새 컨테이너를 알게 한 뒤에 옛 것을 내린다
  if [ "$svc" = gateway ]; then reload_web || sleep 31; else sleep "$SETTLE"; fi
  for cid in $old; do
    docker stop -t "$STOP_WAIT" "$cid" >/dev/null 2>&1
    docker rm -f "$cid" >/dev/null 2>&1
  done
  # 옛 컨테이너가 아직 돌고 있으면 입구 확인이 옛 것을 볼 수 있으므로 성공으로 치지 않는다.
  # 멈췄지만 지워지지 않은 것은 요청을 받지 않으므로 배포는 계속하고, 손으로 지우도록 알린다
  local st
  for cid in $old; do
    st=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null) || continue   # 없으면 지워진 것
    if [ "${st%% *}" = running ]; then log "[$svc] 옛 컨테이너 ${cid::12}를 내리지 못함(상태 $st)"; return 2; fi
    log "[$svc] 멈춘 옛 컨테이너 ${cid::12}가 지워지지 않음(상태 $st)"
    notify_or_queue "배포 주의: $svc 의 멈춘 옛 컨테이너 ${cid::12}가 지워지지 않았습니다 · 확인: docker rm ${cid::12}"
  done
  [ "$svc" = gateway ] && reload_web   # 없어진 옛 주소를 nginx가 잊게 한다
  wait_ready "$svc" "$want" || return 2
}

# 되돌리기: 같은 태그를 직전 이미지로 다시 붙이고 그 이미지로 띄운다.
# 실패하면 직전 이미지와 태그를 적어 두어 다음 실행이 다시 시도한다(알림은 처음 한 번만).
# 표식을 알림보다 먼저 적는다(알림 도중에 죽어도 다음 실행이 되돌리기를 이어 가게)
rollback() {
  local svc="$1" ref="$2" prev="$3" bad="$4"
  if docker tag "$prev" "$ref" && c up -d --no-deps "$svc" >/dev/null 2>&1 && gateway_moved "$svc" && wait_ready "$svc" "$prev"; then
    rm -f "$STATE/$svc.rollback"
    log "[$svc] 새 버전이 응답하지 않아 직전 버전 $(short "$prev")로 되돌림"
    echo "$(now) $svc $(short "$prev") $(short "$bad") rollback" >> "$STATE/history.log"
    notify_or_queue "배포 실패 → 되돌림: $svc $(short "$bad")가 응답하지 않아 $(short "$prev")로 되돌렸습니다"
    return 0
  fi
  log "[$svc] 되돌리기도 실패. 직접 확인 필요"
  local first=1
  [ -e "$STATE/$svc.rollback" ] && first=0
  echo "$prev $ref" > "$STATE/$svc.rollback" || log "[$svc] 되돌리기 표식을 적지 못함"
  if [ "$first" = 1 ]; then
    echo "$(now) $svc $(short "$prev") $(short "$bad") rollback-failed" >> "$STATE/history.log"
    notify_or_queue "배포 실패, 되돌리기도 실패: $svc · 확인: cd $COMPOSE && docker compose ps && docker compose logs --tail=50 $svc"
  fi
  return 1
}

deploy_one() {
  local svc="$1" ref cid cur new took
  # 도는 중에 멈춤(pause)이 걸렸으면 남은 서비스는 바꾸지 않는다
  [ -e "$PAUSE" ] && return 0
  # 지난번에 되돌리기를 끝내지 못했으면 다른 검사·이미지 받기보다 먼저 다시 되돌린다.
  # 실패한 컨테이너가 그사이 죽었거나 레지스트리에 닿지 않아도, 직전 이미지는 이 서버에 남아 있다
  local prev="" pref=""
  [ -s "$STATE/$svc.rollback" ] && read -r prev pref < "$STATE/$svc.rollback"
  if [ -n "$prev" ] && [ -n "$pref" ]; then
    keep_one "$svc" || return 1
    cid=$(container "$svc"); cur=""
    [ -n "$cid" ] && cur=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)
    if [ "$cur" = "$prev" ]; then
      rm -f "$STATE/$svc.rollback"   # 사람이 이미 직전 버전으로 띄워 둠
    elif docker image inspect "$prev" >/dev/null 2>&1; then
      log "[$svc] 끝내지 못한 되돌리기를 다시 시도"
      rollback "$svc" "$pref" "$prev" "${cur:-$prev}"; return 1
    else
      log "[$svc] 직전 이미지가 이 서버에 없어 되돌리기를 그만둠. 직접 확인 필요"
      rm -f "$STATE/$svc.rollback"
    fi
  else
    rm -f "$STATE/$svc.rollback"
  fi
  cid=$(container "$svc")
  # 떠 있지 않은 서비스는 사람이 일부러 멈춘 것으로 보고 건드리지 않는다
  [ -n "$cid" ] || { log "[$svc] 떠 있지 않아 건너뜀"; return 0; }
  ref=$(image_ref "$svc")
  [ -n "$ref" ] || { log "[$svc] 앱 이미지($PREFIX)가 아니어서 건너뜀"; return 0; }
  # 손으로 다른 태그(예: AUTH_SERVER_TAG=latest)로 띄운 컨테이너면 compose가 받는 이미지와 달라 비교가 어긋난다. 건드리지 않고 알린다
  # 이미지 이름은 서비스 이름과 같다(ghcr.io/gakdo/<서비스>:<태그>). 목록에 있더라도 다른 서비스의 이미지면 이 서비스 설정과 다른 것이다
  { [ "${ref%:*}" = "$PREFIX$svc" ] && grep -qxF "$ref" <<<"$COMPOSE_IMAGES"; } || { log "[$svc] 도는 이미지($ref)가 compose 설정과 달라 건너뜀. 같은 설정으로 다시 띄워 주세요"; return 1; }
  # 이 서비스만 받는다. 받기가 실패해도 다른 서비스는 계속한다
  c pull -q "$svc" >/dev/null 2>&1 || { log "[$svc] 이미지 받기 실패(다음 차례에 다시 시도)"; return 1; }
  cur=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null); new=$(image_id "$ref")
  [ -n "$cur" ] && [ -n "$new" ] || { log "[$svc] 이미지 정보를 읽지 못해 건너뜀"; return 0; }
  keep_one "$svc" || return 1
  cid=$(container "$svc"); cur=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)
  [ "$cur" = "$new" ] && return 0
  if [ "$(cat "$STATE/$svc.bad" 2>/dev/null)" = "$new" ]; then return 0; fi   # 이미 실패한 이미지. 다음 이미지를 기다린다

  local start=$SECONDS mode="교체" rc
  if can_roll "$svc"; then
    mode="무중단 교체"
    log "[$svc] $(short "$cur") → $(short "$new") $mode 시작"
    roll "$svc" "$new"; rc=$?
    if [ "$rc" = 1 ]; then
      # 새 컨테이너만 지웠고 옛 컨테이너가 계속 받았다. 태그를 직전 이미지로 돌려 손으로 up 해도 실패한 이미지가 뜨지 않게 한다
      echo "$new" > "$STATE/$svc.bad"; docker tag "$cur" "$ref"
      log "[$svc] 새 버전이 준비되지 않아 바꾸지 않음(끊김 없음)"
      echo "$(now) $svc $(short "$cur") $(short "$new") not-ready" >> "$STATE/history.log"
      notify_or_queue "배포 실패(끊김 없음): $svc $(short "$new")가 준비되지 않아 $(short "$cur")를 그대로 둡니다"
      return 1
    fi
  else
    log "[$svc] $(short "$cur") → $(short "$new") $mode 시작"
    c up -d --no-deps "$svc" >/dev/null 2>&1 && gateway_moved "$svc" && wait_ready "$svc" "$new"; rc=$?
  fi
  if [ "$rc" = 0 ]; then
    took=$((SECONDS - start)); rm -f "$STATE/$svc.bad"
    log "[$svc] 배포 완료 (${took}초, $mode)"
    echo "$(now) $svc $(short "$cur") $(short "$new") ok ${took}s $mode" >> "$STATE/history.log"
    notify_or_queue "배포 완료: $svc $(short "$cur") → $(short "$new") (${took}초, $mode)"
    return 0
  fi

  c logs --tail=30 "$svc" 2>&1 | sed "s/^/[$svc] /" || true
  echo "$new" > "$STATE/$svc.bad"
  rollback "$svc" "$ref" "$cur" "$new"
  return 1
}

# compose 파일에 없는 서비스 이름은 뺀다(옛 compose 파일이어도 받기가 통째로 실패하지 않게)
only_defined() {
  local defined s
  defined="$(c config --services)" || { log "compose config 조회 실패"; exit 1; }
  SERVICES="$(for s in $SERVICES; do grep -qx "$s" <<<"$defined" && printf '%s ' "$s"; done)"
  [ -n "$SERVICES" ] || { log "배포할 서비스가 없음"; exit 1; }
}

status() {
  local svc ref cid cur new mark
  [ -e "$PAUSE" ] && echo "자동 배포 멈춤: $(cat "$PAUSE")"
  printf '%-20s %-14s %-14s %s\n' 서비스 "도는 버전" "받아 둔 버전" 상태
  for svc in $SERVICES; do
    ref=$(image_ref "$svc"); cid=$(container "$svc")
    cur=""; [ -n "$cid" ] && cur=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)
    new=""; [ -n "$ref" ] && new=$(image_id "$ref")
    if [ -z "$cur" ]; then mark="멈춤"
    elif [ "$cur" = "$new" ]; then mark="최신"
    elif [ "$(cat "$STATE/$svc.bad" 2>/dev/null)" = "$new" ]; then mark="새 버전 실패(되돌림)"
    else mark="배포 대기"; fi
    printf '%-20s %-14s %-14s %s\n' "$svc" "$([ -n "$cur" ] && short "$cur" || echo -)" "$([ -n "$new" ] && short "$new" || echo -)" "$mark"
  done
  [ -f "$STATE/history.log" ] && { echo; echo "최근 배포:"; tail -n 5 "$STATE/history.log"; }
  return 0
}

mkdir -p "$STATE" "$(dirname "$PAUSE")"
cd "$COMPOSE" || exit 1
case "${1:-run}" in
  pause)
    # 표시를 먼저 써야 진행 중인 배포가 다음 서비스로 넘어가지 않는다
    shift; echo "$(now) ${*:-사유 없음}" > "$PAUSE" || { echo "멈춤 표시를 쓰지 못했습니다: $PAUSE" >&2; exit 1; }
    # 이미 교체 중인 서비스가 있으면 끝날 때까지 기다렸다가 돌아온다(돌아온 뒤에는 아무것도 바뀌지 않는다)
    exec 9>>"$STATE/lock"
    flock -w 300 9 || { echo "진행 중인 배포가 5분 넘게 끝나지 않았습니다. 멈춤은 걸렸으니 $0 status로 확인하세요" >&2; exit 1; }
    echo "자동 배포를 멈췄습니다. 다시 켜기: $0 resume"; exit 0 ;;
  resume)
    rm -f "$PAUSE" || { echo "멈춤 표시를 지우지 못했습니다: $PAUSE" >&2; exit 1; }
    echo "자동 배포를 다시 켰습니다."; exit 0 ;;
  roll)
    svc="${2:?쓰는 법: $0 roll <서비스>}"
    can_roll "$svc" || { echo "$svc 는 무중단으로 바꿀 수 없습니다(목록에 없거나, 지금 gateway 이미지가 교체를 견디지 못함)" >&2; exit 1; }
    exec 9>>"$STATE/lock"; flock -w 60 9 || { echo "다른 배포가 진행 중입니다" >&2; exit 1; }
    # 기다리는 사이에 gateway가 바뀌었을 수 있다
    can_roll "$svc" || { echo "$svc 는 지금 무중단으로 바꿀 수 없습니다(기다리는 사이 gateway 이미지가 바뀜)" >&2; exit 1; }
    cid=$(container "$svc"); [ -n "$cid" ] || { echo "$svc 가 떠 있지 않습니다" >&2; exit 1; }
    keep_one "$svc" || exit 1
    cid=$(container "$svc"); cur=$(docker inspect -f '{{.Image}}' "$cid"); ref=$(image_ref "$svc")
    # 받아 두기만 한 새 이미지가 있으면 새 컨테이너가 그 이미지로 떠서 "같은 이미지로 교체"가 되지 않는다
    [ -n "$ref" ] && [ "$(image_id "$ref")" = "$cur" ] || { echo "$svc 는 도는 이미지와 받아 둔 이미지가 다릅니다. 먼저 $0 을 한 번 돌려 배포를 끝내 주세요" >&2; exit 1; }
    log "[$svc] 같은 이미지 $(short "$cur")로 무중단 교체 시험"; start=$SECONDS
    roll "$svc" "$cur"; rc=$?
    log "[$svc] 끝(결과 $rc, $((SECONDS - start))초)"; exit "$rc" ;;
  probe)
    svc="${2:?쓰는 법: $0 probe <서비스> [초]}"; secs="${3:-120}"; path=$(ping_path "$svc")
    [ -n "$path" ] || { echo "$svc 는 확인 주소가 없습니다" >&2; exit 1; }
    okc=0; bad=0; end=$((SECONDS + secs))
    while [ "$SECONDS" -lt "$end" ]; do
      if fetch "$path" >/dev/null; then okc=$((okc + 1)); else bad=$((bad + 1)); echo "$(now) 실패"; fi
      sleep 0.2
    done
    echo "$svc ${secs}초: 성공 $okc, 실패 $bad"; [ "$bad" = 0 ]; exit $? ;;
  status) only_defined; status; exit 0 ;;
  run) ;;
  *) echo "쓰는 법: $0 [run|status|pause [사유]|resume|roll <서비스>|probe <서비스> [초]]" >&2; exit 2 ;;
esac

[ -e "$PAUSE" ] && exit 0   # 멈춤 상태에서는 아무것도 하지 않는다(로그도 남기지 않는다)
# 앞 실행이나 health.sh 점검이 끝나기를 잠깐 기다리고, 그래도 안 끝나면 이번 차례는 건너뛴다
exec 9>>"$STATE/lock"
flock -w 60 9 || exit 0
[ -e "$PAUSE" ] && exit 0   # 기다리는 사이에 멈춤이 걸렸을 수 있다
only_defined
COMPOSE_IMAGES="$(c config --images)" || { log "compose 이미지 목록 조회 실패"; exit 1; }
flush_notify

rc=0
for svc in $SERVICES; do deploy_one "$svc" || rc=1; done
exit "$rc"
