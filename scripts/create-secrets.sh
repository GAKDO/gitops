#!/usr/bin/env bash
# overlays/school/secret.env(커밋 금지)를 읽어 trace 네임스페이스에 Secret 두 개를 만든다. 이미 있으면 새 값으로 바꾼다.
#   trace-postgres: POSTGRES_PASSWORD, POSTGRE_USER, POSTGRE_PASSWORD
#   trace-secrets : 나머지 키 전부 (grafana는 이 중 GRAFANA_ADMIN_PASSWORD·INFLUX_READ_TOKEN만 받는다)
# 사용: scripts/create-secrets.sh [secret.env 경로]   (kubectl이 학교 클러스터를 가리키고 있어야 한다)
# 값이 빈 키는 넣지 않는다. 그 키를 쓰는 기능만 동작하지 않는다.
# Secret을 바꿔도 떠 있는 파드는 그대로다: kubectl -n trace rollout restart deploy
# DB 계정 비밀번호는 postgres가 처음 뜰 때만 DB에 들어간다. 나중에 바꾸면 DB 안에서도 ALTER ROLE로 바꾼다(README).
set -euo pipefail

ns="${NAMESPACE:-trace}"
root="$(cd "$(dirname "$0")/.." && pwd)"
env_file="${1:-$root/overlays/school/secret.env}"

if [ ! -f "$env_file" ]; then
  echo "$env_file 이 없습니다. overlays/school/secret.env.example을 secret.env로 복사해 값을 채우세요." >&2
  exit 1
fi

pg_keys='^(POSTGRES_PASSWORD|POSTGRE_USER|POSTGRE_PASSWORD)='
required=(DB_USERNAME DB_PASSWORD POSTGRES_PASSWORD POSTGRE_USER POSTGRE_PASSWORD)

umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 주석·빈 줄·값이 빈 줄을 빼고 줄 앞 공백과 윈도우 줄바꿈(\r)을 지운다
sed -e 's/\r$//' -e 's/^[[:space:]]*//' "$env_file" \
  | grep -E '^[A-Za-z_][A-Za-z0-9_]*=.+' > "$tmp/all.env" || true

missing=()
for k in "${required[@]}"; do
  grep -q "^$k=" "$tmp/all.env" || missing+=("$k")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "꼭 필요한 값이 비어 있습니다: ${missing[*]}" >&2
  exit 1
fi

grep -E "$pg_keys" "$tmp/all.env" > "$tmp/trace-postgres.env"
grep -vE "$pg_keys" "$tmp/all.env" > "$tmp/trace-secrets.env" || true

for name in trace-secrets trace-postgres; do
  kubectl -n "$ns" create secret generic "$name" \
    --from-env-file="$tmp/$name.env" --dry-run=client -o yaml \
    | kubectl -n "$ns" apply -f -
  echo "적용했습니다: $ns/$name (키 $(grep -c . "$tmp/$name.env")개)"
done
