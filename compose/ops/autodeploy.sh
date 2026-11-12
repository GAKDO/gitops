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
#
# 한 서비스마다: 그 서비스의 새 이미지 받기 → 지금 컨테이너와 이미지가 다르면 교체 → 최대 TRACE_DEPLOY_WAIT초 동안
#   ① 컨테이너가 죽거나 다시 켜지지 않았는지 ② ping이 응답하는지 ③ 응답의 커밋이 새 이미지의 커밋인지 확인
#   → 실패하면 직전 이미지로 되돌리고 그 이미지를 '실패'로 적어 다음 이미지가 올 때까지 다시 시도하지 않는다.
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
# 알림을 보내지 못하면 남겨 두었다가 다음 실행 때 다시 보낸다(되돌림 알림이 웹훅 장애로 사라지지 않게)
notify_or_queue() { trace_notify "$1" || echo "$1" >> "$STATE/pending-notify"; }
flush_notify() {
  [ -s "$STATE/pending-notify" ] || return 0
  local line rest=""
  while IFS= read -r line; do
    trace_notify "$line" || rest="$rest$line"$'\n'
  done < "$STATE/pending-notify"
  printf '%s' "$rest" > "$STATE/pending-notify"
}

# 새 컨테이너가 제대로 떴는지: $1 서비스, $2 기대하는 이미지 ID
wait_ready() {
  local svc="$1" want="$2" path commit start=$SECONDS cid st body
  path=$(ping_path "$svc"); commit=$(image_commit "$want")
  while :; do
    cid=$(container "$svc")
    if [ -n "$cid" ]; then
      st=$(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$cid" 2>/dev/null)
      case "$st" in
        "running 0")
          if [ "$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)" = "$want" ]; then
            if [ -z "$path" ]; then
              # 확인 주소가 없는 서비스는 10초 동안 죽지 않으면 통과
              [ $((SECONDS - start)) -ge 10 ] && return 0
            elif body=$(fetch "$path"); then
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

deploy_one() {
  local svc="$1" ref cid cur new took
  # 도는 중에 멈춤(pause)이 걸렸으면 남은 서비스는 바꾸지 않는다
  [ -e "$PAUSE" ] && return 0
  cid=$(container "$svc")
  # 떠 있지 않은 서비스는 사람이 일부러 멈춘 것으로 보고 건드리지 않는다
  [ -n "$cid" ] || { log "[$svc] 떠 있지 않아 건너뜀"; return 0; }
  ref=$(image_ref "$svc")
  [ -n "$ref" ] || { log "[$svc] 앱 이미지($PREFIX)가 아니어서 건너뜀"; return 0; }
  # 이 서비스만 받는다. 받기가 실패해도 다른 서비스는 계속한다
  c pull -q "$svc" >/dev/null 2>&1 || { log "[$svc] 이미지 받기 실패(다음 차례에 다시 시도)"; return 1; }
  cur=$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null); new=$(image_id "$ref")
  [ -n "$cur" ] && [ -n "$new" ] || { log "[$svc] 이미지 정보를 읽지 못해 건너뜀"; return 0; }
  [ "$cur" = "$new" ] && return 0
  if [ "$(cat "$STATE/$svc.bad" 2>/dev/null)" = "$new" ]; then return 0; fi   # 이미 실패한 이미지. 다음 이미지를 기다린다

  log "[$svc] $(short "$cur") → $(short "$new") 교체 시작"
  local start=$SECONDS
  if c up -d --no-deps "$svc" >/dev/null 2>&1 && wait_ready "$svc" "$new"; then
    took=$((SECONDS - start)); rm -f "$STATE/$svc.bad"
    log "[$svc] 배포 완료 (${took}초)"
    echo "$(now) $svc $(short "$cur") $(short "$new") ok ${took}s" >> "$STATE/history.log"
    notify_or_queue "배포 완료: $svc $(short "$cur") → $(short "$new") (${took}초)"
    return 0
  fi

  # 되돌리기: 같은 태그를 직전 이미지로 다시 붙이고 그 이미지로 띄운다
  c logs --tail=30 "$svc" 2>&1 | sed "s/^/[$svc] /" || true
  echo "$new" > "$STATE/$svc.bad"
  if docker tag "$cur" "$ref" && c up -d --no-deps "$svc" >/dev/null 2>&1 && wait_ready "$svc" "$cur"; then
    log "[$svc] 새 버전이 응답하지 않아 직전 버전 $(short "$cur")로 되돌림"
    echo "$(now) $svc $(short "$cur") $(short "$new") rollback" >> "$STATE/history.log"
    notify_or_queue "배포 실패 → 되돌림: $svc $(short "$new")가 응답하지 않아 $(short "$cur")로 되돌렸습니다"
  else
    log "[$svc] 되돌리기도 실패. 직접 확인 필요"
    echo "$(now) $svc $(short "$cur") $(short "$new") rollback-failed" >> "$STATE/history.log"
    notify_or_queue "배포 실패, 되돌리기도 실패: $svc · 확인: cd $COMPOSE && docker compose ps && docker compose logs --tail=50 $svc"
  fi
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
    shift; echo "$(now) ${*:-사유 없음}" > "$PAUSE"
    # 이미 교체 중인 서비스가 있으면 끝날 때까지 기다렸다가 돌아온다(돌아온 뒤에는 아무것도 바뀌지 않는다)
    exec 9>>"$STATE/lock"
    flock -w 300 9 || { echo "진행 중인 배포가 5분 넘게 끝나지 않았습니다. 멈춤은 걸렸으니 $0 status로 확인하세요" >&2; exit 1; }
    echo "자동 배포를 멈췄습니다. 다시 켜기: $0 resume"; exit 0 ;;
  resume) rm -f "$PAUSE"; echo "자동 배포를 다시 켰습니다."; exit 0 ;;
  status) only_defined; status; exit 0 ;;
  run) ;;
  *) echo "쓰는 법: $0 [run|status|pause [사유]|resume]" >&2; exit 2 ;;
esac

[ -e "$PAUSE" ] && exit 0   # 멈춤 상태에서는 아무것도 하지 않는다(로그도 남기지 않는다)
# 앞 실행이나 health.sh 점검이 끝나기를 잠깐 기다리고, 그래도 안 끝나면 이번 차례는 건너뛴다
exec 9>>"$STATE/lock"
flock -w 60 9 || exit 0
[ -e "$PAUSE" ] && exit 0   # 기다리는 사이에 멈춤이 걸렸을 수 있다
only_defined
flush_notify

rc=0
for svc in $SERVICES; do deploy_one "$svc" || rc=1; done
exit "$rc"
