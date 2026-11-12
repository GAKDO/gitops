# gitops

TRACE(노트북 렌탈 상태 기록 서비스)의 쿠버네티스 배포 설정 레포다. 학교 서버의 Argo CD가 이 레포 `main`의 `overlays/school`을 학교 Rancher 클러스터의 `trace` 네임스페이스에 그대로 맞춘다.

앱 코드는 없다. 앱 8개(gateway, web, 서버 5개, Label Studio)와 PostgreSQL의 매니페스트, 그리고 지금 배포된 이미지 태그만 둔다. 학교 공유 인프라(MinIO·RabbitMQ·Redis·InfluxDB·Elasticsearch)는 클러스터에 올리지 않고 주소로만 붙는다. 예외는 둘이다. PostgreSQL(학교 PostgreSQL 접속 정보·권한을 받지 못함)과 파일럿 대시보드 Grafana(학교 Grafana 관리자 계정 분실, InfluxDB가 학교 내부망 전용, 11/2 결정).

비밀번호·키·토큰은 이 레포에 **절대 넣지 않는다.** Secret은 Rancher에서 손으로 만든다(또는 `scripts/create-secrets.sh`).

## 구성

```
gitops/
├── base/
│   ├── apps/<앱>/               Deployment·Service·kustomization (이미지 이름은 앱 이름 그대로)
│   │   ├── gateway/             외부 API 입구 (Spring Cloud Gateway)
│   │   ├── web/                 웹앱 (nginx-unprivileged)
│   │   ├── auth-server/ rental-server/ capture-server/ diagnostics-server/ report-server/
│   │   ├── label-studio/        heartexlabs/label-studio:1.19.0 + 2Gi PVC
│   │   └── grafana/             grafana/grafana-oss:12.1.1, 저장 공간 없이 provisioning만 (원본 web grafana/)
│   ├── postgres/                PostgreSQL 16 StatefulSet(10Gi) + 첫 기동 초기화(init-db.sh) + 매일 MinIO 백업(pg-backup)
│   └── network/                 들어오는 연결 기본 차단 + 같은 네임스페이스 허용 + 밖으로 여는 3개만 허용
├── overlays/school/             학교 클러스터 운영 구성 (Argo CD가 보는 곳)
│   ├── kustomization.yaml       네임스페이스·이미지 태그·NodePort
│   ├── infra.env                비밀 아닌 접속 주소 → ConfigMap trace-infra
│   └── secret.env.example       Secret 키 이름 목록 (값 없음). secret.env로 복사해 채운다 (커밋 금지)
├── compose/                     로컬 Compose(G1): 노트북·학교 서버에서 쿠버네티스 없이 띄우기 (아래 "로컬 Compose")
├── argocd/application.yaml      Argo CD Application "trace" (처음 한 번 등록)
├── scripts/create-secrets.sh    secret.env → Secret trace-secrets·trace-postgres 만들기/바꾸기
├── scripts/check-no-secrets.sh  비밀값이 커밋됐는지 검사 (CI에서도 실행)
└── .github/workflows/validate.yml  매니페스트 검증 (kustomize build + kubeconform)
```

## 배포 흐름

**지금 운영(학교 서버 Compose, `https://gakdo.site`)** 은 아래 "로컬 Compose" 구성으로 돈다. 쿠버네티스 매니페스트와 Argo CD 경로는 클러스터를 쓸 때를 위해 그대로 두고 CI로 계속 검증한다.

```
앱 레포 develop 머지 → GitHub Actions(테스트 → 이미지) → GHCR ghcr.io/gakdo/<앱>:develop
  → 학교 서버의 compose/ops/autodeploy.sh(cron 3분)가 새 이미지를 받아 그 서비스만 교체
  → ping 응답의 커밋이 새 이미지와 같은지 확인 → 실패하면 직전 이미지로 되돌리고 알림
  → 바깥에서는 "운영 점검" 워크플로가 30분마다 gakdo.site의 화면·서버·인증서를 확인
```

