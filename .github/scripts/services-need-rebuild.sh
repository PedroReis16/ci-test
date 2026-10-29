#!/usr/bin/env bash
# Decide se o serviço precisa de build pelo CONTEÚDO que entra na imagem, e não por
# branch, ambiente ou tag Git. As tags continuam no padrão dev-<sha7> / hml-<sha7>:
# o hash de conteúdo não vira tag, só serve para achar uma imagem equivalente.
#
# O hash é calculado sobre o conteúdo versionado (hash de árvore/blob do Git) de tudo
# que entra no build do serviço:
#   - <Projeto>/ (ex.: WebApi1/)
#   - docker-compose/dockerfiles/<Projeto>.Dockerfile
#   - Libraries/<Lib>/ referenciadas pelo .csproj (diretas e transitivas)
#   - arquivos de build da raiz (Directory.Build.*, Directory.Packages.props, NuGet.config,
#     global.json) e o .image-rebuild (edite-o para forçar o rebuild de todos os serviços,
#     ex.: patch da imagem base)
#
# Procura, nesta ordem, uma imagem dev-<sha7>/hml-<sha7> cujo commit tenha o mesmo hash:
#   1. commits do histórico (first-parent) a partir de GIT_REF, enquanto o conteúdo do
#      serviço for igual ao atual (até MAX_HISTORY commits)
#   2. as tags que estão hoje no Helm de cada ambiente (HELM_VALUES_FILES), lidas da
#      cópia local e da origin/develop. Cobre imagens de commits fora deste histórico,
#      como a develop que andou depois do corte da release.
# Achou -> needs_rebuild=false e o digest dela (o deploy só cria a tag do ambiente).
# Não achou -> needs_rebuild=true.
#
# Env obrigatório: DOTNET_PROJECT, IMAGE_SLUG, REGISTRY_IMAGE_BASE
# Opcional: GIT_REF (padrão HEAD), HELM_VALUES_FILES (separados por espaço),
#   MAX_HISTORY (padrão 50), GITHUB_OUTPUT (Actions)
# Requer login prévio no registry e histórico do Git (checkout com fetch-depth: 0).
# Não cria nenhuma tag.
#
# Saída (GITHUB_OUTPUT e stdout):
#   needs_rebuild, reason, content_hash, existing_tag, existing_digest
set -euo pipefail

: "${DOTNET_PROJECT:?DOTNET_PROJECT é obrigatório}"
: "${IMAGE_SLUG:?IMAGE_SLUG é obrigatório}"
: "${REGISTRY_IMAGE_BASE:?REGISTRY_IMAGE_BASE é obrigatório}"
GIT_REF="${GIT_REF:-HEAD}"
MAX_HISTORY="${MAX_HISTORY:-50}"
ENV_PREFIXES=(dev hml)

# Mude a versão se alterar o algoritmo do hash.
HASH_VERSION="content-hash-v1"

