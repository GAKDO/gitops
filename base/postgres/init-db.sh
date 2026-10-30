#!/bin/sh
# PostgreSQL이 처음 뜰 때(데이터 폴더가 비어 있을 때) 한 번만 돈다. 이미 데이터가 있으면 다시 돌지 않는다.
# ConfigMap postgres-init으로 /docker-entrypoint-initdb.d에 들어가고, 공식 이미지의 시작 스크립트가 읽어서 실행한다.
#   - 앱 계정(trace-secrets의 DB_USERNAME/DB_PASSWORD)과 DB trace, 서비스별 스키마 7개
#   - Label Studio 계정(trace-postgres의 POSTGRE_USER/POSTGRE_PASSWORD)과 DB labelstudio
# 테이블은 각 서버가 시작할 때 Flyway로 자기 스키마에 만든다. 이미 뜬 DB에 스키마를 더하려면 psql로 직접 만든다(README).
# 계정 이름·비밀번호는 psql 변수로 넘겨 따옴표 처리를 psql에 맡긴다.

: "${TRACE_DB_USER:?trace-secrets의 DB_USERNAME이 비어 있습니다}"
: "${TRACE_DB_PASSWORD:?trace-secrets의 DB_PASSWORD가 비어 있습니다}"
: "${LABELSTUDIO_DB_USER:?trace-postgres의 POSTGRE_USER가 비어 있습니다}"
: "${LABELSTUDIO_DB_PASSWORD:?trace-postgres의 POSTGRE_PASSWORD가 비어 있습니다}"

psql -v ON_ERROR_STOP=1 --username postgres --dbname postgres \
  -v app_user="$TRACE_DB_USER" -v app_password="$TRACE_DB_PASSWORD" \
  -v ls_user="$LABELSTUDIO_DB_USER" -v ls_password="$LABELSTUDIO_DB_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_password';
CREATE ROLE :"ls_user" LOGIN PASSWORD :'ls_password';
CREATE DATABASE trace OWNER :"app_user";
CREATE DATABASE labelstudio OWNER :"ls_user";
SQL

# 서비스마다 스키마 하나 (capture-server는 capture·inspection 두 개). 서비스 사이 FK는 두지 않는다
psql -v ON_ERROR_STOP=1 --username postgres --dbname trace -v app_user="$TRACE_DB_USER" <<'SQL'
CREATE SCHEMA IF NOT EXISTS rental AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS capture AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS inspection AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS diagnostics AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS report AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS ml AUTHORIZATION :"app_user";
CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION :"app_user";
SQL
