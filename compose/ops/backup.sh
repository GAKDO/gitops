#!/usr/bin/env bash
# 학교 서버 야간 백업: PostgreSQL 전체 덤프 + MinIO 데이터(사진·리포트) 묶음.
# cron 예: 30 3 * * * bash ~/gitops/compose/ops/backup.sh >> ~/trace-backups/backup.log 2>&1
# 보관: DB는 TRACE_BACKUP_KEEP_DB일(기본 14), MinIO는 TRACE_BACKUP_KEEP_MINIO일(기본 3). 사진이 커서 짧게 둔다.
set -euo pipefail
COMPOSE="${TRACE_COMPOSE_DIR:-$HOME/gitops/compose}"
OUT="${TRACE_BACKUP_DIR:-$HOME/trace-backups}"
KEEP_DB="${TRACE_BACKUP_KEEP_DB:-14}"
KEEP_MINIO="${TRACE_BACKUP_KEEP_MINIO:-3}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
. "$(dirname "$0")/notify.sh"

FAILED=0
# 알림이 실패해도 원래 백업 오류로 끝낸다. ERR 트랩과 겹쳐도 한 번만 알린다
fail() {
  [ "$FAILED" = 1 ] && exit 1
  FAILED=1; trace_notify "백업 실패($STAMP): $1" || true; echo "실패: $1" >&2; exit 1
}
# cd·mv·find 등 예상하지 못한 실패도 알림 경로로 보낸다
trap 'fail "예상하지 못한 오류(줄 $LINENO: $BASH_COMMAND)"' ERR

mkdir -p "$OUT/db" "$OUT/minio"
cd "$COMPOSE"

# 1) DB: 해시 체인·검수 기록이 여기 있다. 쓰다 끊긴 파일이 남지 않게 .part로 쓰고 끝나면 이름을 바꾼다
DB="$OUT/db/trace-$STAMP.sql.gz"
docker compose exec -T postgres pg_dumpall -U postgres | gzip > "$DB.part" || fail "pg_dumpall"
gzip -t "$DB.part" || fail "DB 덤프 압축 확인"
mv "$DB.part" "$DB"

# 2) MinIO: 묶는 동안 쓰기가 섞이지 않게 잠깐 멈춘다(pause, 새벽이라 업로드 없음). 어떤 경우에도 다시 푼다
MINIO_ID="$(docker compose ps -q minio)"
[ -n "$MINIO_ID" ] || fail "minio 컨테이너가 없음"
MIN="$OUT/minio/minio-$STAMP.tar.gz"
docker compose pause minio >/dev/null || fail "minio 일시 정지"
trap 'docker compose unpause minio >/dev/null 2>&1 || true' EXIT
docker run --rm --volumes-from "$MINIO_ID":ro -v "$OUT/minio":/out alpine:3.20 \
  tar czf "/out/$(basename "$MIN").part" -C / data || fail "MinIO 묶음"
docker compose unpause minio >/dev/null || fail "minio 다시 시작"
trap - EXIT
gzip -t "$MIN.part" || fail "MinIO 묶음 압축 확인"
mv "$MIN.part" "$MIN"

# 3) 오래된 백업 지우기: 일수를 분으로 바꿔 정확히 그 시간이 지난 것만(이번 것은 남음)
find "$OUT/db" -name 'trace-*.sql.gz' -mmin "+$((KEEP_DB * 1440))" -delete
find "$OUT/minio" -name 'minio-*.tar.gz' -mmin "+$((KEEP_MINIO * 1440))" -delete

echo "백업 끝 $STAMP: DB $(du -h "$DB" | cut -f1), MinIO $(du -h "$MIN" | cut -f1), 디스크 남은 $(df -h "$OUT" | awk 'NR==2{print $4}')"
