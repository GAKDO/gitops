# gitops

TRACE(노트북 렌탈 상태 기록 서비스)의 쿠버네티스 배포 설정 레포다. 학교 서버의 Argo CD가 이 레포 `main`의 `overlays/school`을 학교 Rancher 클러스터의 `trace` 네임스페이스에 그대로 맞춘다.

앱 코드는 없다. 앱 8개(gateway, web, 서버 5개, Label Studio)와 PostgreSQL의 매니페스트, 그리고 지금 배포된 이미지 태그만 둔다. 학교 공유 인프라(MinIO·RabbitMQ·Redis·InfluxDB·Elasticsearch)는 클러스터에 올리지 않고 주소로만 붙는다. PostgreSQL만 예외로 클러스터 안에 둔다(학교 PostgreSQL 접속 정보·권한을 받지 못함).

비밀번호·키·토큰은 이 레포에 **절대 넣지 않는다.** Secret은 Rancher에서 손으로 만든다(또는 `scripts/create-secrets.sh`).

## 구성

```
gitops/
├── base/
│   ├── apps/<앱>/               Deployment·Service·kustomization (이미지 이름은 앱 이름 그대로)
│   │   ├── gateway/             외부 API 입구 (Spring Cloud Gateway)
│   │   ├── web/                 웹앱 (nginx-unprivileged)
│   │   ├── auth-server/ rental-server/ capture-server/ diagnostics-server/ report-server/
│   │   └── label-studio/        heartexlabs/label-studio:1.19.0 + 2Gi PVC
│   ├── postgres/                PostgreSQL 16 StatefulSet(10Gi) + 첫 기동 초기화(init-db.sh) + 매일 MinIO 백업(pg-backup)
│   └── network/                 들어오는 연결 기본 차단 + 같은 네임스페이스 허용 + 밖으로 여는 3개만 허용
├── overlays/school/             학교 클러스터 운영 구성 (Argo CD가 보는 곳)
│   ├── kustomization.yaml       네임스페이스·이미지 태그·NodePort
│   ├── infra.env                비밀 아닌 접속 주소 → ConfigMap trace-infra
│   └── secret.env.example       Secret 키 이름 목록 (값 없음). secret.env로 복사해 채운다 (커밋 금지)
├── argocd/application.yaml      Argo CD Application "trace" (처음 한 번 등록)
├── scripts/create-secrets.sh    secret.env → Secret trace-secrets·trace-postgres 만들기/바꾸기
├── scripts/check-no-secrets.sh  비밀값이 커밋됐는지 검사 (CI에서도 실행)
└── .github/workflows/validate.yml  매니페스트 검증 (kustomize build + kubeconform)
```

## 배포 흐름

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
- 복구: MinIO에서 받아 개인 키로 푼 뒤 파드 안 `pg_restore`로 넣는다. 파일이 바뀌었으면 푸는 단계에서 오류가 난다. 복구하는 동안 해당 앱은 잠시 내려 둔다.
  ```bash
  mc cp <별칭>/trace-backups/postgres/trace-20261101-0330.dump.p7m .
  openssl cms -decrypt -binary -inform DER -inkey backup-key.pem -in trace-20261101-0330.dump.p7m -out trace-20261101-0330.dump
  kubectl -n trace exec -i postgres-0 -- pg_restore -U postgres -d trace --clean --if-exists < trace-20261101-0330.dump
  ```
- PostgreSQL 데이터는 PVC `data-postgres-0`(10Gi), Label Studio 파일은 PVC `label-studio-data`(2Gi)에 남는다. 네임스페이스를 지우면 PVC도 지워지니 백업 뒤에 지운다.
- 첫 기동 초기화가 중간에 실패하면(예: Secret 값이 비어 있음) 데이터 폴더만 만들어진 채 남아 다시 돌지 않는다. 데이터가 없을 때만 StatefulSet을 0으로 줄이고 PVC `data-postgres-0`을 지운 뒤 다시 띄운다.

## 로컬에서 검증

```bash
kustomize build overlays/school | kubeconform -strict -summary -ignore-missing-schemas -kubernetes-version 1.33.0 -
scripts/check-no-secrets.sh
```

CI와 같은 도구 버전을 쓴다: kustomize 5.7.1, kubeconform 0.7.0.
