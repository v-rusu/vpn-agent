#!/usr/bin/env bash
# Build the solomonar CLI (`sol`) for linux/arm64 from a local checkout and drop
# it at bin/solomonar-linux-arm64, where the Dockerfile COPYs it from.
#
#   scripts/fetch-solomonar.sh [path-to-solomonar-checkout]
#
# Default checkout: /Users/vlad/Projects/code-factory-workspace/solomonar
# The binary's `sol --version` reports the checkout's short HEAD.
set -euo pipefail

SRC="${1:-/Users/vlad/Projects/code-factory-workspace/solomonar}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/bin/solomonar-linux-arm64"

[[ -f "${SRC}/go.mod" ]] || { echo "not a solomonar checkout: ${SRC}" >&2; exit 1; }

REV="$(git -C "${SRC}" rev-parse --short HEAD)"
if [[ -n "$(git -C "${SRC}" status --porcelain --untracked-files=no)" ]]; then
    echo "warning: ${SRC} has uncommitted changes; binary is labelled ${REV} anyway" >&2
fi

mkdir -p "$(dirname "${OUT}")"
(
    cd "${SRC}"
    GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
        -ldflags "-X github.com/v-rusu/solomonar/internal/cli.version=${REV}" \
        -o "${OUT}" ./cmd/solomonar
)
echo "built ${OUT} (solomonar ${REV})"
