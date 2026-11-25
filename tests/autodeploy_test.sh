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
    ps) if [ "$2" = -q ] && [ -f "$W/ps-fail.$3" ]; then   # 남은 횟수가 0이 되는 조회만 실패한다
          n=$(cat "$W/ps-fail.$3"); n=$((n - 1)); echo "$n" > "$W/ps-fail.$3"; [ "$n" = 0 ] && exit 1
        fi
        [ -f "$W/run.$3" ] && echo "cid-$3"; [ -f "$W/run2.$3" ] && echo "cid2-$3"
        case "$2" in *a*) [ -f "$W/run.$3.stopped" ] && echo "cid-$3"; [ -f "$W/run2.$3.stopped" ] && echo "cid2-$3" ;; esac ;;
    pull) shift 2; for s in "$@"; do [ -e "$W/pull-fail.$s" ] && exit 1; [ -f "$W/remote.$s" ] && cp "$W/remote.$s" "$W/tag.$s"; done ;;
    up) s="${*: -1}"
      case "$*" in
        *--scale*) [ -e "$W/scale-fail.$s" ] && { cp "$W/tag.$s" "$W/run2.$s"; exit 1; }
                   if [ -f "$W/run.$s" ]; then cp "$W/tag.$s" "$W/run2.$s"; else cp "$W/tag.$s" "$W/run.$s"; fi
                   echo "roll $s $(cat "$W/tag.$s")" >> "$W/ups" ;;
        *) [ "$(cat "$W/up-fail.$s" 2>/dev/null)" = "$(cat "$W/tag.$s")" ] && exit 1
           rm -f "$W/run2.$s"; cp "$W/tag.$s" "$W/run.$s"; echo "up $s $(cat "$W/tag.$s")" >> "$W/ups" ;;
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
    # 이미지 ID만 넘긴 조회(되돌리기 전 확인)는 w/image-fail이 있으면 그 내용을 오류로 내고 실패한다
    if [ "$3" != -f ] && [ -e "$W/image-fail" ]; then cat "$W/image-fail" >&2; exit 1; fi
    case "$4" in
      *.Id*) cat "$W/tag.$(svc_of "$5")" ;;
      *) id="$5"; case "$id" in ghcr.io/*) id=$(cat "$W/tag.$(svc_of "$id")") ;; esac; echo "APP_COMMIT=${id#sha256:}0000000" ;;
    esac ;;
  tag) echo "$2" > "$W/tag.$(svc_of "$3")" ;;
  stop) echo "stop ${*: -1}" >> "$W/stops" ;;
  rm) f=$(file_of "${*: -1}"); if [ -e "$W/rm-fail" ]; then [ -f "$f" ] && mv "$f" "$f.stopped"; exit 1; fi; rm -f "$f" "$f.stopped" ;;
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
# ── 가짜 환경 설정 ──
# 가짜 docker·curl이 먼저 불리도록 PATH 앞에 두고, 배포 스크립트가 읽는 환경 변수를 시험용 값으로 둔다.
# TRACE_DEPLOY_WAIT·STEP: 새 컨테이너가 응답하는지 최대 몇 초까지, 몇 초마다 확인할지(시험이라 짧게).
export PATH="$T/bin:$PATH" FAKE_WORLD="$T/w" HOME="$T/home" TRACE_COMPOSE_DIR="$T/compose"
export TRACE_DEPLOY_SERVICES="auth-server gateway web chat-server" TRACE_DEPLOY_WAIT=2 TRACE_DEPLOY_STEP=1
export TRACE_DEPLOY_SETTLE=0 TRACE_DEPLOY_ROLLING=""   # 앞부분은 예전 방식(다시 만들기)으로 본다
# 알림(웹훅) 주소. 가짜 curl이 받아서 w/notified에 적기만 한다(example.invalid는 없는 주소라 실제로 나가지 않음).
export TRACE_ALERT_WEBHOOK_URL="https://example.invalid/hooks/x"
# 도우미 함수
#   run     : 배포 스크립트(autodeploy.sh)를 한 번 실행한다. 학교 서버에서는 3분마다 돈다
#   set_img : 가짜 세계의 이미지 값을 바꾼다(예: set_img remote.web bbb2 = 레지스트리에 web 새 이미지 bbb2가 올라옴)
#   ups     : 지금까지 컨테이너를 다시 띄운 횟수
#   ok·fail : 확인 결과를 찍는다. 하나라도 fail이면 바로 멈춘다
run() { bash "$ROOT/compose/ops/autodeploy.sh" "$@"; }
set_img() { echo "sha256:$2" > "$T/w/$1"; }
ups() { wc -l < "$T/w/ups" 2>/dev/null || echo 0; }
ok() { echo "ok - $1"; }
fail() { echo "not ok - $1"; exit 1; }
# 시작 상태: 서비스 3개(auth-server·gateway·web)가 모두 같은 이미지 aaa1로 돌고, 레지스트리에도 새 것이 없다.
: > "$T/w/broken"; : > "$T/w/ups"; : > "$T/w/notified"
for s in auth-server gateway web; do set_img "tag.$s" aaa1; set_img "run.$s" aaa1; set_img "remote.$s" aaa1; done

# [상황] 레지스트리에 새 이미지가 없다.
# [기대] 아무 컨테이너도 다시 띄우지 않는다.
run >/dev/null
[ "$(ups)" = 0 ] && ok "바뀐 이미지가 없으면 아무것도 다시 띄우지 않는다" || fail "변화 없음"

# [상황] auth-server 새 이미지(bbb2)가 올라왔고 정상으로 응답한다.
# [기대] auth-server만 교체하고, 배포 이력(history.log)에 남기고, '배포 완료' 알림을 보낸다.
set_img remote.auth-server bbb2
run >/dev/null
[ "$(cat "$T/w/run.auth-server")" = sha256:bbb2 ] && [ "$(ups)" = 1 ] && ok "새 이미지가 응답하면 그 서비스만 교체한다" || fail "정상 교체"
grep -q "auth-server aaa1000 bbb2000 ok" "$T/home/.cache/trace-deploy/history.log" && ok "배포 이력을 남긴다" || fail "이력"
grep -q "배포 완료" "$T/w/notified" && ok "배포 완료를 알린다" || fail "완료 알림"

# [상황] 새 이미지(ccc3)가 떠도 응답하지 않고(broken), 마침 알림 웹훅도 죽어 있다(hook-down).
# [기대] 배포는 실패로 끝나고(0이 아닌 종료 코드) 직전 이미지(bbb2)로 되돌린다.
#        못 보낸 되돌림 알림은 웹훅이 살아난 다음 실행 때 다시 보낸다.
#        실패한 이미지는 더 새 이미지가 올 때까지 다시 시도하지 않는다(3분마다 같은 실패를 반복하지 않게).
set_img remote.auth-server ccc3; echo sha256:ccc3 > "$T/w/broken"; touch "$T/w/hook-down"
if run >/dev/null 2>&1; then fail "실패한 배포는 0이 아닌 값으로 끝나야 한다"; fi
grep -q "되돌림" "$T/w/notified" && fail "웹훅이 죽어 있으면 알림이 가지 않아야 한다"
rm "$T/w/hook-down"; run >/dev/null
grep -q "되돌림" "$T/w/notified" && ok "보내지 못한 되돌림 알림은 다음 실행 때 다시 보낸다" || fail "알림 재전송"
[ "$(cat "$T/w/run.auth-server")" = sha256:bbb2 ] && ok "새 이미지가 응답하지 않으면 직전 이미지로 되돌린다" || fail "되돌리기"
before=$(ups); run >/dev/null
[ "$(ups)" = "$before" ] && ok "실패한 이미지는 다음 이미지가 올 때까지 다시 시도하지 않는다" || fail "재시도 금지"

# [상황] 실패한 ccc3 다음으로 더 새 이미지(ddd4)가 올라왔다.
# [기대] 다시 배포한다.
set_img remote.auth-server ddd4
run >/dev/null
[ "$(cat "$T/w/run.auth-server")" = sha256:ddd4 ] && ok "더 새로운 이미지가 오면 다시 배포한다" || fail "다음 이미지"

# [상황] 촬영·시연 중이라 배포를 멈춰 두었다(pause). 그사이 web 새 이미지가 올라온다.
# [기대] 멈춘 동안은 배포하지 않고, 다시 켜면(resume) 밀린 이미지를 배포한다.
run pause "금요일 촬영" >/dev/null; set_img remote.web eee5; before=$(ups); run >/dev/null
[ "$(ups)" = "$before" ] && ok "멈춤 상태에서는 배포하지 않는다" || fail "멈춤"
run resume >/dev/null; run >/dev/null
[ "$(cat "$T/w/run.web")" = sha256:eee5 ] && ok "다시 켜면 밀린 이미지를 배포한다" || fail "다시 켜기"
# [상황] auth-server·web 둘 다 새 이미지가 왔는데 auth-server 이미지 받기(pull)만 실패한다.
# [기대] 실패로 끝나지만 web은 배포한다(한 서비스 때문에 전체가 멈추지 않게).
#        status 명령은 서비스별 지금 버전·최신 버전을 표로 보여 주고, compose에 없는 chat-server는 보여 주지 않는다.
set_img remote.auth-server fff6; set_img remote.web fff6; touch "$T/w/pull-fail.auth-server"
if run >/dev/null 2>&1; then fail "받기에 실패하면 0이 아닌 값으로 끝나야 한다"; fi
[ "$(cat "$T/w/run.auth-server")" = sha256:ddd4 ] && [ "$(cat "$T/w/run.web")" = sha256:fff6 ] && ok "한 서비스의 받기가 실패해도 나머지는 배포한다" || fail "받기 실패"
rm "$T/w/pull-fail.auth-server"; run >/dev/null
out=$(run status)
grep -q "web  *fff6000  *fff6000  *최신" <<<"$out" && ! grep -q chat-server <<<"$out" && ok "status가 서비스별 버전을 보여 준다" || fail "status"

# ── 무중단 교체 ──
# 무중단 교체 = 새 컨테이너를 옆에 하나 더 띄워 응답을 확인한 뒤 옛 것을 내리는 방식(교체 중에도 요청이 끊기지 않음).
# gateway·auth-server만 이 방식으로 바꾼다. run_of는 지금 도는 이미지, count는 그 서비스의 컨테이너 수를 읽는다.
export TRACE_DEPLOY_ROLLING="gateway auth-server"
run_of() { cat "$T/w/run.$1" 2>/dev/null || cat "$T/w/run2.$1"; }
count() { ls "$T/w" | grep -c "^run2\?\.$1\$"; }
: > "$T/w/stops"; : > "$T/w/reloads"

# [상황] 무중단 교체 대상이지만 gateway 이미지에 '무중단 지원' 표시(라벨)가 아직 없다.
# [기대] 예전처럼 컨테이너를 다시 만드는 방식으로 교체한다.
set_img remote.auth-server ggg7
run >/dev/null
[ "$(tail -n 1 "$T/w/ups")" = "up auth-server sha256:ggg7" ] && ok "gateway 이미지에 표시가 없으면 서버는 예전처럼 다시 만든다" || fail "표시 없음"

# [상황] gateway에 '무중단 지원' 표시가 생겼고 auth-server 새 이미지(hhh8)가 온다.
# [기대] 새 컨테이너를 먼저 띄우고 응답을 확인한 뒤 옛 컨테이너를 내린다. 끝나면 하나만 남고 이력에 '무중단 교체'로 적힌다.
echo 1 > "$T/w/gateway-label"; set_img remote.auth-server hhh8
run >/dev/null
[ "$(tail -n 1 "$T/w/ups")" = "roll auth-server sha256:hhh8" ] && [ "$(run_of auth-server)" = sha256:hhh8 ] && [ "$(count auth-server)" = 1 ] \
  && grep -q "stop cid-auth-server" "$T/w/stops" && ok "무중단 교체: 새 컨테이너를 먼저 띄우고 준비된 뒤 옛 것을 내린다" || fail "무중단 교체"
grep -q "무중단 교체" "$T/home/.cache/trace-deploy/history.log" && ok "이력에 무중단 교체로 남는다" || fail "무중단 이력"

# [상황] 새 이미지(iii9)로 옆에 띄운 컨테이너가 응답하지 않는다.
# [기대] 옛 컨테이너는 그대로 두고(요청이 끊기지 않음) 새 것만 지운다. 받아 둔 태그도 옛 이미지로 돌리고, '끊김 없음'을 넣어 실패를 알린다.
set_img remote.auth-server iii9; echo sha256:iii9 > "$T/w/broken"; stops=$(wc -l < "$T/w/stops")
if run >/dev/null 2>&1; then fail "준비되지 않은 새 버전은 0이 아닌 값으로 끝나야 한다"; fi
[ "$(run_of auth-server)" = sha256:hhh8 ] && [ "$(count auth-server)" = 1 ] && [ "$(wc -l < "$T/w/stops")" = "$stops" ] \
  && [ "$(cat "$T/w/tag.auth-server")" = sha256:hhh8 ] && ok "새 버전이 준비되지 않으면 옛 컨테이너를 건드리지 않고 새 것만 지운다" || fail "준비 실패"
grep -q "끊김 없음" "$T/w/notified" && ok "끊김 없이 실패했다고 알린다" || fail "준비 실패 알림"

# [상황] gateway 자체를 교체한다.
# [기대] web의 nginx가 새 gateway를 찾도록 옛 것을 내리기 전과 뒤에 한 번씩(모두 2번) reload 한다.
set_img remote.gateway jjj1
run >/dev/null
[ "$(run_of gateway)" = sha256:jjj1 ] && [ "$(grep -c "nginx -s reload" "$T/w/reloads")" = 2 ] && ok "gateway를 바꿀 때는 옛 것을 내리기 전과 뒤에 web nginx를 reload 한다" || fail "gateway 교체"

# [상황] 앞 실행이 도중에 끊겨 auth-server 컨테이너가 2개 남아 있다.
# [기대] 여분을 정리하고 새 이미지(kkk2)로 교체해 하나만 남긴다.
cp "$T/w/run2.auth-server" "$T/w/run.auth-server" 2>/dev/null || cp "$T/w/run.auth-server" "$T/w/run2.auth-server"
set_img remote.auth-server kkk2; run >/dev/null
[ "$(count auth-server)" = 1 ] && [ "$(run_of auth-server)" = sha256:kkk2 ] && ok "앞 실행이 남긴 여분 컨테이너를 정리하고 교체한다" || fail "여분 정리"

# [상황] 사람이 roll 명령으로 같은 이미지 그대로 무중단 재시작을 요청한다.
# [기대] 한 번만 교체한다. 무중단 대상이 아닌 web은 거부한다.
#        probe는 응답 확인을 정해진 횟수만큼 해 보고 성공·실패 수를 센다.
before=$(ups); run roll auth-server >/dev/null
[ "$(ups)" = $((before + 1)) ] && [ "$(count auth-server)" = 1 ] && [ "$(run_of auth-server)" = sha256:kkk2 ] && ok "roll은 같은 이미지로 무중단 교체를 한 번 한다" || fail "roll"
if run roll web >/dev/null 2>&1; then fail "web은 무중단 교체 대상이 아니어야 한다"; else ok "web은 무중단 교체 대상이 아니다"; fi
run probe auth-server 1 | grep -q "실패 0" && ok "probe가 성공·실패 수를 센다" || fail "probe"

# 여기부터는 auth-server가 cid-(먼저 만든 것) 하나로 도는 상태에서 시작한다
[ -f "$T/w/run.auth-server" ] || mv "$T/w/run2.auth-server" "$T/w/run.auth-server"
# [상황] 새 이미지를 받아 두기만 하고(태그만 바뀜) 아직 배포하지 않은 상태에서 roll을 부른다.
# [기대] 거부한다(재시작인 줄 알았는데 새 버전이 함께 올라가는 것을 막음).
set_img tag.auth-server mmm4; before=$(ups)
if run roll auth-server >/dev/null 2>&1; then fail "받아 둔 이미지가 다르면 roll은 거부해야 한다"; fi
[ "$(ups)" = "$before" ] && ok "받아 두기만 한 새 이미지가 있으면 roll을 거부한다" || fail "roll 거부"
set_img tag.auth-server kkk2

# [상황] 옆에 새 컨테이너를 띄우는 것 자체가 실패한다(scale-fail).
# [기대] 반쯤 만들어진 새 것만 지우고 옛 컨테이너는 그대로 둔다.
set_img remote.auth-server nnn5; touch "$T/w/scale-fail.auth-server"
if run >/dev/null 2>&1; then fail "새 컨테이너 띄우기가 실패하면 0이 아닌 값으로 끝나야 한다"; fi
[ "$(count auth-server)" = 1 ] && [ "$(cat "$T/w/run.auth-server")" = sha256:kkk2 ] && ok "새 컨테이너 띄우기가 실패하면 만들어진 것만 지우고 옛 것을 둔다" || fail "띄우기 실패 정리"
rm "$T/w/scale-fail.auth-server"

# [상황] 교체는 됐는데 멈춘 옛 컨테이너가 지워지지 않는다(rm-fail).
# [기대] 배포는 마치고 '지워지지 않았습니다'를 따로 알린다. 남은 것은 다음 교체(sss9) 전에 지운다.
set_img remote.auth-server qqq7; touch "$T/w/rm-fail"; : > "$T/w/notified"
run >/dev/null 2>&1
rm "$T/w/rm-fail"
[ "$(run_of auth-server)" = sha256:qqq7 ] && grep -q "지워지지 않았습니다" "$T/w/notified" && grep -q "배포 완료" "$T/w/notified" \
  && ok "멈춘 옛 컨테이너가 지워지지 않으면 배포는 마치고 따로 알린다" || fail "삭제 실패"
set_img remote.auth-server sss9; before=$(ups); run >/dev/null 2>&1
[ -z "$(ls "$T/w" | grep stopped)" ] && [ "$(count auth-server)" = 1 ] && [ "$(run_of auth-server)" = sha256:sss9 ] && [ "$(ups)" = $((before + 1)) ] \
  && ok "멈춘 채 남은 옛 컨테이너는 다음 교체 전에 지운다" || fail "멈춘 컨테이너 정리"
[ -f "$T/w/run.auth-server" ] || mv "$T/w/run2.auth-server" "$T/w/run.auth-server"

# [상황] 컨테이너가 2개인데 어느 쪽이 먼저 만들어졌는지(만든 시각) 읽지 못한다.
# [기대] 잘못 지울 수 있으니 아무것도 지우지 않고 실패로 끝낸다.
set_img remote.auth-server rrr8; set_img run2.auth-server rrr8; touch "$T/w/created-fail"
if run >/dev/null 2>&1; then fail "만든 시각을 읽지 못하면 0이 아닌 값으로 끝나야 한다"; fi
[ "$(count auth-server)" = 2 ] && ok "컨테이너가 둘인데 만든 시각을 읽지 못하면 아무것도 지우지 않는다" || fail "만든 시각 실패"
rm "$T/w/created-fail" "$T/w/run2.auth-server"

# 앞 실행이 새 컨테이너를 띄운 직후 죽은 경우: 확인되지 않은 새 것(응답 없음)이 남아 있다
# [기대] 확인되지 않은 새 것 대신, 요청을 받던 옛 컨테이너(sss9)를 남긴다.
set_img remote.auth-server ppp6; set_img run2.auth-server ppp6; echo sha256:ppp6 > "$T/w/broken"
if run >/dev/null 2>&1; then fail "확인되지 않은 새 컨테이너는 0이 아닌 값으로 끝나야 한다"; fi
[ "$(count auth-server)" = 1 ] && [ "$(cat "$T/w/run.auth-server")" = sha256:sss9 ] && ok "남아 있던 확인되지 않은 새 컨테이너 대신 요청을 받던 옛 것을 남긴다" || fail "미확인 컨테이너"
: > "$T/w/broken"
# [상황] web 컨테이너가 compose 설정(develop)과 다른 태그(latest)로, 또는 다른 서비스의 이미지로 떠 있다(사람이 손으로 띄운 경우 등).
# [기대] 건드리지 않고 실패로 알린다(일부러 띄운 것을 덮어쓰지 않게).
echo latest > "$T/w/tagname.web"; set_img remote.web lll3; before=$(ups)
if run >/dev/null 2>&1; then fail "태그가 다른 컨테이너는 0이 아닌 값으로 끝나야 한다"; fi
[ "$(ups)" = "$before" ] && ok "compose 설정과 다른 태그로 뜬 컨테이너는 건드리지 않고 알린다" || fail "태그 불일치"
rm -f "$T/w/tagname.web"; echo gateway > "$T/w/imgname.web"; before=$(ups)
if run >/dev/null 2>&1; then fail "다른 서비스의 이미지로 뜬 컨테이너는 0이 아닌 값으로 끝나야 한다"; fi
[ "$(ups)" = "$before" ] && ok "다른 서비스의 이미지로 뜬 컨테이너는 목록에 있는 이미지여도 건드리지 않는다" || fail "다른 서비스 이미지"
rm -f "$T/w/imgname.web"

# ── 되돌리기 실패 뒤 다시 시도 ──
# 되돌리기 표식: ~/.cache/trace-deploy/<서비스>.rollback 파일. "직전 이미지 ID + 태그"를 적어 두고, 되돌리기를 끝내면 지운다.
# [상황] 새 이미지(ttt1)가 응답하지 않아 되돌리려는데, 되돌리기(직전 이미지로 다시 띄우기)까지 실패한다(up-fail).
# [기대] 이력에 rollback-failed를 남기고, 다음 실행에서 되돌리기를 다시 해 직전 이미지로 돌아간다.
#        되돌린 뒤에는 실패한 이미지를 다시 띄우지 않는다.
: > "$T/w/broken"; run >/dev/null 2>&1 || true
prev=$(cat "$T/w/run.web"); set_img remote.web ttt1; echo sha256:ttt1 > "$T/w/broken"; echo "$prev" > "$T/w/up-fail.web"
if run >/dev/null 2>&1; then fail "되돌리기까지 실패하면 0이 아닌 값으로 끝나야 한다"; fi
[ "$(cat "$T/w/run.web")" = sha256:ttt1 ] && grep -q "rollback-failed" "$T/home/.cache/trace-deploy/history.log" || fail "되돌리기 실패 준비"
rm "$T/w/up-fail.web"; run >/dev/null 2>&1 || true
[ "$(cat "$T/w/run.web")" = "$prev" ] && ok "끝내지 못한 되돌리기는 다음 실행에서 다시 한다" || fail "되돌리기 재시도"
before=$(ups); run >/dev/null 2>&1 || true
[ "$(ups)" = "$before" ] && ok "되돌린 뒤에는 실패한 이미지를 다시 띄우지 않는다" || fail "되돌린 뒤 재시도"

# ── 되돌리기 실패 뒤 컨테이너가 죽었거나 이미지를 받지 못해도 다시 시도 ──
# [상황] 되돌리기가 실패한 뒤, 다음 실행 전에 그 컨테이너가 죽었고 이미지 받기도 실패한다.
# [기대] 그래도 표식을 보고 직전 이미지로 되돌린다.
set_img remote.web uuu1; echo sha256:uuu1 > "$T/w/broken"; echo "$prev" > "$T/w/up-fail.web"
run >/dev/null 2>&1 || true
[ -s "$T/home/.cache/trace-deploy/web.rollback" ] || fail "되돌리기 표식 준비"
rm "$T/w/up-fail.web"; rm "$T/w/run.web"; touch "$T/w/pull-fail.web"
run >/dev/null 2>&1 || true
[ "$(cat "$T/w/run.web" 2>/dev/null)" = "$prev" ] && ok "실패한 컨테이너가 죽고 이미지를 받지 못해도 끝내지 못한 되돌리기를 다시 한다" || fail "죽은 뒤 되돌리기 재시도"
rm "$T/w/pull-fail.web"; : > "$T/w/broken"

# ── 되돌리기 표식의 태그가 지금 compose 설정과 다르면 다시 하지 않고 표식을 남긴다 ──
# [상황] 표식에는 latest 태그가 적혀 있는데 지금 compose 설정은 develop이다.
# [기대] 설정이 바뀐 것일 수 있으니 되돌리지 않고 실패로 알리며, 표식은 사람이 보도록 남긴다.
echo "sha256:old1 ghcr.io/gakdo/web:latest" > "$T/home/.cache/trace-deploy/web.rollback"; before=$(ups)
if run >/dev/null 2>&1; then fail "되돌리기 표식의 태그가 다르면 0이 아닌 값으로 끝나야 한다"; fi
[ "$(ups)" = "$before" ] && [ -s "$T/home/.cache/trace-deploy/web.rollback" ] && ok "되돌리기 표식의 태그가 compose 설정과 다르면 건드리지 않고 표식을 남긴다" || fail "되돌리기 태그 불일치"
rm "$T/home/.cache/trace-deploy/web.rollback"

# ── 직전 버전이 떠 있어도 응답하지 않으면 되돌리기 표식을 지우지 않는다 ──
# [상황] 표식의 직전 버전이 이미 떠 있지만 응답하지 않는다.
# [기대] 되돌리기가 끝난 게 아니므로 표식을 남긴다. 응답하게 되면 그때 표식을 지운다.
cur=$(cat "$T/w/run.web"); echo "$cur ghcr.io/gakdo/web:develop" > "$T/home/.cache/trace-deploy/web.rollback"; echo "$cur" > "$T/w/broken"
if run >/dev/null 2>&1; then fail "직전 버전이 응답하지 않으면 0이 아닌 값으로 끝나야 한다"; fi
[ -s "$T/home/.cache/trace-deploy/web.rollback" ] && ok "직전 버전이 떠 있어도 응답하지 않으면 되돌리기 표식을 남긴다" || fail "응답 없는 직전 버전"
: > "$T/w/broken"; run >/dev/null 2>&1 || true
[ ! -e "$T/home/.cache/trace-deploy/web.rollback" ] && ok "직전 버전이 응답하면 되돌리기 표식을 지운다" || fail "표식 정리"

# ── 직전 이미지 확인이 잠깐 실패하면 표식을 남기고, 이미지가 정말 없을 때만 그만둔다 ──
# [상황] 직전 이미지가 있는지 확인하려는데 Docker에 잠깐 연결이 안 된다. 그다음엔 "이미지 없음"이라는 확실한 답이 온다.
# [기대] 잠깐 실패는 표식을 남겨 다음에 다시 하고, 이미지가 정말 없을 때만 되돌리기를 그만둔다(표식 삭제).
echo "sha256:old1 ghcr.io/gakdo/web:develop" > "$T/home/.cache/trace-deploy/web.rollback"; echo "Cannot connect to the Docker daemon" > "$T/w/image-fail"
if run >/dev/null 2>&1; then fail "직전 이미지를 확인하지 못하면 0이 아닌 값으로 끝나야 한다"; fi
[ -s "$T/home/.cache/trace-deploy/web.rollback" ] && ok "직전 이미지 확인이 실패하면 되돌리기 표식을 남긴다" || fail "이미지 확인 실패"
echo "Error response from daemon: No such image: sha256:old1" > "$T/w/image-fail"; run >/dev/null 2>&1 || true
[ ! -e "$T/home/.cache/trace-deploy/web.rollback" ] && ok "직전 이미지가 정말 없으면 되돌리기를 그만둔다" || fail "없는 이미지"
rm "$T/w/image-fail"

# ── 컨테이너 목록 조회가 실패하면 지우지 않는다 ──
# [상황] 새 web 이미지로 바꾸는 도중 컨테이너 목록 조회(docker compose ps)가 실패한다.
# [기대] 무엇이 떠 있는지 모르니 도는 컨테이너를 지우지 않고 "목록을 읽지 못해"로 실패를 알린다.
set_img remote.web vvv1; echo 3 > "$T/w/ps-fail.web"
if out=$(run 2>&1); then fail "목록 조회가 실패하면 0이 아닌 값으로 끝나야 한다"; fi
grep -q "목록을 읽지 못해" <<<"$out" && [ -f "$T/w/run.web" ] && ok "컨테이너 목록을 읽지 못하면 도는 컨테이너를 지우지 않는다" || fail "목록 조회 실패 때 삭제"
rm -f "$T/w/ps-fail.web"
echo "모두 통과"
