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
# 조회 자체가 실패하면(도커 데몬 문제 등) 서비스 상태와 섞지 않고 상태 파일도 그대로 둔다
ALL="$(docker compose config --services)" || { echo "$(date -u +%FT%TZ) compose config 조회 실패"; exit 1; }
SERVICES="$(grep -vx 'minio-init' <<<"$ALL")"
[ -n "$SERVICES" ] || { echo "$(date -u +%FT%TZ) 서비스 목록이 비어 있음"; exit 1; }
RUNNING="$(docker compose ps --status running --services)" || { echo "$(date -u +%FT%TZ) compose ps 조회 실패"; exit 1; }
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

# 알림은 "정상 → 장애"와 "장애 → 정상" 두 전이에서만. 장애 목록만 바뀌면 기록만 갱신한다.
# 알림 전송이 실패하면 상태를 저장하지 않아 다음 점검(2분 뒤)에 다시 보낸다
NOW="${BAD# }"; PREV="$(cat "$STATE" 2>/dev/null || true)"
save() { printf '%s' "$NOW" > "$STATE"; }
if [ -n "$NOW" ] && [ -z "$PREV" ]; then
  trace_notify "장애: $NOW · 확인: cd $COMPOSE && docker compose ps" && save
elif [ -z "$NOW" ] && [ -n "$PREV" ]; then
  trace_notify "복구: 모든 서비스 정상(직전 장애: $PREV)" && save
elif [ "$NOW" != "$PREV" ]; then
  save
fi
echo "$(date -u +%FT%TZ) ${NOW:-정상}"
