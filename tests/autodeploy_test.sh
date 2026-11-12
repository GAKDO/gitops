#!/usr/bin/env bash
# compose/ops/autodeploy.sh 시험. 가짜 docker·curl을 PATH 앞에 두고 실제 서버 없이 네 가지를 본다:
#   ① 바뀐 게 없으면 아무것도 안 함 ② 새 이미지가 정상이면 교체 ③ 새 이미지가 응답하지 않으면 되돌리고 다시 시도하지 않음 ④ 멈춤(pause)
# 쓰는 법: bash tests/autodeploy_test.sh   (CI '매니페스트 검증'에서도 돈다)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/w" "$T/compose" "$T/home"
# 가짜 세계: w/tag.<서비스> = 태그가 가리키는 이미지, w/run.<서비스> = 컨테이너가 쓰는 이미지,
#            w/remote.<서비스> = 레지스트리의 최신 이미지, w/broken = 떠도 응답하지 않는 이미지 목록
cat > "$T/bin/docker" <<'FAKE'
#!/usr/bin/env bash
# 컨테이너 번호: cid-<서비스>는 w/run.<서비스>, cid2-<서비스>는 w/run2.<서비스>(무중단 교체 때 옆에 하나 더 뜬 것)
W="$FAKE_WORLD"
svc_of() { echo "${1#ghcr.io/gakdo/}" | cut -d: -f1; }
file_of() { case "$1" in cid2-*) echo "$W/run2.${1#cid2-}" ;; *) echo "$W/run.${1#cid-}" ;; esac; }
name_of() { local n="${1#cid2-}"; echo "${n#cid-}"; }
if [ "$1" = compose ]; then
  shift
  case "$1" in
    config)
      case "$*" in
        *--images*) printf '%s\n' ghcr.io/gakdo/auth-server:develop ghcr.io/gakdo/gateway:develop ghcr.io/gakdo/web:develop postgres:16 ;;
        *) printf '%s\n' auth-server gateway web postgres ;;
      esac ;;
    ps) [ -f "$W/run.$3" ] && echo "cid-$3"; [ -f "$W/run2.$3" ] && echo "cid2-$3" ;;
    pull) shift 2; for s in "$@"; do [ -e "$W/pull-fail.$s" ] && exit 1; [ -f "$W/remote.$s" ] && cp "$W/remote.$s" "$W/tag.$s"; done ;;
    up) s="${*: -1}"
      case "$*" in
        *--scale*) [ -e "$W/scale-fail.$s" ] && { cp "$W/tag.$s" "$W/run2.$s"; exit 1; }
                   if [ -f "$W/run.$s" ]; then cp "$W/tag.$s" "$W/run2.$s"; else cp "$W/tag.$s" "$W/run.$s"; fi
                   echo "roll $s $(cat "$W/tag.$s")" >> "$W/ups" ;;
        *) rm -f "$W/run2.$s"; cp "$W/tag.$s" "$W/run.$s"; echo "up $s $(cat "$W/tag.$s")" >> "$W/ups" ;;
      esac ;;
    exec) echo "$*" >> "$W/reloads" ;;
    logs) echo "(가짜 로그)" ;;
  esac
  exit 0
