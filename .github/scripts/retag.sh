#!/usr/bin/env bash
# Adiciona uma tag a uma imagem JÁ EXISTENTE no registry, identificada pelo digest.
# Não faz build nem pull: o registry copia o manifesto.
#
# Uso: retag.sh <imagem> <digest> <nova-tag>
#   ex.: retag.sh pedroreis16/ci-test sha256:ab12... hml-abc1234
#
# É idempotente e protege contra conflito:
#   - tag não existe                 -> cria apontando para o digest
#   - tag existe com o MESMO digest  -> não faz nada
#   - tag existe com OUTRO digest    -> falha (tags nunca são sobrescritas)
#
# `imagetools create` costuma envolver o manifesto original num índice OCI, então
# o digest da tag pode diferir do digest de origem. Isso é a mesma imagem se o
# índice tiver o digest original como filho.
set -euo pipefail

IMAGE="${1:?imagem obrigatória}"
DIGEST="${2:?digest obrigatório}"
TAG="${3:?tag obrigatória}"

inspect_digest() {
  docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null || true
}

child_digests() {
  docker buildx imagetools inspect "$1" --raw 2>/dev/null \
    | jq -r '.manifests[]?.digest // empty' 2>/dev/null || true
}

# 0 se a ref é o digest ou um índice que o contém.
points_to_digest() {
  local ref="$1"
  local want="$2"
  local top children
  top=$(inspect_digest "$ref")
  [[ "$top" == "$want" ]] && return 0
  children=$(child_digests "$ref")
  [[ -n "$children" ]] && printf '%s\n' "$children" | grep -qx "$want"
}

existing=$(inspect_digest "$IMAGE:$TAG")

if [[ -z "$existing" ]]; then
  echo "Criando $IMAGE:$TAG -> $DIGEST"
  docker buildx imagetools create --prefer-index=false --tag "$IMAGE:$TAG" "$IMAGE@$DIGEST"

  if ! points_to_digest "$IMAGE:$TAG" "$DIGEST"; then
    created=$(inspect_digest "$IMAGE:$TAG")
    echo "::error::$IMAGE:$TAG ficou com digest ${created:-desconhecido}, esperado $DIGEST (nem o índice aponta para ele)"
    exit 1
  fi
  echo "$IMAGE:$TAG aponta para $DIGEST"
elif points_to_digest "$IMAGE:$TAG" "$DIGEST"; then
  echo "$IMAGE:$TAG já aponta para $DIGEST, nada a fazer"
else
  echo "::error::Conflito: $IMAGE:$TAG já existe apontando para $existing (esperado $DIGEST). Tags nunca são sobrescritas."
  exit 1
fi