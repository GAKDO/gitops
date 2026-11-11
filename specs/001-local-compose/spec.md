# 기능 명세: G1 로컬 Compose 폴백

- 백로그: G1 (gitops), 요구사항 NFR-06(NFR-05는 클러스터에서 확인)
- 근거: 11/2 저녁 전체 공유(민서) 5번, backlog.md G1, decisions.md 11/2(이미지 출처·MINIO_PUBLIC_BASE)
- 상태: 구현

## 배경

인프라(학교 클러스터) 확정 전에도 시연 흐름(출고 → 수령 → 반납 → 리포트)을 돌릴 바탕이 필요하다.
[잠정] 주력 배포안은 학교 서버(10.116.64.12:8315) + 강사님 nginx 서브도메인(trace.java21.net)이고 쿠버네티스·Cloudflare가 없다.

## 사용자 이야기

1. A는 노트북에서 `docker compose up -d` 한 번으로 서버 6개 + web + PostgreSQL·RabbitMQ·Redis·MinIO를 띄운다.
2. A는 같은 파일을 학교 서버에서 띄우고, 강사님 nginx가 HTTPS로 8315를 넘기면 고객 폰이 `https://trace.java21.net`에서 수령 촬영을 한다.
3. 폰은 HTTPS 화면에서 사진을 web 주소 아래 `/trace-captures/`로 올린다(혼합 콘텐츠 없음).

## 수용 기준

- AC1: `.env`(예시 복사 + 값)만 채우면 `docker compose up -d`로 12개 서비스가 뜨고 `minio-init`은 0으로 끝난다.
- AC2: 입구는 web 하나(`WEB_PORT`, 기본 8315). `/` 화면, `/api/` → gateway, `/trace-captures/`·`/trace-derived/` → MinIO.
- AC3: 공개 주소는 `PUBLIC_BASE_URL` 하나로 `WEB_PUBLIC_URL`·`TRACE_WEB_ORIGIN`·`MINIO_PUBLIC_BASE`가 된다.
- AC4: 이미지는 GHCR 고정 태그(기본 `develop`, 앱별로 바꿀 수 있음), 인프라 이미지도 모두 고정 태그다(minio/minio Docker Hub 사용 안 함).
- AC5: 비밀은 `.env`에만 있고 커밋되지 않는다(`.gitignore`, check-no-secrets).
- AC6: 앱 컨테이너가 죽으면 다시 뜬다(`restart: unless-stopped`).
- AC7: 환경 변수 이름은 클러스터(overlays/school)와 같다.
- AC8: CI(매니페스트 검증)가 `docker compose config`로 파일과 변수 치환을 확인한다.

## 범위 밖

- Label Studio·Grafana·InfluxDB(학교 내부망 전용), Cloudflare Tunnel, 연기 시험, 클러스터 매니페스트 변경(11/2 "멈출 것").
- 시연 데이터 시드·한 번에 흐름 재현 스크립트(여유 항목, 별도 작업).

## 짝 변경

- web: nginx `/api/`·MinIO 프록시(`API_UPSTREAM`·`MINIO_UPSTREAM`, Host는 MinIO 주소 그대로)
- capture_server: 사전 서명 URL 앞부분을 `MINIO_PUBLIC_BASE`로 바꿈