# Arquivos da raiz que afetam o build de todos os projetos. Podem não existir.
ROOT_FILES=(
  "Directory.Build.props"
  "Directory.Build.targets"
  "Directory.Packages.props"
  "NuGet.config"
  "nuget.config"
  "global.json"
  ".image-rebuild"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dotnet-project-refs.sh
source "${SCRIPT_DIR}/dotnet-project-refs.sh"

emit() {
  local out
  out="$(printf '%s\n' \
    "needs_rebuild=$1" \
    "reason=$2" \
    "content_hash=${3:-}" \
    "existing_tag=${4:-}" \
    "existing_digest=${5:-}")"
  printf '%s\n' "${out}" >&2
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s\n' "${out}" >> "${GITHUB_OUTPUT}"
  fi
}

DOCKERFILE="docker-compose/dockerfiles/${DOTNET_PROJECT}.Dockerfile"

if ! dotnet_csproj_path "${DOTNET_PROJECT}" >/dev/null; then
  echo "::error::csproj de ${DOTNET_PROJECT} não encontrado."
  exit 1
fi

# Obrigatórios: se faltarem no commit, é erro de configuração.
REQUIRED=("${DOTNET_PROJECT}" "${DOCKERFILE}")
LIBS=()
while IFS= read -r lib_path; do
  [[ -n "${lib_path}" ]] && LIBS+=("${lib_path}")
done < <(dotnet_library_paths "${DOTNET_PROJECT}")

# Lista "<caminho> <objeto git>" das entradas da imagem num commit, já ordenada.
# Retorna 1 (e imprime o caminho) se um caminho obrigatório não existir nesse commit.
build_manifest() {
  local ref="$1" p obj out="${HASH_VERSION}"$'\n'
  for p in "${REQUIRED[@]}" "${LIBS[@]}"; do
    obj="$(git rev-parse --verify -q "${ref}:${p}" 2>/dev/null || true)"
    [[ -n "${obj}" ]] || { echo "${p}"; return 1; }
    out+="${p} ${obj}"$'\n'
  done
  for p in "${ROOT_FILES[@]}"; do
    obj="$(git rev-parse --verify -q "${ref}:${p}" 2>/dev/null || true)"
    out+="${p} ${obj:-absent}"$'\n'
  done
  printf '%s' "${out}" | LC_ALL=C sort
}

# Hash de conteúdo do serviço num commit (vazio se a estrutura não existir nele).
declare -A HASH_CACHE=()
hash_at() {
  local commit="$1" m
  if [[ -z "${HASH_CACHE[${commit}]+x}" ]]; then
    if m="$(build_manifest "${commit}")"; then
      HASH_CACHE["${commit}"]="$(printf '%s\n' "${m}" | sha256sum | cut -c1-12)"
    else
      HASH_CACHE["${commit}"]=""
    fi
  fi
  printf '%s' "${HASH_CACHE[${commit}]}"
}

registry_digest() {
  docker buildx imagetools inspect "${REGISTRY_IMAGE_BASE}:$1" \
    --format '{{.Manifest.Digest}}' 2>/dev/null || true
}

if ! manifest="$(build_manifest "${GIT_REF}")"; then
  echo "::error::Caminho ${manifest} não existe em ${GIT_REF} (está versionado?)."
  exit 1
fi
head_commit="$(git rev-parse --verify "${GIT_REF}^{commit}")"
content_hash="$(hash_at "${head_commit}")"

echo "Entradas da imagem de ${DOTNET_PROJECT} em ${GIT_REF}:"
printf '  %s\n' "${manifest//$'\n'/$'\n'  }"
echo "Hash de conteúdo: ${content_hash}"

# Tenta reusar a imagem de uma tag; sai do script se ela tiver o mesmo conteúdo.
declare -A TRIED=()
try_tag() {
  local tag="$1" commit="$2" source="$3" d
  [[ -n "${TRIED[${tag}]:-}" ]] && return 0
  TRIED["${tag}"]=1
  [[ "$(hash_at "${commit}")" == "${content_hash}" ]] || return 0
  d="$(registry_digest "${tag}")"
  [[ -n "${d}" ]] || return 0
  echo "Imagem ${tag} (${source}) tem o mesmo conteúdo: ${d}. Sem build."
  emit "false" "content-exists:${tag}" "${content_hash}" "${tag}" "${d}"
  exit 0
}

# 1. Histórico: commits com o mesmo conteúdo do serviço, do mais novo para o mais antigo.
#    Para no primeiro commit em que o conteúdo muda.
checked=0
while IFS= read -r commit; do
  if [[ "$(hash_at "${commit}")" != "${content_hash}" ]]; then
    break
  fi
  checked=$((checked + 1))
  for prefix in "${ENV_PREFIXES[@]}"; do
    try_tag "${prefix}-${commit:0:7}" "${commit}" "histórico"
  done
done < <(git rev-list --first-parent --max-count="${MAX_HISTORY}" "${head_commit}")
echo "Histórico: ${checked} commit(s) com o mesmo conteúdo, nenhum com imagem dev/hml."

# 2. Tags que estão hoje no Helm. Os bumps são mergeados na branch do deploy:
#    o estado de dev vive na develop.
helm_tag() {
  sed -nE 's/^[[:space:]]*tag:[[:space:]]*["'\'']?([^"'\'' #]+)["'\'']?.*/\1/p' | head -n 1
}
helm_tags=()
for values in ${HELM_VALUES_FILES:-}; do
  if [[ -f "${values}" ]]; then
    t="$(helm_tag < "${values}")"
    [[ -n "${t}" ]] && helm_tags+=("${t}")
  fi
  t="$(git show "origin/develop:${values}" 2>/dev/null | helm_tag || true)"
  [[ -n "${t}" ]] && helm_tags+=("${t}")
done
for tag in "${helm_tags[@]}"; do
  [[ "${tag}" =~ ^(dev|hml)-([0-9a-f]{7})$ ]] || continue
  commit="$(git rev-parse --verify -q "${BASH_REMATCH[2]}^{commit}" 2>/dev/null || true)"
  if [[ -z "${commit}" ]]; then
    echo "Helm ${tag}: commit não encontrado no histórico (ou SHA curto ambíguo), ignorando."
    continue
  fi
  try_tag "${tag}" "${commit}" "Helm"
done

echo "Nenhuma imagem dev/hml com esse conteúdo. Build necessário."
emit "true" "content-new" "${content_hash}" "" ""