서버가 밖으로 나가 이미지를 받아 오는 방식이라 GitHub에 서버 접속 키를 두지 않는다. 자세한 설정은 아래 "Compose 운영 자동화".

**클러스터(Argo CD) 경로**

```
앱 레포 main 푸시 → GitHub Actions(빌드·테스트) → GHCR ghcr.io/gakdo/<앱>:<커밋 SHA>
  → 같은 워크플로가 이 레포의 overlays/school에서 kustomize edit set image → main에 커밋
  → Argo CD가 main 변화를 보고 클러스터에 맞춤 (자동 동기화)
```

1. 앱 레포(`gateway`, `web`, `auth-server` …)의 GitHub Actions가 이미지를 `ghcr.io/gakdo/<앱>:<커밋 SHA>`로 올린다.
2. 같은 워크플로가 이 레포를 받아 아래를 돌리고 `main`에 커밋·푸시한다. 앱 레포에는 이 레포에 쓸 수 있는 토큰을 GitHub Secret으로 둔다.
   ```bash
   cd overlays/school
   kustomize edit set image auth-server=ghcr.io/gakdo/auth-server:<커밋 SHA>
   ```
   `images:`의 `name`이 base의 이미지 이름(앱 이름 그대로)이라서 앱 이름만 맞으면 된다. 이 명령은 파일을 kustomize 기본 형식으로 다시 쓰므로 `kustomization.yaml`은 처음부터 그 형식(목록 들여쓰기 없음, images 이름순)으로 둔다. 그래야 태그 커밋이 한 줄 차이로 남는다.
3. Argo CD가 `main`의 `overlays/school`을 클러스터에 맞춘다. 레포에서 지운 리소스는 클러스터에서도 지우고(prune), 클러스터에서 손으로 바꾼 것은 레포 내용으로 되돌린다(selfHeal).
4. 되돌리기: 이 레포에서 태그를 바꾼 커밋을 `git revert`하면 Argo CD가 직전 이미지로 맞춘다.

PR과 `main`·`develop` 푸시마다 "매니페스트 검증"이 비밀값 검사와 `kustomize build overlays/school | kubeconform`을 돌린다. 클러스터에는 접속하지 않는다.

## 처음 한 번

0. **네임스페이스**: `trace`는 인프라 관리자가 Rancher 프로젝트 안에 만들어 둔다(10/30 승인). Argo CD는 네임스페이스를 만들지 않는다.
1. **Secret 두 개** (`trace-secrets`, `trace-postgres`): Argo CD 등록보다 먼저 만든다. PostgreSQL은 처음 뜰 때 이 값으로 앱 계정·Label Studio 계정과 DB를 만든다. Secret이 없으면 postgres·Label Studio 파드는 만들어지지 않고 기다린다.
   ```bash
   cp overlays/school/secret.env.example overlays/school/secret.env   # 값 채우기 (커밋 금지, .gitignore에 있음)
   scripts/create-secrets.sh                                          # kubectl이 학교 클러스터를 가리키고 있어야 한다
   ```
   Rancher 화면(Storage → Secrets, 네임스페이스 `trace`)에서 같은 이름·키로 직접 만들어도 된다. 어느 키가 어느 Secret에 들어가는지는 `secret.env.example`에 있다.
2. **Cloudflare Tunnel** (`https://gakdo.site`): 밖에서는 이 주소 하나로 받는다. 클러스터 안 `cloudflared`(base/apps/cloudflared)가 Cloudflare로 나가는 연결만 맺으므로 들어오는 포트·인증서가 필요 없다.
   1. gakdo.site의 네임서버를 Cloudflare로 옮긴다(가비아 → 네임서버 설정에 Cloudflare가 준 두 개).
   2. Cloudflare Zero Trust → Networks → Tunnels → Create a tunnel(Cloudflared, 이름 `trace`) → 토큰을 복사한다.
   3. Public hostname 두 개를 이 순서로 만든다(위가 먼저 맞음): `gakdo.site` 경로 `^/api/` → `HTTP` `gateway:8080`, `gakdo.site`(경로 없음) → `HTTP` `web:8080`.
   4. 토큰을 Secret으로 넣는다(값은 레포·채팅에 남기지 않는다):
      ```bash
      read -rsp 'TUNNEL_TOKEN: ' T; echo
      kubectl -n trace create secret generic trace-cloudflared --from-literal=TUNNEL_TOKEN="$T"; unset T
      ```
   Secret이 없으면 cloudflared 파드만 기다리고 나머지는 그대로 뜬다.
