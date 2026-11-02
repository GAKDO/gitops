#!/bin/sh
# PostgreSQL이 처음 뜰 때(볼륨이 비어 있을 때) 한 번만 돈다. 클러스터 base/postgres/init-db.sh에서 Label Studio만 뺀 것이다.
# 앱 계정·DB trace·서비스별 스키마를 만들고, 테이블은 각 서버가 시작할 때 Flyway로 만든다.
# 다시 돌리려면 docker compose down -v 로 볼륨까지 지운다(데이터가 사라진다).
set -eu
: "${TRACE_DB_USER:?.env의 DB_USERNAME이 비어 있습니다}"
: "${TRACE_DB_PASSWORD:?.env의 DB_PASSWORD가 비어 있습니다}"

psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres \
  -v app_user="$TRACE_DB_USER" -v app_password="$TRACE_DB_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password';
CREATE DATABASE trace OWNER :"app_user";
SQL

psql -v ON_ERROR_STOP=1 --username postgres --dbname trace -v app_user="$TRACE_DB_USER" <<'SQL'
CREATE SCHEMA IF NOT EXISTS rental AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS capture AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS inspection AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS diagnostics AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS report AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS ml AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION :"app_user";
SQL
