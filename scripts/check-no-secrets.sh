#!/usr/bin/env bash
# 저장소에 실제 비밀값이 들어가지 않았는지 검사한다. (블로그 deploy/scripts/check-no-secrets.sh를 옮기고 gitops용 검사를 더함)
# 매니페스트 검증(validate.yml)과 비밀값 검사(security.yml)에서 돈다. 토큰·키 패턴 전반은 security.yml의 gitleaks가 본다.
# - secret.env·kubeconfig·.env·*.local.env 파일이 추적되고 있으면 실패 (.example은 허용)
# - 쿠버네티스 Secret 매니페스트나 secretGenerator가 있으면 실패 (Secret은 Rancher에서 손으로 만든다)
# - secret.env.example에 값이 채워져 있으면 실패 (KEY= 형태로 이름만 둔다)
# - 학교 공용 비밀번호 패턴(nhnacademy로 시작하는 비밀번호 등)이 보이면 실패
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
if git ls-files | grep -E '(^|/)secret\.env$|(^|/)kubeconfig|(^|/)\.env$|\.local\.env$' ; then
  echo "비밀 파일이 커밋되어 있습니다" >&2; fail=1
fi
if git grep -n -I -E '^kind:[[:space:]]*Secret[[:space:]]*$|^[[:space:]]*secretGenerator:' -- '*.yaml' '*.yml' ; then
  echo "Secret은 저장소에 두지 않고 Rancher(또는 scripts/create-secrets.sh)로 만듭니다" >&2; fail=1
fi
if git grep -n -I -E '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]' -- '*secret.env.example' ; then
  echo "secret.env.example에는 KEY= 형태로 이름만 둡니다" >&2; fail=1
fi
# 패턴은 값 자체를 적지 않고 형태로만 찾는다
if git grep -n -I -i -E '(password|pwd|secret)[^=:]*[=:][[:space:]]*["'"'"']?[Nn]hnacademy[0-9]' -- . ':!scripts/check-no-secrets.sh' ; then
  echo "학교 공용 비밀번호로 보이는 값이 있습니다" >&2; fail=1
fi
[ "$fail" -eq 0 ] && echo "비밀값 없음"
exit $fail