3. **GHCR 받기용 Secret** (패키지가 비공개일 때만): 앱 Deployment는 `ghcr-pull`을 참조한다. 패키지가 공개면 만들지 않아도 된다(경고만 남고 이미지는 받는다).
   ```bash
   kubectl -n trace create secret docker-registry ghcr-pull \
     --docker-server=ghcr.io --docker-username=<GitHub 사용자> --docker-password=<read:packages 권한 토큰>
   ```
4. **Argo CD에 등록**: 레포가 비공개면 Argo CD Settings → Repositories에 읽기 전용 토큰으로 이 레포를 먼저 등록한다.
   ```bash
   kubectl apply -n argocd -f argocd/application.yaml   # 또는 Argo CD 화면에서 같은 값으로 만든다
   ```
5. **확인**: Argo CD 화면에서 `trace`가 Synced·Healthy인지, `kubectl -n trace get pods`로 파드가 모두 Running인지 본다. 앱 이미지가 아직 GHCR에 없으면 그 앱만 ImagePullBackOff로 남는다(앱 레포가 처음 올리면 풀린다).

## 밖으로 열린 포트

학교 서버는 NodePort를 8300~8499에서 학생마다 10개씩 나눠 준다. A 계정 범위(8310~8319) 중 8316 하나만 쓰고, 8318은 지난 프로젝트가 쓰고 있다. 나머지는 예비다. gateway·web은 NodePort 없이 Cloudflare Tunnel로만 공개한다(학교망에 평문 HTTP 포트를 열지 않고, 요청 제한이 믿는 `CF-Connecting-IP` 헤더를 위조할 경로도 없앤다).

| NodePort | 서비스 | 용도 |
|---|---|---|
| 없음 | gateway | API. `https://gakdo.site/api/...`(터널). 클러스터 안에서 확인할 땐 `kubectl -n trace port-forward svc/gateway 8080:8080` |
| 없음 | web | 웹. `https://gakdo.site`(터널) |
| 8316 | label-studio | 학습 데이터 라벨링 |
| 없음 | grafana | 파일럿 추이 대시보드. `https://gakdo.site/grafana/`(web nginx가 `http://grafana:3000`으로 넘김). 익명은 보기만, 편집은 admin |

나머지 서버 5개와 postgres는 같은 네임스페이스 안에서만 닿는다(`base/network`). 클러스터 안 앱은 모두 8080으로 받고, 서로 `http://<서비스 이름>:8080`으로 부른다. 집 PC에서 DB가 필요하면 `kubectl -n trace port-forward svc/postgres 5432:5432`로 붙는다.

## 어디를 바꾸나

