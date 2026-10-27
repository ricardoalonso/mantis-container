#!/bin/bash
# Publishes an image that exists locally.
#
#   ./push.sh               # push the version in the Containerfile
#   ./push.sh 2.27.1        # push a specific version
#   ./push.sh 2.27.1 --latest
#   ./push.sh --description-only   # only update the description on Quay
#
# The repository description on Quay is set from README-quay.md when
# QUAY_TOKEN (or QUAY_TOKEN_FILE) holds a Quay OAuth token with the
# "Administer Repositories" permission. The podman/skopeo login cannot do it:
# Quay's API does not accept registry credentials.
#
# `latest` is NOT moved unless you ask for it. The previous version of this
# script unconditionally republished a hard-coded 2.25.5 as latest, which would
# quietly hand every `docker pull ...:latest` a years-old MantisBT.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

REGISTRY=${REGISTRY:-quay.io/ricardoalonsos/mantis}
MOVE_LATEST=0
DESCRIPTION_ONLY=0
VERSION=""

for arg in "$@"; do
	case "$arg" in
		--latest) MOVE_LATEST=1 ;;
		--description-only) DESCRIPTION_ONLY=1 ;;
		-*) echo "error: unknown option '$arg'" >&2; exit 1 ;;
		*)  VERSION=$arg ;;
	esac
done

update_description() {
	local token=${QUAY_TOKEN:-}
	if [ -z "$token" ] && [ -n "${QUAY_TOKEN_FILE:-}" ]; then
		token=$(<"$QUAY_TOKEN_FILE")
	fi
	if [ -z "$token" ]; then
		echo "Left the Quay description alone. Set QUAY_TOKEN or QUAY_TOKEN_FILE to update it."
		return 0
	fi

	local api="https://${REGISTRY%%/*}/api/v1/repository/${REGISTRY#*/}"
	echo "Updating the description of ${REGISTRY} from README-quay.md"
	# The token goes in through a config file, not the command line, so it
	# does not show up in the process list.
	local response
	if ! response=$(jq -Rs '{description: .}' README-quay.md |
		curl -sS --fail-with-body -X PUT \
			--config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
			-H 'Content-Type: application/json' --data-binary @- "$api"); then
		echo "error: Quay refused the description update: ${response}" >&2
		return 1
	fi
}

if [ "$DESCRIPTION_ONLY" = "1" ]; then
	update_description
	exit 0
fi

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

update_description
