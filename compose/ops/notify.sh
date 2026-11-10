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
  curl -fsS -m 10 -H 'Content-Type: application/json' -d "{\"$field\":\"$text\"}" "$url" >/dev/null
}
