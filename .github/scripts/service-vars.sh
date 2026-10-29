#!/usr/bin/env bash
# Mapeia a API escolhida no workflow para os nomes usados no build e no deploy.
# Único lugar para cadastrar uma API nova (build e promote leem daqui).
#
# Uso: service-vars.sh <Api>   (ex.: WebApi1)
# Saída (GITHUB_OUTPUT e stdout):
#   dotnet_project, project_file, dockerfile_path, image_name, image_slug, service_name
#
# image_name é só o nome do repo no Hub (sem o usuário). Incluir DOCKERHUB_USERNAME no
# job output faz o Actions descartar o valor ("may contain secret").
set -euo pipefail

SLUG="${1:?API obrigatória}"

case "${SLUG}" in
  "WebApi1")
    PROJ="WebApi1"; SVC="webapi1"; IMAGE_REPO="ci-test"
    ;;
  "WebApi2")
    PROJ="WebApi2"; SVC="webapi2"; IMAGE_REPO="ci-test-2"
    ;;
  *)
    echo "::error::API não suportada: ${SLUG}"
    exit 1
    ;;
esac

out="$(printf '%s\n' \
  "dotnet_project=${PROJ}" \
  "project_file=./${PROJ}/${PROJ}.csproj" \
  "dockerfile_path=./docker-compose/dockerfiles/${PROJ}.Dockerfile" \
  "image_name=${IMAGE_REPO}" \
  "image_slug=${SVC}" \
  "service_name=${SVC}")"
printf '%s\n' "${out}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf '%s\n' "${out}" >> "${GITHUB_OUTPUT}"
fi
