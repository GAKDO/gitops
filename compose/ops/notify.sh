# 운영 알림 발송 함수(ml trace_ml.retrain.notify와 같은 방식). source해서 쓴다.
# 보내지 못하면 0이 아닌 값을 돌려준다(웹훅이 없으면 0). 부르는 쪽이 재시도 여부를 정한다.
# 웹훅 주소는 비밀: ~/.config/trace-ops.env 의 TRACE_ALERT_WEBHOOK_URL(Discord·Slack). 없으면 조용히 건너뛴다.
if [ -f "$HOME/.config/trace-ops.env" ]; then . "$HOME/.config/trace-ops.env"; fi
trace_notify() {
  local url="${TRACE_ALERT_WEBHOOK_URL:-}" field="content"
  [ -n "$url" ] || return 0
  case "$url" in *hooks.slack.com*) field="text" ;; esac
  # 큰따옴표·역슬래시만 막는다(메시지는 스크립트가 만든 짧은 문장)
  local text="[TRACE 운영] ${1//\\/\\\\}"; text="${text//\"/\\\"}"
  # 2xx만 성공으로 본다(리디렉션 3xx는 실제로 전달되지 않았으므로 실패로 돌려 다음 점검에 다시 보낸다)
  local code
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -d "{\"$field\":\"$text\"}" "$url") || return 1
  case "$code" in 2??) return 0 ;; *) echo "알림 전송 실패: HTTP $code" >&2; return 1 ;; esac
}
