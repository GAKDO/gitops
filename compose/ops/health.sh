#!/usr/bin/env bash
# 학교 서버 상태 감시: 서비스가 멈추거나 unhealthy가 되면, 그리고 돌아오면 한 번씩 알린다(같은 상태는 다시 안 울림).
# cron 예: */2 * * * * bash ~/gitops/compose/ops/health.sh >> ~/trace-backups/health.log 2>&1
set -uo pipefail
COMPOSE="${TRACE_COMPOSE_DIR:-$HOME/gitops/compose}"
STATE="${TRACE_HEALTH_STATE:-$HOME/.cache/trace-health.state}"
PORT="${WEB_PORT:-8315}"
URL="${TRACE_HEALTH_URL:-}"
. "$(dirname "$0")/notify.sh"
mkdir -p "$(dirname "$STATE")"
cd "$COMPOSE" || exit 1

# 계속 돌아야 하는 서비스(minio-init처럼 한 번 돌고 끝나는 것은 뺀다)
SERVICES="$(docker compose config --services | grep -vx 'minio-init')"
RUNNING="$(docker compose ps --status running --services 2>/dev/null)"
BAD=""
for s in $SERVICES; do
  if ! grep -qx "$s" <<<"$RUNNING"; then BAD="$BAD $s(멈춤)"; continue; fi
  h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$(docker compose ps -q "$s")" 2>/dev/null)"
  [ "$h" = "unhealthy" ] && BAD="$BAD $s(unhealthy)"
done
# web(nginx) → gateway 경로가 사는지. tls/가 있으면 https로 열리므로 둘 다 본다
ping_ok() {
  if [ -n "$URL" ]; then curl -fsS -m 5 -k "$URL" >/dev/null 2>&1; return; fi
  for scheme in http https; do
    curl -fsS -m 5 -k "$scheme://127.0.0.1:$PORT/api/v1/gateway/ping" >/dev/null 2>&1 && return 0
  done
  return 1
}
ping_ok || BAD="$BAD 웹→gateway(응답없음)"

NOW="${BAD# }"; PREV="$(cat "$STATE" 2>/dev/null || true)"
if [ "$NOW" != "$PREV" ]; then
  if [ -n "$NOW" ]; then trace_notify "장애: $NOW · 확인: cd $COMPOSE && docker compose ps"
  else trace_notify "복구: 모든 서비스 정상"; fi
  printf '%s' "$NOW" > "$STATE"
fi
echo "$(date -u +%FT%TZ) ${NOW:-정상}"
