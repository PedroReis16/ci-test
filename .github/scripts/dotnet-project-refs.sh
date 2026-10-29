#!/usr/bin/env bash
# Resolve o grafo de ProjectReference a partir dos .csproj.
# Fonte de verdade para "quem consome qual library" — sem mapa manual.
#
# Uso (source ou CLI):
#   libraries <Projeto>   → Libraries/<Lib> (diretas + transitivas)
#   closure <Projeto>     → nomes das libraries
#   consumers <Library>   → serviços que referenciam a lib (direto ou via outra lib)
#   is-library <Nome>     → exit 0 se Libraries/<Nome>/<Nome>.csproj existir
#
# Quando sourced, exporta as funções dotnet_* abaixo.

# Raiz do monorepo: este arquivo vive em .github/scripts/.
_DOTNET_REFS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

declare -A _DOTNET_DIRECT_REFS=()
declare -A _DOTNET_LIB_SET=()
declare -A _DOTNET_CLOSURE_CACHE=()
_DOTNET_GRAPH_LOADED=0

_dotnet_refs_root() {
  if [[ -n "${REPO_ROOT:-}" ]]; then
    printf '%s\n' "${REPO_ROOT}"
    return 0
  fi
  printf '%s\n' "${_DOTNET_REFS_ROOT}"
}

dotnet_is_library() {
  local name="${1:-}"
  local root
  root="$(_dotnet_refs_root)"
  [[ -n "${name}" && -f "${root}/Libraries/${name}/${name}.csproj" ]]
}

dotnet_csproj_path() {
  local name="${1:-}"
  local root
  root="$(_dotnet_refs_root)"
  [[ -n "${name}" ]] || return 1
  if [[ -f "${root}/Libraries/${name}/${name}.csproj" ]]; then
    printf '%s\n' "${root}/Libraries/${name}/${name}.csproj"
    return 0
  fi
  if [[ -f "${root}/${name}/${name}.csproj" ]]; then
    printf '%s\n' "${root}/${name}/${name}.csproj"
    return 0
  fi
  return 1
}

# Nomes de projetos referenciados por um .csproj (só ProjectReference).
dotnet_project_references() {
  local csproj="${1:-}"
  local matches
  [[ -f "${csproj}" ]] || return 0
  matches="$(tr -d '\r' < "${csproj}" | grep -oE '<ProjectReference[^>]*Include="[^"]+\.csproj"' || true)"
  [[ -n "${matches}" ]] || return 0
  while IFS= read -r inc; do
    [[ -z "${inc}" ]] && continue
    inc="${inc#*Include=\"}"
    inc="${inc%\"}"
    inc="${inc//\\//}"
    basename "${inc}" .csproj
  done <<< "${matches}"
}

_dotnet_load_graph() {
  [[ "${_DOTNET_GRAPH_LOADED}" == "1" ]] && return 0
  local root csproj name
  root="$(_dotnet_refs_root)"

  for csproj in "${root}/Libraries/"*/*.csproj; do
    [[ -f "${csproj}" ]] || continue
    name="$(basename "${csproj}" .csproj)"
    _DOTNET_LIB_SET["${name}"]=1
    _DOTNET_DIRECT_REFS["${name}"]="$(dotnet_project_references "${csproj}")"
  done
  # Serviços na raiz (ex.: WebApi1/, WebApi2/), fora de Libraries/ e Tests/.
  for csproj in "${root}/"*/*.csproj; do
    [[ -f "${csproj}" ]] || continue
    case "${csproj#"${root}/"}" in
      Libraries/*|Tests/*) continue ;;
    esac
    name="$(basename "${csproj}" .csproj)"
    [[ -n "${_DOTNET_LIB_SET[${name}]:-}" ]] && continue
    _DOTNET_DIRECT_REFS["${name}"]="$(dotnet_project_references "${csproj}")"
  done
  _DOTNET_GRAPH_LOADED=1
}

# Libraries consumidas por um projeto (fecho transitivo via Libraries/).
dotnet_library_closure() {
  local start="${1:-}"
  local current ref refs result
  local -a queue
  declare -A seen=()
  declare -A libs=()

  [[ -n "${start}" ]] || return 0
  _dotnet_load_graph

  if [[ -n "${_DOTNET_CLOSURE_CACHE[${start}]+x}" ]]; then
    [[ -n "${_DOTNET_CLOSURE_CACHE[${start}]}" ]] && printf '%s\n' "${_DOTNET_CLOSURE_CACHE[${start}]}"
    return 0
  fi

  queue=("${start}")
  while ((${#queue[@]} > 0)); do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${seen[${current}]:-}" ]] && continue
    seen["${current}"]=1

    refs="${_DOTNET_DIRECT_REFS[${current}]:-}"
    while IFS= read -r ref; do
      [[ -z "${ref}" ]] && continue
      [[ -n "${_DOTNET_LIB_SET[${ref}]:-}" ]] || continue
      libs["${ref}"]=1
      queue+=("${ref}")
    done <<< "${refs}"
  done

  if ((${#libs[@]} == 0)); then
    _DOTNET_CLOSURE_CACHE["${start}"]=""
    return 0
  fi
  result="$(printf '%s\n' "${!libs[@]}" | LC_ALL=C sort)"
  _DOTNET_CLOSURE_CACHE["${start}"]="${result}"
  printf '%s\n' "${result}"
}

dotnet_library_paths() {
  local project="${1:-}"
  local lib
  while IFS= read -r lib; do
    [[ -z "${lib}" ]] && continue
    printf 'Libraries/%s\n' "${lib}"
  done < <(dotnet_library_closure "${project}")
}

# APIs/workers na raiz (não Libraries/, não Tests/).
dotnet_service_projects() {
  local name
  _dotnet_load_graph
  for name in "${!_DOTNET_DIRECT_REFS[@]}"; do
    [[ -n "${_DOTNET_LIB_SET[${name}]:-}" ]] && continue
    printf '%s\n' "${name}"
  done | LC_ALL=C sort
}

dotnet_library_consumers() {
  local lib="${1:-}"
  local svc closure
  [[ -n "${lib}" ]] || return 0
  _dotnet_load_graph
  while IFS= read -r svc; do
    [[ -z "${svc}" ]] && continue
    closure="$(dotnet_library_closure "${svc}")"
    if grep -qxF "${lib}" <<< "${closure}"; then
      printf '%s\n' "${svc}"
    fi
  done < <(dotnet_service_projects)
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  cmd="${1:-}"
  shift || true
  case "${cmd}" in
    libraries) dotnet_library_paths "$@" ;;
    closure) dotnet_library_closure "$@" ;;
    consumers) dotnet_library_consumers "$@" ;;
    is-library)
      if dotnet_is_library "$@"; then
        exit 0
      fi
      exit 1
      ;;
    *)
      echo "uso: $0 {libraries|closure|consumers|is-library} <nome>" >&2
      exit 2
      ;;
  esac
fi