| 바꿀 것 | 파일 | 참고 |
|---|---|---|
| 앱 이미지 태그 | `overlays/school/kustomization.yaml`의 `images:` | 보통 앱 레포가 자동으로 바꾼다 |
| 인프라 주소 (Redis DB 번호, 버킷 등) | `overlays/school/infra.env` | ConfigMap 이름이 고정이라 파드가 저절로 다시 뜨지 않는다. 머지 후 `kubectl -n trace rollout restart deploy` |
| 비밀번호·키 | 로컬 `secret.env` → `scripts/create-secrets.sh`, 또는 Rancher | 바꾼 뒤 `rollout restart`. DB 계정 비밀번호는 DB 안에서도 `ALTER ROLE ... PASSWORD`로 같이 바꾼다 |
| 밖으로 여는 포트 | `overlays/school/kustomization.yaml`의 `patches:` | |
| 리소스·프로브·보안 설정 | `base/apps/<앱>/deployment.yaml` | |
| Label Studio 버전 | `base/apps/label-studio/deployment.yaml`의 `image:` | 앱 레포가 없어 여기서 직접 올린다 |
| Grafana 버전·대시보드 | `base/apps/grafana/deployment.yaml`의 `image:`, `base/apps/grafana/provisioning/` | provisioning 원본은 web `grafana/`. 거기를 먼저 고치고 여기에 같이 복사한다. 파일을 바꾸면 파드가 저절로 다시 뜬다 |
| DB·스키마 | `base/postgres/init-db.sh` | 데이터가 빈 첫 기동 때만 돈다. 이미 뜬 DB에는 `psql`로 직접 만든다 |
| 백업 시각·보관 기간 | `base/postgres/pg-backup.yaml` | |
| 네트워크 허용 | `base/network/` | 나가는 연결은 막지 않는다 |
| 새 앱 | `base/apps/<앱>/` 추가 → `overlays/school`의 `resources:`·`images:`, 필요하면 `infra.env`에 주소 | |

클러스터에서 `kubectl edit`로 고치면 selfHeal이 되돌린다. 바꿀 것은 이 레포에서 PR로 바꾼다.

## DB 백업과 복구

- 매일 03:30(KST) `pg-backup` CronJob이 `trace`·`labelstudio` 두 DB를 `pg_dump -Fc`로 뜨고, 인증서로 암호화해 MinIO `trace-backups/postgres/<DB>-<날짜-시각>.dump.p7m`에 올린다. 7일 지난 백업은 지운다. 클러스터 디스크에는 남기지 않는다.
- 암호화하는 이유: 학교 MinIO S3 API가 HTTP뿐이라 오가는 덤프가 평문으로 보인다. 그래서 공개 키 인증서로 암호화(CMS, AES-256-GCM)해서 올리고, 풀 수 있는 개인 키는 클러스터 밖에만 둔다. 인증서가 없으면 백업은 평문으로 올리지 않고 실패한다.
- 키 만들기(처음 한 번, 노트북에서):
  ```bash
  openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=trace-backup" -keyout backup-key.pem -out backup-cert.pem
  base64 -w0 backup-cert.pem   # 이 한 줄을 trace-secrets의 BACKUP_ENCRYPTION_CERT로 넣는다
  ```
  `backup-key.pem`은 비밀번호 관리자 등 클러스터 밖 안전한 곳에 둔다. 잃어버리면 백업을 풀 수 없다.
- 지금 바로 백업: `kubectl -n trace create job --from=cronjob/pg-backup pg-backup-now`
- 복구: MinIO에서 받아 개인 키로 푼 뒤 파드 안 `pg_restore`로 넣는다. 앞 단계가 실패하면 멈추도록 `&&`로 잇고, 풀어 둔 평문은 끝나면 지운다. 복구하는 동안 해당 앱은 잠시 내려 둔다.
  ```bash
  (
    f=trace-20261101-0330.dump
    trap 'rm -f "$f"' EXIT
    rm -f "$f" "$f.p7m" &&
    mc cp <별칭>/trace-backups/postgres/$f.p7m . &&
    sha256sum "$f.p7m" &&
    openssl cms -decrypt -binary -inform DER -inkey backup-key.pem -in "$f.p7m" -out "$f" &&
    kubectl -n trace exec -i postgres-0 -- pg_restore -U postgres -d trace --clean --if-exists < "$f"
  )
  ```
