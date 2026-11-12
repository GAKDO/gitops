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
W="$FAKE_WORLD"
svc_of() { echo "${1#ghcr.io/gakdo/}" | cut -d: -f1; }
if [ "$1" = compose ]; then
  shift
  case "$1" in
    config)
      printf '%s\n' auth-server web postgres ;;
    ps) [ -f "$W/run.$3" ] && echo "cid-$3" ;;
    pull) shift 2; for s in "$@"; do [ -f "$W/remote.$s" ] && cp "$W/remote.$s" "$W/tag.$s"; done ;;
    up) s="${*: -1}"; cp "$W/tag.$s" "$W/run.$s"; echo "up $s $(cat "$W/tag.$s")" >> "$W/ups" ;;
    logs) echo "(가짜 로그)" ;;
  esac
  exit 0
fi
case "$1" in
  inspect)
    s="${4#cid-}"
    case "$3" in *State.Status*) echo "running 0" ;; *Config.Image*) echo "ghcr.io/gakdo/$s:develop" ;; *) cat "$W/run.$s" ;; esac ;;
  image)
    case "$4" in
      *.Id*) cat "$W/tag.$(svc_of "$5")" ;;
      *) id="$5"; case "$id" in ghcr.io/*) id=$(cat "$W/tag.$(svc_of "$id")") ;; esac; echo "APP_COMMIT=${id#sha256:}0000000" ;;
    esac ;;
  tag) cp /dev/null "$W/tag.$(svc_of "$3")"; echo "$2" > "$W/tag.$(svc_of "$3")" ;;
esac
FAKE
cat > "$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
W="$FAKE_WORLD"; url="${*: -1}"
case "$url" in
  http://*auth/ping) s=auth-server ;; http://*version.txt) s=web ;;
  *hooks*) [ -e "$W/hook-down" ] && exit 7; echo "$*" >> "$W/notified"; printf 200; exit 0 ;;
  *) exit 22 ;;
esac
id=$(cat "$W/run.$s"); grep -qx "$id" "$W/broken" 2>/dev/null && exit 22
echo "{\"commit\":\"${id#sha256:}0000000\"}"
FAKE
chmod +x "$T/bin/docker" "$T/bin/curl"
export PATH="$T/bin:$PATH" FAKE_WORLD="$T/w" HOME="$T/home" TRACE_COMPOSE_DIR="$T/compose"
export TRACE_DEPLOY_SERVICES="auth-server web chat-server" TRACE_DEPLOY_WAIT=2 TRACE_DEPLOY_STEP=1
export TRACE_ALERT_WEBHOOK_URL="https://example.invalid/hooks/x"
run() { bash "$ROOT/compose/ops/autodeploy.sh" "$@"; }
set_img() { echo "sha256:$2" > "$T/w/$1"; }
ups() { wc -l < "$T/w/ups" 2>/dev/null || echo 0; }
ok() { echo "ok - $1"; }
fail() { echo "not ok - $1"; exit 1; }
: > "$T/w/broken"; : > "$T/w/ups"; : > "$T/w/notified"
for s in auth-server web; do set_img "tag.$s" aaa1; set_img "run.$s" aaa1; set_img "remote.$s" aaa1; done

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
out=$(run status)
grep -q "web  *eee5000  *eee5000  *최신" <<<"$out" && ! grep -q chat-server <<<"$out" && ok "status가 서비스별 버전을 보여 준다" || fail "status"
echo "모두 통과"
