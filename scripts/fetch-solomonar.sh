#!/usr/bin/env bash
# Build the solomonar CLI (`sol`) for linux/arm64 and linux/amd64 from a local
# checkout and drop them at bin/solomonar-linux-<arch>, where the Dockerfile
# COPYs the one matching the image's arch from. ARCHES narrows the set.
#
#   scripts/fetch-solomonar.sh [path-to-solomonar-checkout]
#
# Default checkout: /Users/vlad/Projects/code-factory-workspace/solomonar
# The binary's `sol --version` reports the checkout's short HEAD.
set -euo pipefail

SRC="${1:-/Users/vlad/Projects/code-factory-workspace/solomonar}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHES="${ARCHES:-arm64 amd64}"

[[ -f "${SRC}/go.mod" ]] || { echo "not a solomonar checkout: ${SRC}" >&2; exit 1; }

REV="$(git -C "${SRC}" rev-parse --short HEAD)"
if [[ -n "$(git -C "${SRC}" status --porcelain --untracked-files=no)" ]]; then
    echo "warning: ${SRC} has uncommitted changes; binary is labelled ${REV} anyway" >&2
fi

mkdir -p "${REPO_ROOT}/bin"
for ARCH in ${ARCHES}; do
    OUT="${REPO_ROOT}/bin/solomonar-linux-${ARCH}"
    (
        cd "${SRC}"
        GOOS=linux GOARCH="${ARCH}" CGO_ENABLED=0 go build \
            -ldflags "-X github.com/v-rusu/solomonar/internal/cli.version=${REV}" \
            -o "${OUT}" ./cmd/solomonar
    )
    echo "built ${OUT} (solomonar ${REV})"
done