- 파일이 바뀌었으면 푸는 단계(GCM 검증)에서 멈춘다. 다만 HTTP 구간에서는 예전의 정상 백업으로 바꿔치기할 수 있으니, 받은 파일의 `sha256sum`을 그 백업을 만든 잡 로그(`kubectl -n trace logs job/<잡 이름> -c encrypt`)의 해시와 비교한 뒤 복구한다.
- PostgreSQL 데이터는 PVC `data-postgres-0`(10Gi), Label Studio 파일은 PVC `label-studio-data`(2Gi)에 남는다. 네임스페이스를 지우면 PVC도 지워지니 백업 뒤에 지운다.
- 첫 기동 초기화가 중간에 실패하면(예: Secret 값이 비어 있음) 데이터 폴더만 만들어진 채 남아 다시 돌지 않는다. 데이터가 없을 때만 StatefulSet을 0으로 줄이고 PVC `data-postgres-0`을 지운 뒤 다시 띄운다.

## 로컬 Compose (G1)

학교 클러스터 없이 서버 6개 + web + PostgreSQL·RabbitMQ·Redis·MinIO를 `docker compose` 하나로 띄운다(NFR-06). 노트북과 학교 서버(10.116.64.12:8315, `https://gakdo.site` → 강사님 nginx → 8315) 둘 다 같은 파일이다. 앱 이미지(GHCR)와 환경 변수 이름은 클러스터와 같다.

```bash
cd compose
./init-env.sh               # .env를 만들고 빈 계정·비밀 값을 무작위로 채운다(있는 값은 그대로, 커밋 금지)
                            # 그다음 .env에 PUBLIC_BASE_URL(필요하면 ADMIN_EMAIL·DEMO_CUSTOMER_EMAIL·SMTP_*)을 채운다
docker login ghcr.io        # GHCR 패키지가 비공개면 read:packages 토큰으로 한 번
docker compose up -d
docker compose ps           # minio-init은 버킷을 만들고 Exited (0)이면 정상
```

| 경로 (web nginx가 입구) | 가는 곳 |
|---|---|
| `/` | 화면 |
| `/api/` | gateway → 서버 5개 |
| `/trace-captures/`·`/trace-derived/` | MinIO (사전 서명 URL, capture-server가 앞부분을 `PUBLIC_BASE_URL`로 바꿔 줌) |

- **공개 주소**: `.env`의 `PUBLIC_BASE_URL` 하나가 `WEB_PUBLIC_URL`(QR 링크)·`TRACE_WEB_ORIGIN`(CORS)·`MINIO_PUBLIC_BASE`(사진 URL)가 된다. 폰 카메라는 HTTPS에서만 되므로 폰 수령 촬영은 `https://` 주소(학교 서버의 강사님 nginx, 또는 `compose/tls/`에 `tls.crt`·`tls.key`)로 연다.
- **이미지 태그**: 기본 `develop`(develop 푸시마다 갱신). `TRACE_TAG=latest`면 main 릴리스, 앱 하나만 바꾸려면 `CAPTURE_SERVER_TAG=<커밋 SHA>`처럼. 바꾼 뒤 `docker compose pull && docker compose up -d`.
- **자동 재시작**: 모든 서비스가 `restart: unless-stopped`라 앱이 죽으면 다시 뜬다(`docker compose kill capture-server` 뒤에도 다시 뜸. `stop`은 손으로 멈춘 것으로 본다).
- **집 PC 워커**: RabbitMQ(5672)·MinIO(9000)는 기본으로 이 기기(127.0.0.1)에서만 열린다. 같은 망의 워커가 붙어야 하면 `INFRA_BIND=0.0.0.0`. 같은 기기에서 포트가 이미 쓰이면 `RABBITMQ_HOST_PORT`·`RABBITMQ_MGMT_HOST_PORT`·`MINIO_HOST_PORT`·`MINIO_CONSOLE_HOST_PORT`로 호스트 포트만 바꾼다(학교 서버는 9000·9001이 다른 MinIO라 19000·19001). 컨테이너끼리는 그대로 `rabbitmq:5672`·`minio:9000`.
- **초기화**: DB 계정·스키마는 postgres 볼륨이 비어 있을 때 `compose/init-db.sh`가 한 번 만든다. 처음부터 다시 하려면 `docker compose down -v`(데이터가 모두 사라진다).
- **Apple Silicon**: GHCR 이미지가 amd64뿐이라 에뮬레이션으로 돈다(Docker Desktop의 Rosetta 사용 권장). 처음 기동이 몇 분 걸릴 수 있다.
- InfluxDB(파일럿 추이)는 들어 있지 않다. 학교 InfluxDB는 내부망 전용이라 학교 서버에서 띄울 때만 `infra.env`의 `INFLUX_URL`을 채운다.

