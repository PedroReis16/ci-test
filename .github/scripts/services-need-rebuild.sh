#!/usr/bin/env bash
# Decide se o serviço precisa de build pelo CONTEÚDO que entra na imagem, e não por
# branch, ambiente ou tag Git. As tags de imagem continuam no padrão dev-<sha7> /
# hml-<sha7>: o hash de conteúdo não vira tag, só serve para achar uma imagem equivalente.
#
# O hash é calculado sobre o conteúdo versionado (hash de blob do Git, arquivo a arquivo)
# de tudo que entra no build do serviço:
#   - <Projeto>/ (ex.: WebApi1/), menos o que está em IMAGE_EXCLUDES
#   - docker-compose/dockerfiles/<Projeto>.Dockerfile
#   - Libraries/<Lib>/ referenciadas pelo .csproj (diretas e transitivas), menos IMAGE_EXCLUDES
#   - arquivos de build da raiz (Directory.Build.*, Directory.Packages.props, NuGet.config,
#     global.json) e o .image-rebuild (edite-o para forçar o rebuild de todos os serviços,
#     ex.: patch da imagem base)
#
# Configuração de ambiente (appsettings*.json, launchSettings) não entra no hash nem na
# imagem: vem do deploy (env/ConfigMap/Secret no Helm). Mudar config não gera build.
#
# Cada deploy registra uma tag Git <serviço>/<tag-da-imagem> (ex.: webapi1/dev-abc1234),
# criada pelo git-deploy-tag.sh. Este script compara o conteúdo atual com os últimos
# DEPLOYS_PER_ENV deploys de CADA ambiente (dev e hml), não só do ambiente atual:
#   - homolog depois do merge da develop -> bate com o último deploy de dev
#   - develop depois do back-merge da release -> bate com o último deploy de hml
#   - mudança só de config -> bate com o último deploy do próprio ambiente
# Bateu -> confirma no registry que a imagem existe (uma consulta) e devolve o digest:
#   needs_rebuild=false (o deploy só cria a tag do ambiente).
# Não bateu (ou não há deploy anterior) -> needs_rebuild=true.
#
# Env obrigatório: DOTNET_PROJECT, IMAGE_SLUG (prefixo das tags Git), REGISTRY_IMAGE_BASE
# Opcional: GIT_REF (padrão HEAD), DEPLOYS_PER_ENV (padrão 1), GITHUB_OUTPUT (Actions)
# Requer login prévio no registry e as tags Git (checkout com fetch-depth: 0).
# Não cria nenhuma tag.
#
# Saída (GITHUB_OUTPUT e stdout):
#   needs_rebuild, reason, content_hash, existing_tag, existing_digest
set -euo pipefail

: "${DOTNET_PROJECT:?DOTNET_PROJECT é obrigatório}"
: "${IMAGE_SLUG:?IMAGE_SLUG é obrigatório}"
: "${REGISTRY_IMAGE_BASE:?REGISTRY_IMAGE_BASE é obrigatório}"
GIT_REF="${GIT_REF:-HEAD}"
DEPLOYS_PER_ENV="${DEPLOYS_PER_ENV:-1}"
ENV_PREFIXES=(dev hml)

# Mude a versão se alterar o algoritmo do hash.
HASH_VERSION="content-hash-v2"

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

# Arquivos dentro do projeto/libs que NÃO entram na imagem. Mantenha em sincronia com o
# .dockerignore: o que ele exclui do contexto não pode mudar o hash.
IMAGE_EXCLUDES=(
  "*/bin/*"
  "*/obj/*"
  "*/Properties/launchSettings.json"
  "*/appsettings*.json"
  "*.http"
  "*/README.md"
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

is_excluded() {
  local file="$1" pattern
  for pattern in "${IMAGE_EXCLUDES[@]}"; do
    # shellcheck disable=SC2254
    case "${file}" in ${pattern}) return 0 ;; esac
  done
  return 1
}

# Lista "<arquivo> <blob git>" das entradas da imagem num commit, já ordenada.
# Retorna 1 (e imprime o caminho) se um caminho obrigatório não existir nesse commit.
build_manifest() {
  local ref="$1" p obj file listing found out="${HASH_VERSION}"$'\n'
  for p in "${REQUIRED[@]}" "${LIBS[@]}"; do
    listing="$(git ls-tree -r --full-tree "${ref}" -- "${p}" 2>/dev/null || true)"
    found=0
    while IFS=$'\t' read -r meta file; do
      [[ -n "${file}" ]] || continue
      found=1
      is_excluded "${file}" && continue
      obj="${meta##* }"
      out+="${file} ${obj}"$'\n'
    done <<< "${listing}"
    [[ "${found}" == "1" ]] || { echo "${p}"; return 1; }
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

# Últimos deploys de cada ambiente, do mais novo para o mais antigo.
checked=0
for prefix in "${ENV_PREFIXES[@]}"; do
  while IFS= read -r git_tag; do
    [[ -n "${git_tag}" ]] || continue
    image_tag="${git_tag#"${IMAGE_SLUG}/"}"
    commit="$(git rev-parse --verify -q "refs/tags/${git_tag}^{commit}" 2>/dev/null || true)"
    [[ -n "${commit}" ]] || continue
    checked=$((checked + 1))
    deployed_hash="$(hash_at "${commit}")"
    if [[ "${deployed_hash}" != "${content_hash}" ]]; then
      echo "Último deploy ${git_tag}: conteúdo ${deployed_hash:-desconhecido}, diferente."
      continue
    fi
    d="$(registry_digest "${image_tag}")"
    if [[ -z "${d}" ]]; then
      echo "::warning::${git_tag} tem o mesmo conteúdo, mas a imagem ${image_tag} não está no registry."
      continue
    fi
    echo "Último deploy ${git_tag} tem o mesmo conteúdo: ${d}. Sem build."
    emit "false" "content-exists:${image_tag}" "${content_hash}" "${image_tag}" "${d}"
    exit 0
  done < <(git for-each-ref --sort=-creatordate --count="${DEPLOYS_PER_ENV}" \
    --format='%(refname:strip=2)' "refs/tags/${IMAGE_SLUG}/${prefix}-*")
done

if ((checked == 0)); then
  echo "Nenhum deploy anterior de ${IMAGE_SLUG} (tags ${IMAGE_SLUG}/dev-*, ${IMAGE_SLUG}/hml-*). Build necessário."
  emit "true" "first-deploy" "${content_hash}" "" ""
  exit 0
fi
echo "Conteúdo diferente dos últimos deploys de dev/hml. Build necessário."
emit "true" "content-new" "${content_hash}" "" ""
