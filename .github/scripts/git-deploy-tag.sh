#!/usr/bin/env bash
# Registra um deploy como tag Git anotada e envia para a origin.
#   dev/hml: <serviço>/<tag-da-imagem>  (ex.: webapi1/dev-abc1234)
#   prod:    <serviço>/v<versão>        (ex.: webapi1/v1.4.0)
# O services-need-rebuild.sh compara o conteúdo atual com essas tags, e o promote de
# prod usa as tags v* para controlar as versões.
#
# É idempotente e protege contra conflito (tags nunca são movidas):
#   - tag não existe                   -> cria no COMMIT e envia
#   - tag existe no MESMO commit       -> não faz nada
#   - tag existe em OUTRO commit       -> falha
#
# Env obrigatório: TAG_NAME, COMMIT, IMAGE_TAG, DIGEST
# Opcional: IMAGE_NAME, CONTENT_HASH, SOURCE_TAG
set -euo pipefail

: "${TAG_NAME:?TAG_NAME é obrigatório}"
: "${COMMIT:?COMMIT é obrigatório}"
: "${IMAGE_TAG:?IMAGE_TAG é obrigatório}"
: "${DIGEST:?DIGEST é obrigatório}"

commit="$(git rev-parse --verify "${COMMIT}^{commit}")"

# Outra execução pode ter criado a tag depois do checkout.
git fetch --quiet origin "refs/tags/${TAG_NAME}:refs/tags/${TAG_NAME}" 2>/dev/null || true

existing="$(git rev-parse --verify -q "refs/tags/${TAG_NAME}^{commit}" 2>/dev/null || true)"
if [[ "${existing}" == "${commit}" ]]; then
  echo "Tag ${TAG_NAME} já aponta para ${commit}, nada a fazer."
  exit 0
fi
if [[ -n "${existing}" ]]; then
  echo "::error::Conflito: tag ${TAG_NAME} já existe em ${existing} (esperado ${commit}). Tags nunca são movidas."
  exit 1
fi

# Só o nome do repo no Hub (sem o usuário): a mensagem fica pública no repositório.
message="$(printf '%s\n' \
  "deploy ${TAG_NAME}" \
  "" \
  "image: ${IMAGE_NAME:-?}:${IMAGE_TAG}" \
  "digest: ${DIGEST}" \
  "content-hash: ${CONTENT_HASH:-?}" \
  "source: ${SOURCE_TAG:-build}" \
  "run: ${GITHUB_SERVER_URL:-}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}")"

git -c user.name="github-actions[bot]" \
  -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  tag -a "${TAG_NAME}" "${commit}" -m "${message}"
git push origin "refs/tags/${TAG_NAME}"

echo "Tag ${TAG_NAME} -> ${commit} (${IMAGE_TAG}, ${DIGEST})"
