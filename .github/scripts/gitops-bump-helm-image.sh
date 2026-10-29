#!/usr/bin/env bash
# Atualiza image.tag (e pullPolicy) em um values.yaml Helm, abre PR e faz merge.
#
# Env obrigatório: VALUES_FILE, IMAGE_TAG, SERVICE, BRANCH, ACTOR, GH_TOKEN
# Env opcional: PR_BODY
set -euo pipefail

: "${VALUES_FILE:?VALUES_FILE é obrigatório}"
: "${IMAGE_TAG:?IMAGE_TAG é obrigatório}"
: "${SERVICE:?SERVICE é obrigatório}"
: "${BRANCH:?BRANCH é obrigatório}"
: "${ACTOR:?ACTOR é obrigatório}"
: "${GH_TOKEN:?GH_TOKEN é obrigatório}"

if [ ! -f "${VALUES_FILE}" ]; then
  echo "::error::Arquivo Helm não encontrado: ${VALUES_FILE}"
  exit 1
fi

git fetch origin "${BRANCH}"
git checkout "${BRANCH}"
git pull --ff-only origin "${BRANCH}"

CURRENT_TAG="$(
  sed -nE 's/^[[:space:]]*tag:[[:space:]]*["'\'']?([^"'\'']+)["'\'']?.*/\1/p' "${VALUES_FILE}" | head -n 1
)"
if [ "${CURRENT_TAG}" = "${IMAGE_TAG}" ]; then
  echo "image.tag já está em ${IMAGE_TAG} — nada a commitar."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "${SCRIPT_DIR}/bump-helm-image.py" "${VALUES_FILE}" "${IMAGE_TAG}"

ACTOR_NAME="$(gh api "users/${ACTOR}" --jq 'if (.name | type == "string" and length > 0) then .name else .login end')"
ACTOR_ID="$(gh api "users/${ACTOR}" --jq '.id')"
ACTOR_EMAIL="${ACTOR_ID}+${ACTOR}@users.noreply.github.com"

git config user.name "${ACTOR_NAME}"
git config user.email "${ACTOR_EMAIL}"

BUMP_BRANCH="chore/${SERVICE}-image-tag-${IMAGE_TAG}"
git checkout -B "${BUMP_BRANCH}"

git add "${VALUES_FILE}"
git commit -m "chore(${SERVICE}): bump image tag to ${IMAGE_TAG}" \
  -m "Atualiza Helm values para o ArgoCD sincronizar a imagem publicada."

git push --force origin "HEAD:${BUMP_BRANCH}"

PR_TITLE="chore(${SERVICE}): bump image tag to ${IMAGE_TAG}"
if [ -z "${PR_BODY:-}" ]; then
  PR_BODY="$(printf '%s\n' \
    "Atualiza \`image.tag\` de \`${SERVICE}\` para \`${IMAGE_TAG}\`." \
    "" \
    "Branch protegida exige pull request, então o deploy abre este PR e faz o merge.")"
fi

EXISTING_PR="$(gh pr list --head "${BUMP_BRANCH}" --base "${BRANCH}" --json number --jq '.[0].number // empty')"
if [ -n "${EXISTING_PR}" ]; then
  PR_NUMBER="${EXISTING_PR}"
  gh pr edit "${PR_NUMBER}" --title "${PR_TITLE}" --body "${PR_BODY}"
else
  PR_URL="$(gh pr create --base "${BRANCH}" --head "${BUMP_BRANCH}" --title "${PR_TITLE}" --body "${PR_BODY}")"
  PR_NUMBER="${PR_URL##*/}"
fi

if ! gh pr merge "${PR_NUMBER}" --merge --delete-branch; then
  echo "::error::O merge automático do PR #${PR_NUMBER} falhou."
  echo "PR: https://github.com/${GITHUB_REPOSITORY:-}/pull/${PR_NUMBER}"
  exit 1
fi

echo "Helm image.tag atualizado via PR #${PR_NUMBER}: ${CURRENT_TAG} → ${IMAGE_TAG} (autor: ${ACTOR_NAME} <${ACTOR_EMAIL}>)"