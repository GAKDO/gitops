#!/usr/bin/env bash
# 처음 띄우기 전에 한 번: .env가 없으면 .env.example로 만들고, 비어 있는 계정·비밀 값을 무작위로 채운다.
# 이미 값이 있는 키는 건드리지 않는다(CHAIN_SIGNING_KEY는 바꾸면 이전 봉인 검증이 깨지므로 특히).
# 값은 화면에 찍지 않는다. PUBLIC_BASE_URL·ADMIN_EMAIL·DEMO_CUSTOMER_EMAIL·SMTP_*는 사람이 채운다.
set -euo pipefail
cd "$(dirname "$0")"
command -v openssl >/dev/null || { echo "openssl이 필요합니다" >&2; exit 1; }

if [ ! -f .env ]; then
  cp .env.example .env
  echo ".env를 만들었습니다"
fi
chmod 600 .env

rand_hex() { openssl rand -hex 24; }
jwt_key() { openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | base64 | tr -d '\n'; }
chain_key() { openssl genpkey -algorithm ed25519 2>/dev/null | base64 | tr -d '\n'; }

# 키가 "KEY=" 로 비어 있을 때만 채운다. base64·hex 값에는 '|'와 '&'가 없어 sed 치환에 안전하다
fill() {
  local key=$1 value
  grep -qE "^${key}=$" .env || return 0
  value=$("${@:2}")
  [ -n "$value" ] || { echo "${key} 값을 만들지 못했습니다" >&2; exit 1; }
  sed -i "s|^${key}=$|${key}=${value}|" .env
  echo "채움: ${key}"
}

fill DB_USERNAME echo trace
fill RABBITMQ_USERNAME echo trace
fill MINIO_ACCESS_KEY echo trace-admin
fill BOOTH_CLIENT_ID echo trace-booth
for key in POSTGRES_PASSWORD DB_PASSWORD RABBITMQ_PASSWORD REDIS_PASSWORD MINIO_SECRET_KEY \
           ADMIN_PASSWORD BOOTH_CLIENT_SECRET DEMO_CUSTOMER_PASSWORD; do
  fill "$key" rand_hex
done
fill JWT_PRIVATE_KEY jwt_key
fill CHAIN_SIGNING_KEY chain_key

echo "아직 비어 있는 키(필요한 것만 직접 채운다):"
grep -E '^[A-Z_]+=$' .env | cut -d= -f1 | sed 's/^/  /' || true