### Compose 운영 자동화 (학교 서버: 야간 백업·장애 알림)

쿠버네티스 `pg-backup` 대신 Compose에서도 사람이 지켜보지 않아도 되게 cron 두 줄을 둔다. 알림은 `~/.config/trace-ops.env`의 `TRACE_ALERT_WEBHOOK_URL`(Discord·Slack 웹훅, 집 PC 재학습 알림과 같은 채널 가능)로 보내고, 없으면 조용히 건너뛴다.

```bash
# 학교 서버에서 (ssh -p 8822 AIGJ_01_002@s2.java21.net)
cd ~/gitops && git pull
mkdir -p ~/trace-backups ~/.config
echo 'TRACE_ALERT_WEBHOOK_URL=<웹훅 주소>' > ~/.config/trace-ops.env && chmod 600 ~/.config/trace-ops.env
bash compose/ops/backup.sh      # 한 번 손으로 돌려 크기·남은 디스크 확인
crontab -e                      # 아래 두 줄을 그대로 붙여 넣기
```

```cron
30 3 * * * bash $HOME/gitops/compose/ops/backup.sh >> $HOME/trace-backups/backup.log 2>&1
*/2 * * * * bash $HOME/gitops/compose/ops/health.sh >> $HOME/trace-backups/health.log 2>&1
```

자동 배포를 켜려면 한 줄을 더한다(넣기 전에는 지금처럼 손으로 `docker compose pull && docker compose up -d`).

```cron
*/3 * * * * bash $HOME/gitops/compose/ops/autodeploy.sh >> $HOME/trace-backups/deploy.log 2>&1
```

| 스크립트 | 하는 일 |
| --- | --- |
| `ops/backup.sh` | `pg_dumpall` → `~/trace-backups/db/trace-<시각>.sql.gz`(14일 보관), MinIO 데이터 볼륨 → `~/trace-backups/minio/minio-<시각>.tar.gz`(3일 보관). MinIO는 묶는 동안만 잠깐 일시 정지(pause)해 한 시점의 파일만 담는다. 실패하면 알림 |
| `ops/autodeploy.sh` | 3분마다 앱 이미지(`TRACE_DEPLOY_SERVICES`, 기본은 서버 6개·chat-server·web)를 받아, 지금 도는 컨테이너와 다르면 그 서비스만 바꾼다. 최대 180초 동안 컨테이너가 죽지 않았는지와 ping 응답의 커밋이 새 이미지의 커밋인지 확인하고, 실패하면 직전 이미지로 되돌린 뒤 그 이미지는 다음 이미지가 올 때까지 다시 시도하지 않는다. 결과는 `~/.cache/trace-deploy/history.log`와 알림으로 남는다. compose 파일·`.env`·DB·모델 파일은 건드리지 않는다 |
| `ops/health.sh` | 2분마다 서비스가 멈추거나 unhealthy인지, 웹 → gateway(`/api/v1/gateway/ping`)가 응답하는지 본다. 정상→장애, 장애→정상으로 바뀔 때만 한 번씩 알린다(알림 전송이 실패하면 다음 점검에 다시 보냄) |

