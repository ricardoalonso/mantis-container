#!/bin/bash
# Publishes an image that exists locally.
#
#   ./push.sh               # push the version in the Containerfile
#   ./push.sh 2.27.1        # push a specific version
#   ./push.sh 2.27.1 --latest
#
# `latest` is NOT moved unless you ask for it. The previous version of this
# script unconditionally republished a hard-coded 2.25.5 as latest, which would
# quietly hand every `docker pull ...:latest` a years-old MantisBT.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

REGISTRY=${REGISTRY:-quay.io/ricardoalonsos/mantis}
MOVE_LATEST=0
VERSION=""

for arg in "$@"; do
	case "$arg" in
		--latest) MOVE_LATEST=1 ;;
		-*) echo "error: unknown option '$arg'" >&2; exit 1 ;;
		*)  VERSION=$arg ;;
	esac
done

if [ -z "$VERSION" ]; then
	VERSION=$(sed -n 's/^ARG MANTIS_VERSION=\(.*\)$/\1/p' Containerfile)
fi

if ! podman image exists "${REGISTRY}:${VERSION}"; then
	echo "error: ${REGISTRY}:${VERSION} is not built locally. Run ./build.sh ${VERSION}" >&2
	exit 1
fi

echo "Pushing ${REGISTRY}:${VERSION}"
podman push "${REGISTRY}:${VERSION}"

if [ "$MOVE_LATEST" = "1" ]; then
	echo "Moving ${REGISTRY}:latest to ${VERSION}"
	skopeo copy "docker://${REGISTRY}:${VERSION}" "docker://${REGISTRY}:latest"
else
	echo "Left ${REGISTRY}:latest alone. Pass --latest to move it."
fi
