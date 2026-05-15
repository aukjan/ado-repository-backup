#!/usr/bin/env bash

OPTIONAL_FLAGS=()

[[ "${DRY_RUN}" == "true" ]] && OPTIONAL_FLAGS+=(-x)
[[ "${WIKI}" == "true" ]] && OPTIONAL_FLAGS+=(-w)
[[ "${VERBOSE}" == "true" ]] && OPTIONAL_FLAGS+=(-v)
[[ "${NOCOMPRESS}" == "true" ]] && OPTIONAL_FLAGS+=(-n)
[[ "${BACKLOG}" == "true" ]] && OPTIONAL_FLAGS+=(-b)
[[ "${SKIP_REPOS}" == "true" ]] && OPTIONAL_FLAGS+=(-s)
[[ "${PIPELINES}" == "true" ]] && OPTIONAL_FLAGS+=(-l)
[[ "${ARTIFACTS}" == "true" ]] && OPTIONAL_FLAGS+=(-a)
[[ "${INCLUDE_DISABLED}" == "true" ]] && OPTIONAL_FLAGS+=(-e)
[[ -n "${PROJECT_FILTER:-}" ]] && OPTIONAL_FLAGS+=(-f "${PROJECT_FILTER}")

echo "INFO: running script ./backup-devops.sh -p $DEVOPS_PAT -o $DEVOPS_ORG_URL -d /data -r $RETENTION_DAYS ${OPTIONAL_FLAGS[*]}"
./backup-devops.sh -p "$DEVOPS_PAT" -o "$DEVOPS_ORG_URL" -d /data -r "$RETENTION_DAYS" "${OPTIONAL_FLAGS[@]}"