- 자동 배포 명령(학교 서버 `~/gitops/compose`에서): `bash ops/autodeploy.sh status`(서비스별 도는 버전·받아 둔 버전·최근 배포), `bash ops/autodeploy.sh pause 촬영`(촬영·시연 전에 멈춤), `bash ops/autodeploy.sh resume`(다시 켬). 교체하는 서비스는 수 초에서 수십 초 동안 응답이 끊긴다(무중단 아님). inspect-worker는 검사 도중에 다시 켜지지 않게 기본에서 뺐다.
- 되돌린 뒤 서버의 `:develop` 태그는 실패한 새 이미지를 가리킨 채로 남는다. 그 서비스를 손으로 `docker compose up -d` 하면 실패한 이미지가 뜨므로, 고친 이미지가 올라온 뒤에 한다.
- 바깥 점검: `.github/workflows/site-check.yml`("운영 점검")이 30분마다 GitHub 러너에서 `https://gakdo.site`의 화면·서버 6개·챗봇 ping과 인증서 남은 기간(14일 미만이면 실패)을 본다. 서버·앞단 nginx·DNS가 죽어 `health.sh`가 알릴 수 없는 경우를 잡는다.
- 백업은 같은 서버 디스크에 남으므로 서버 자체가 망가지는 경우까지 막으려면 가끔 집 PC로 내려받는다: `scp -P 8822 AIGJ_01_002@s2.java21.net:trace-backups/db/<파일> .`
- 복구 명령은 모두 학교 서버의 `~/gitops/compose`에서 친다(`cd ~/gitops/compose`).
- DB 복구: 덤프는 `--clean` 없이 만든 `pg_dumpall`이라 기존 `trace` DB 위에 부으면 섞인다. 빈 DB에 붓는다.
  1. 백업 파일이 온전한지 먼저 본다(실패하면 여기서 멈추고 다른 파일을 고른다): `gzip -t ~/trace-backups/db/<파일>.sql.gz && echo OK`
  2. 앱만 멈춘다(postgres는 켜 둔다): `docker compose stop $(docker compose config --services | grep -vxE 'postgres|minio|minio-init|rabbitmq|redis')`
  3. 기존 DB를 지운다: `docker compose exec -T postgres psql -U postgres -d postgres -c 'DROP DATABASE trace WITH (FORCE)'`
  4. 붓는다. 두 명령의 종료 상태를 함께 확인한다: `set -o pipefail; gunzip -c ~/trace-backups/db/<파일>.sql.gz | docker compose exec -T postgres psql -U postgres -d postgres 2> ~/trace-backups/restore-err.log && echo 복구 명령 성공`
  5. `복구 명령 성공`이 나왔고, `grep ERROR ~/trace-backups/restore-err.log | grep -v 'role ".*" already exists'` 가 **아무것도 안 나올 때만** 다음으로 간다(역할이 이미 있다는 오류는 정상). 둘 중 하나라도 어긋나면 앱을 켜지 말고 3단계부터 다시 한다.
  6. 앱을 켠다: `docker compose up -d`
- MinIO 복구: 아래 순서대로, 앞 단계가 성공했을 때만 다음으로 간다.
  1. 백업 파일 확인: `gzip -t ~/trace-backups/minio/<파일> && tar tzf ~/trace-backups/minio/<파일> >/dev/null && echo OK`
  2. `docker compose stop minio`
  3. 비우고 푼다(숨김 폴더 `.minio.sys`까지): `docker run --rm --volumes-from $(docker compose ps -a -q minio) -v ~/trace-backups/minio:/b alpine:3.20 sh -c 'find /data -mindepth 1 -delete && tar xzf /b/<파일> -C /' && echo 추출 성공`
  4. `추출 성공`이 나왔을 때만 `docker compose start minio`. 안 나왔으면(디스크 부족 등) MinIO를 멈춘 채 두고 원인을 고친 뒤 3단계를 다시 한다.
- 보관 일수·위치는 `TRACE_BACKUP_KEEP_DB`·`TRACE_BACKUP_KEEP_MINIO`·`TRACE_BACKUP_DIR`로 바꾼다.

## 로컬에서 검증

```bash
kustomize build overlays/school | kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.33.0 -
scripts/check-no-secrets.sh
```

CI와 같은 도구 버전을 쓴다: kustomize 5.7.1, kubeconform 0.7.0.
