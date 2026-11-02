# 변경 기록

이 레포의 버전별 변경을 적는다. 형식은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따른다.
기능 PR은 `## [Unreleased]` 아래에 한 줄을 더하고, 릴리스 PR에서 `## [x.y.z] - 날짜`로 바꾼다(CONTRIBUTING.md 3번).
main에 버전이 적힌 CHANGELOG가 올라가면 release.yml이 태그와 GitHub Release를 만든다.

## [Unreleased]

### 고침

- 학교 `MINIO_ENDPOINT`를 웹 콘솔 주소에서 S3 API 주소 `http://storage.java21.net:8000`으로 바꾸고, 폰용 사전 서명 URL 앞부분 `MINIO_PUBLIC_BASE=https://gakdo.site`를 더함

## [0.1.0] - 2026-11-02

**목표: 첫 클러스터 배포와 https://gakdo.site 공개**
auth-server 초기 계정 키를 받고, Cloudflare Tunnel(cloudflared 2개)로 web·gateway를 https://gakdo.site에 공개한다.

### 추가
- 블로그(AIGJ-01-002-blog/devlog) CI/CD를 옮겨 초기 구성
- auth-server 초기 관리자·부스 자격 키와 `WEB_PUBLIC_URL` 안내 (AU1) (#1)
- Cloudflare Tunnel 커넥터(cloudflared)와 주소 값 `https://gakdo.site`, `TRACE_CLIENT_IP_HEADER` (#3)
- 시연용 고객 계정 키 `DEMO_CUSTOMER_EMAIL`·`DEMO_CUSTOMER_PASSWORD` 예시 (#4)

### 바꿈
- gateway·web NodePort(8314·8315)를 닫고 터널로만 공개, NodePort는 label-studio 8316만 (#3)
- web·gateway 직접 TLS(#2)는 터널 방식으로 바꾸며 되돌림 (#3)
