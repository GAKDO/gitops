# 계획: G1 로컬 Compose 폴백

## 기술

Docker Compose(spec, `name: trace`), YAML 앵커로 앱 6개 공통 설정. 비밀 아닌 주소는 `compose/infra.env`(이름은 overlays/school/infra.env와 같음),
비밀과 공개 주소는 `compose/.env`(`.env.example`만 커밋). 공개 주소 파생값은 Compose 변수 치환으로 `environment:`에 넣는다.

## 구성

| 서비스 | 이미지 | 비고 |
|---|---|---|
| gateway·auth/rental/capture/diagnostics/report-server | `ghcr.io/gakdo/<앱>:${TRACE_TAG:-develop}` | amd64, 768 MB, `SPRING_PROFILES_ACTIVE=compose` |
| web | `ghcr.io/gakdo/web` | 유일하게 밖으로 여는 포트 `WEB_PORT`(8315), `tls/`가 있으면 HTTPS |
| postgres | `postgres:16.15-alpine` | `init-db.sh`가 앱 계정·DB trace·스키마 7개 |
| rabbitmq | `rabbitmq:4.1.8-management-alpine` | vhost `/trace`, `INFRA_BIND`(기본 127.0.0.1) |
| redis | `redis:7.4.12-alpine` | requirepass, AOF |
| minio / minio-init | `pgsty/minio:RELEASE.2026-08-04T00-00-00Z` / `pgsty/mc:RELEASE.2026-09-16T00-00-00Z` | 버킷 trace-captures·trace-derived, 비공개 |

## 결정

- MinIO 이미지: 결정은 quay.io 먼저였으나 이 세션에서 quay.io에 닿지 않아 확인할 수 없었고, pgsty는 Docker Hub에서 태그를 확인했다. pg-backup이 이미 `pgsty/mc`를 쓰므로 같은 곳으로 맞춘다.
- 사전 서명 URL은 MinIO 원래 Host로 서명되므로, web nginx가 Host를 `MINIO_UPSTREAM` 값 그대로 보내고 capture-server는 URL 앞부분만 공개 주소로 바꾼다(경로·쿼리 불변).
- 앱 프로필은 `compose`(어느 `on-profile`에도 걸리지 않음). `school` 프로필의 "JWT 키 필수"는 걸지 않고 `.env.example`에서 키를 권한다.
