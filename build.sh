#!/bin/bash
# Builds the image, tagged from the version in the Containerfile.
#
#   ./build.sh              # build the default version
#   ./build.sh 2.27.1       # build a specific version
#
# The version is read back from the Containerfile rather than repeated here, so
# the tag and the contents cannot drift apart.
#
# Note there is no --pull=newer: the base image is pinned by digest in the
# Containerfile, which is what makes a given commit reproducible.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

REGISTRY=${REGISTRY:-quay.io/ricardoalonsos/mantis}

if [ $# -gt 0 ]; then
	VERSION=$1
else
	VERSION=$(sed -n 's/^ARG MANTIS_VERSION=\(.*\)$/\1/p' Containerfile)
fi

if [ -z "${VERSION:-}" ]; then
	echo "error: could not determine MANTIS_VERSION" >&2
	exit 1
fi

if [ ! -d "patches/$VERSION" ]; then
	echo "error: no patches/$VERSION directory; refusing to build an unpatched image" >&2
	exit 1
fi

if ! grep -q "  mantisbt-${VERSION}.tar.gz\$" checksums.sha256; then
	echo "error: no checksum for mantisbt-${VERSION}.tar.gz in checksums.sha256" >&2
	exit 1
fi

echo "Building ${REGISTRY}:${VERSION}"
# --format docker: podman's default OCI format silently discards HEALTHCHECK
# ("HEALTHCHECK is not supported for OCI image format and will be ignored").
podman build \
	--format docker \
	--build-arg "MANTIS_VERSION=$VERSION" \
	-t "${REGISTRY}:${VERSION}" \
	.

echo
echo "Built ${REGISTRY}:${VERSION}"
echo "Smoke test it with:  ./smoke-test.sh ${VERSION}"
echo "Publish it with:     ./push.sh ${VERSION}"