fi
case "$1" in
  inspect)
    f=$(file_of "$4"); s=$(name_of "$4")
    [ -f "$f" ] || [ -f "$f.stopped" ] || exit 1
    case "$3" in
      *State.Status*) if [ -f "$f" ]; then echo "running 0"; else echo "exited 0"; fi ;;
      *Created*) [ -e "$W/created-fail" ] && exit 1
                 case "$4" in cid2-*) echo 2 ;; *) echo 1 ;; esac ;;
      *Config.Image*) echo "ghcr.io/gakdo/$(cat "$W/imgname.$s" 2>/dev/null || echo "$s"):$(cat "$W/tagname.$s" 2>/dev/null || echo develop)" ;;
      *NetworkSettings*) case "$4" in cid2-*) echo "10.0.0.2 " ;; *) echo "10.0.0.1 " ;; esac ;;
      *Config.Labels*) cat "$W/gateway-label" 2>/dev/null ;;
      *) cat "$f" ;;
    esac ;;
  image)
    case "$4" in
      *.Id*) cat "$W/tag.$(svc_of "$5")" ;;
      *) id="$5"; case "$id" in ghcr.io/*) id=$(cat "$W/tag.$(svc_of "$id")") ;; esac; echo "APP_COMMIT=${id#sha256:}0000000" ;;
    esac ;;
  tag) echo "$2" > "$W/tag.$(svc_of "$3")" ;;
  stop) echo "stop ${*: -1}" >> "$W/stops" ;;
  rm) f=$(file_of "${*: -1}"); if [ -e "$W/rm-fail" ]; then mv "$f" "$f.stopped"; exit 1; fi; rm -f "$f" ;;
  logs) echo "(가짜 로그)" ;;
esac
FAKE
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# 127.0.0.1(입구)은 남아 있는 컨테이너가, 10.0.0.1·10.0.0.2는 그 컨테이너가 직접 답한다
W="$FAKE_WORLD"; url="${*: -1}"
case "$url" in
  *hooks*) [ -e "$W/hook-down" ] && exit 7; echo "$*" >> "$W/notified"; printf 200; exit 0 ;;
  http://*auth/ping) s=auth-server ;; http://*gateway/ping) s=gateway ;; http://*version.txt) s=web ;;
  *) exit 22 ;;
esac
case "$url" in
  http://10.0.0.2:*) f="$W/run2.$s" ;;
  http://10.0.0.1:*) f="$W/run.$s" ;;
  *) f="$W/run.$s"; [ -f "$f" ] || f="$W/run2.$s"; echo "$s $(cat "$f")" >> "$W/entrance" ;;
esac
[ -f "$f" ] || exit 7
id=$(cat "$f"); grep -qx "$id" "$W/broken" 2>/dev/null && exit 22
echo "{\"commit\":\"${id#sha256:}0000000\"}"
FAKE
chmod +x "$T/bin/docker" "$T/bin/curl"
export PATH="$T/bin:$PATH" FAKE_WORLD="$T/w" HOME="$T/home" TRACE_COMPOSE_DIR="$T/compose"
export TRACE_DEPLOY_SERVICES="auth-server gateway web chat-server" TRACE_DEPLOY_WAIT=2 TRACE_DEPLOY_STEP=1
export TRACE_DEPLOY_SETTLE=0 TRACE_DEPLOY_ROLLING=""   # 앞부분은 예전 방식(다시 만들기)으로 본다
export TRACE_ALERT_WEBHOOK_URL="https://example.invalid/hooks/x"
run() { bash "$ROOT/compose/ops/autodeploy.sh" "$@"; }
set_img() { echo "sha256:$2" > "$T/w/$1"; }
ups() { wc -l < "$T/w/ups" 2>/dev/null || echo 0; }
ok() { echo "ok - $1"; }
fail() { echo "not ok - $1"; exit 1; }
: > "$T/w/broken"; : > "$T/w/ups"; : > "$T/w/notified"
for s in auth-server gateway web; do set_img "tag.$s" aaa1; set_img "run.$s" aaa1; set_img "remote.$s" aaa1; done

run >/dev/null
[ "$(ups)" = 0 ] && ok "바뀐 이미지가 없으면 아무것도 다시 띄우지 않는다" || fail "변화 없음"

set_img remote.auth-server bbb2
run >/dev/null
[ "$(cat "$T/w/run.auth-server")" = sha256:bbb2 ] && [ "$(ups)" = 1 ] && ok "새 이미지가 응답하면 그 서비스만 교체한다" || fail "정상 교체"
grep -q "auth-server aaa1000 bbb2000 ok" "$T/home/.cache/trace-deploy/history.log" && ok "배포 이력을 남긴다" || fail "이력"
grep -q "배포 완료" "$T/w/notified" && ok "배포 완료를 알린다" || fail "완료 알림"

set_img remote.auth-server ccc3; echo sha256:ccc3 > "$T/w/broken"; touch "$T/w/hook-down"
if run >/dev/null 2>&1; then fail "실패한 배포는 0이 아닌 값으로 끝나야 한다"; fi
grep -q "되돌림" "$T/w/notified" && fail "웹훅이 죽어 있으면 알림이 가지 않아야 한다"
rm "$T/w/hook-down"; run >/dev/null
grep -q "되돌림" "$T/w/notified" && ok "보내지 못한 되돌림 알림은 다음 실행 때 다시 보낸다" || fail "알림 재전송"
[ "$(cat "$T/w/run.auth-server")" = sha256:bbb2 ] && ok "새 이미지가 응답하지 않으면 직전 이미지로 되돌린다" || fail "되돌리기"
before=$(ups); run >/dev/null
[ "$(ups)" = "$before" ] && ok "실패한 이미지는 다음 이미지가 올 때까지 다시 시도하지 않는다" || fail "재시도 금지"

set_img remote.auth-server ddd4
run >/dev/null
[ "$(cat "$T/w/run.auth-server")" = sha256:ddd4 ] && ok "더 새로운 이미지가 오면 다시 배포한다" || fail "다음 이미지"

run pause "금요일 촬영" >/dev/null; set_img remote.web eee5; before=$(ups); run >/dev/null
[ "$(ups)" = "$before" ] && ok "멈춤 상태에서는 배포하지 않는다" || fail "멈춤"
run resume >/dev/null; run >/dev/null
[ "$(cat "$T/w/run.web")" = sha256:eee5 ] && ok "다시 켜면 밀린 이미지를 배포한다" || fail "다시 켜기"
set_img remote.auth-server fff6; set_img remote.web fff6; touch "$T/w/pull-fail.auth-server"
if run >/dev/null 2>&1; then fail "받기에 실패하면 0이 아닌 값으로 끝나야 한다"; fi
[ "$(cat "$T/w/run.auth-server")" = sha256:ddd4 ] && [ "$(cat "$T/w/run.web")" = sha256:fff6 ] && ok "한 서비스의 받기가 실패해도 나머지는 배포한다" || fail "받기 실패"
rm "$T/w/pull-fail.auth-server"; run >/dev/null
out=$(run status)
grep -q "web  *fff6000  *fff6000  *최신" <<<"$out" && ! grep -q chat-server <<<"$out" && ok "status가 서비스별 버전을 보여 준다" || fail "status"

# ── 무중단 교체 ──
export TRACE_DEPLOY_ROLLING="gateway auth-server"
run_of() { cat "$T/w/run.$1" 2>/dev/null || cat "$T/w/run2.$1"; }
count() { ls "$T/w" | grep -c "^run2\?\.$1\$"; }
: > "$T/w/stops"; : > "$T/w/reloads"

set_img remote.auth-server ggg7
run >/dev/null
[ "$(tail -n 1 "$T/w/ups")" = "up auth-server sha256:ggg7" ] && ok "gateway 이미지에 표시가 없으면 서버는 예전처럼 다시 만든다" || fail "표시 없음"

echo 1 > "$T/w/gateway-label"; set_img remote.auth-server hhh8
run >/dev/null
[ "$(tail -n 1 "$T/w/ups")" = "roll auth-server sha256:hhh8" ] && [ "$(run_of auth-server)" = sha256:hhh8 ] && [ "$(count auth-server)" = 1 ] \
  && grep -q "stop cid-auth-server" "$T/w/stops" && ok "무중단 교체: 새 컨테이너를 먼저 띄우고 준비된 뒤 옛 것을 내린다" || fail "무중단 교체"
grep -q "무중단 교체" "$T/home/.cache/trace-deploy/history.log" && ok "이력에 무중단 교체로 남는다" || fail "무중단 이력"

set_img remote.auth-server iii9; echo sha256:iii9 > "$T/w/broken"; stops=$(wc -l < "$T/w/stops")
if run >/dev/null 2>&1; then fail "준비되지 않은 새 버전은 0이 아닌 값으로 끝나야 한다"; fi
[ "$(run_of auth-server)" = sha256:hhh8 ] && [ "$(count auth-server)" = 1 ] && [ "$(wc -l < "$T/w/stops")" = "$stops" ] \
  && [ "$(cat "$T/w/tag.auth-server")" = sha256:hhh8 ] && ok "새 버전이 준비되지 않으면 옛 컨테이너를 건드리지 않고 새 것만 지운다" || fail "준비 실패"
grep -q "끊김 없음" "$T/w/notified" && ok "끊김 없이 실패했다고 알린다" || fail "준비 실패 알림"

set_img remote.gateway jjj1
run >/dev/null
[ "$(run_of gateway)" = sha256:jjj1 ] && [ "$(grep -c "nginx -s reload" "$T/w/reloads")" = 2 ] && ok "gateway를 바꿀 때는 옛 것을 내리기 전과 뒤에 web nginx를 reload 한다" || fail "gateway 교체"

cp "$T/w/run2.auth-server" "$T/w/run.auth-server" 2>/dev/null || cp "$T/w/run.auth-server" "$T/w/run2.auth-server"
set_img remote.auth-server kkk2; run >/dev/null
[ "$(count auth-server)" = 1 ] && [ "$(run_of auth-server)" = sha256:kkk2 ] && ok "앞 실행이 남긴 여분 컨테이너를 정리하고 교체한다" || fail "여분 정리"

before=$(ups); run roll auth-server >/dev/null
[ "$(ups)" = $((before + 1)) ] && [ "$(count auth-server)" = 1 ] && [ "$(run_of auth-server)" = sha256:kkk2 ] && ok "roll은 같은 이미지로 무중단 교체를 한 번 한다" || fail "roll"
if run roll web >/dev/null 2>&1; then fail "web은 무중단 교체 대상이 아니어야 한다"; else ok "web은 무중단 교체 대상이 아니다"; fi
run probe auth-server 1 | grep -q "실패 0" && ok "probe가 성공·실패 수를 센다" || fail "probe"

# 여기부터는 auth-server가 cid-(먼저 만든 것) 하나로 도는 상태에서 시작한다
[ -f "$T/w/run.auth-server" ] || mv "$T/w/run2.auth-server" "$T/w/run.auth-server"
set_img tag.auth-server mmm4; before=$(ups)
if run roll auth-server >/dev/null 2>&1; then fail "받아 둔 이미지가 다르면 roll은 거부해야 한다"; fi
[ "$(ups)" = "$before" ] && ok "받아 두기만 한 새 이미지가 있으면 roll을 거부한다" || fail "roll 거부"
set_img tag.auth-server kkk2

set_img remote.auth-server nnn5; touch "$T/w/scale-fail.auth-server"
if run >/dev/null 2>&1; then fail "새 컨테이너 띄우기가 실패하면 0이 아닌 값으로 끝나야 한다"; fi
[ "$(count auth-server)" = 1 ] && [ "$(cat "$T/w/run.auth-server")" = sha256:kkk2 ] && ok "새 컨테이너 띄우기가 실패하면 만들어진 것만 지우고 옛 것을 둔다" || fail "띄우기 실패 정리"
rm "$T/w/scale-fail.auth-server"

set_img remote.auth-server qqq7; touch "$T/w/rm-fail"; : > "$T/w/notified"
run >/dev/null 2>&1
rm "$T/w/rm-fail"
[ "$(run_of auth-server)" = sha256:qqq7 ] && grep -q "지워지지 않았습니다" "$T/w/notified" && grep -q "배포 완료" "$T/w/notified" \
  && ok "멈춘 옛 컨테이너가 지워지지 않으면 배포는 마치고 따로 알린다" || fail "삭제 실패"
rm -f "$T/w"/*.stopped; [ -f "$T/w/run.auth-server" ] || mv "$T/w/run2.auth-server" "$T/w/run.auth-server"

set_img remote.auth-server rrr8; set_img run2.auth-server rrr8; touch "$T/w/created-fail"
if run >/dev/null 2>&1; then fail "만든 시각을 읽지 못하면 0이 아닌 값으로 끝나야 한다"; fi
[ "$(count auth-server)" = 2 ] && ok "컨테이너가 둘인데 만든 시각을 읽지 못하면 아무것도 지우지 않는다" || fail "만든 시각 실패"
rm "$T/w/created-fail" "$T/w/run2.auth-server"

# 앞 실행이 새 컨테이너를 띄운 직후 죽은 경우: 확인되지 않은 새 것(응답 없음)이 남아 있다
set_img remote.auth-server ppp6; set_img run2.auth-server ppp6; echo sha256:ppp6 > "$T/w/broken"
if run >/dev/null 2>&1; then fail "확인되지 않은 새 컨테이너는 0이 아닌 값으로 끝나야 한다"; fi
[ "$(count auth-server)" = 1 ] && [ "$(cat "$T/w/run.auth-server")" = sha256:qqq7 ] && ok "남아 있던 확인되지 않은 새 컨테이너 대신 요청을 받던 옛 것을 남긴다" || fail "미확인 컨테이너"
: > "$T/w/broken"
echo latest > "$T/w/tagname.web"; set_img remote.web lll3; before=$(ups)
if run >/dev/null 2>&1; then fail "태그가 다른 컨테이너는 0이 아닌 값으로 끝나야 한다"; fi
[ "$(ups)" = "$before" ] && ok "compose 설정과 다른 태그로 뜬 컨테이너는 건드리지 않고 알린다" || fail "태그 불일치"
rm -f "$T/w/tagname.web"; echo gateway > "$T/w/imgname.web"; before=$(ups)
if run >/dev/null 2>&1; then fail "다른 서비스의 이미지로 뜬 컨테이너는 0이 아닌 값으로 끝나야 한다"; fi
[ "$(ups)" = "$before" ] && ok "다른 서비스의 이미지로 뜬 컨테이너는 목록에 있는 이미지여도 건드리지 않는다" || fail "다른 서비스 이미지"
rm -f "$T/w/imgname.web"
echo "모두 통과"
