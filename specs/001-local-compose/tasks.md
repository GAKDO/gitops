# 작업: G1 로컬 Compose 폴백

- [x] T1 capture_server: `MINIO_PUBLIC_BASE`로 사전 서명 URL 앞부분 바꾸기 + 단위 테스트 (capture_server #5)
- [x] T2 web: nginx `/api/` → gateway, `/trace-captures/`·`/trace-derived/` → MinIO, 시작 스크립트 일반화 (web #37)
- [x] T3 gitops `compose/docker-compose.yml`: 앱 7개 + 인프라 4개 + minio-init
- [x] T4 `compose/infra.env`, `compose/.env.example`, `compose/init-db.sh`, `compose/tls/`
- [x] T5 `.gitignore`에 `compose/.env`
- [x] T6 매니페스트 검증 CI에 `docker compose config` 확인
- [x] T7 README "로컬 Compose", CHANGELOG
- [ ] T8 첫 `docker compose up`(노트북·학교 서버)에서 이미지 받기·세 시점 흐름 확인 — Docker가 있는 기기에서 사람이 확인
