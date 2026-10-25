#!/bin/bash
# Fills /mantis/plugins, the MantisBT plugin directory, on every start.
#
# MantisBT's plugins/ is a symlink to /mantis/plugins (a volume), which holds
# three kinds of plugin:
#
#  - Bundled: the plugins that come with this image (MantisBT's own, which must
#    match its version, and OidcAuth). Replaced on every start; their names are
#    reserved.
#  - Downloaded: archives listed in MANTIS_PLUGINS, each pinned by sha256.
#    Cached in the volume (.archive-<sha256> files), so a restart does not need
#    the network once they have been fetched. Installed again on every start, and removed when they
#    leave the list.
#  - Your own: any other folder. Never touched.
#
# Installing a plugin's files does not enable it: that is still done in
# Manage > Manage Plugins, which records it in the database.
set -euo pipefail

# shellcheck source=../lib/mantis/common.sh
source /usr/local/lib/mantis/common.sh
set_defaults

BUNDLED_MARK="$PLUGINS_DIR/.bundled"
DOWNLOADED_MARK="$PLUGINS_DIR/.downloaded"
# Cached archives are files, not a folder: MantisBT lists every folder in the
# plugin directory as a plugin, dot-folders included.
CACHE_PREFIX="$PLUGINS_DIR/.archive-"

file_env MANTIS_PLUGINS

# Group-writable, like the rest of the image: under OpenShift's arbitrary user
# IDs, group 0 is what stays constant between pods.
umask 0002

# A plugin is a folder <Name> holding <Name>.php, which declares
# "class <Name>Plugin extends ...": that is how MantisBT loads it. Not
# necessarily MantisPlugin directly; source-integration's plugins extend their
# own base classes. The basename rule is plugin.php's.
valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }

# --- Validate MANTIS_PLUGINS before touching anything -------------------------
# Entries are separated by whitespace (newlines too, for _FILE):
#   https://example.com/Foo-1.2.tar.gz#sha256=<64 hex digits>
entries=()
for entry in ${MANTIS_PLUGINS:-}; do
	[[ $entry =~ ^(https?|file)://[^#]+#sha256=[0-9A-Fa-f]{64}$ ]] \
		|| die "MANTIS_PLUGINS entry '$entry' is not valid: expected <http(s) or file URL>#sha256=<64 hex digits>"
	entries+=("$entry")
done

[ -d "$PLUGINS_DIR" ] && [ -w "$PLUGINS_DIR" ] \
	|| die "$PLUGINS_DIR is not a writable directory for uid $(id -u). For a bind mount, run: podman unshare chown 48:0 <dir>"

# --- Bundled plugins ----------------------------------------------------------
mapfile -t bundled < <(find "$BUNDLED_PLUGINS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

# Remove bundled plugins an earlier image shipped and this one no longer does.
if [ -f "$BUNDLED_MARK" ]; then
	while read -r old; do
		valid_name "$old" || continue
		[ -d "$BUNDLED_PLUGINS_DIR/$old" ] && continue
		log "Removing $old: no longer shipped with the image"
		rm -rf "${PLUGINS_DIR:?}/$old"
	done < "$BUNDLED_MARK"
fi
for name in "${bundled[@]}"; do
	rm -rf "${PLUGINS_DIR:?}/$name"
	cp -R "$BUNDLED_PLUGINS_DIR/$name" "$PLUGINS_DIR/"
done
# Upstream's deny-all, should anything ever serve this folder directly.
cp "$BUNDLED_PLUGINS_DIR/.htaccess" "$PLUGINS_DIR/.htaccess"
printf '%s\n' "${bundled[@]}" > "$BUNDLED_MARK"

# --- Downloaded plugins -------------------------------------------------------
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

declare -A downloaded=()   # name -> URL
declare -A wanted_sums=()  # sha256 -> 1, for pruning the cache
staged=()                  # name<TAB>source dir, in $work
n=0
for entry in "${entries[@]}"; do
	url=${entry%#sha256=*}
	sum=${entry##*#sha256=}; sum=${sum,,}
	wanted_sums[$sum]=1
	archive="$CACHE_PREFIX$sum"

	# The cache is keyed by checksum, so a changed URL with the same content
	# is not fetched again, and a tampered cache file is caught here.
	if [ -f "$archive" ] && printf '%s  %s\n' "$sum" "$archive" | sha256sum --check --status; then
		:
	else
		log "Downloading plugin archive $url"
		# Straight into the volume. A file moved in from /tmp keeps this
		# container's private SELinux label, and the next container could
		# not read it.
		partial=$(mktemp "$PLUGINS_DIR/.partial.XXXXXX")
		curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 \
			-o "$partial" "$url" \
			|| { rm -f "$partial"; die "could not download $url"; }
		actual=$(sha256sum "$partial" | cut -d' ' -f1)
		[ "$actual" = "$sum" ] \
			|| { rm -f "$partial"; die "checksum mismatch for $url: expected $sum, got $actual"; }
		mv "$partial" "$archive"
	fi

	n=$((n + 1))
	dest="$work/x$n"
	mkdir -p "$dest"
	# By content, not by name: URLs often have no extension.
	if [ "$(head -c 2 "$archive")" = "PK" ]; then
		unzip -q "$archive" -d "$dest" || die "could not unpack $url (zip)"
	else
		tar -xf "$archive" -C "$dest" --no-same-owner --no-same-permissions \
			|| die "could not unpack $url (tar)"
	fi

	found=0
	while read -r php; do
		name=$(basename "$php" .php)
		valid_name "$name" || continue
		grep -Eq "^[[:space:]]*class[[:space:]]+${name}Plugin[[:space:]]+extends[[:space:]]" "$php" || continue
		for b in "${bundled[@]}"; do
			[ "$b" = "$name" ] && die "$url contains plugin $name, which comes with the image and cannot be replaced"
		done
		[ -z "${downloaded[$name]:-}" ] \
			|| die "plugin $name is in both ${downloaded[$name]} and $url"
		downloaded[$name]=$url
		staged+=("$name"$'\t'"$(dirname "$php")")
		found=$((found + 1))
	done < <(find "$dest" -mindepth 1 -maxdepth 5 -type f -name '*.php' | sort)
	(( found > 0 )) || die "$url contains no MantisBT plugin (a <Name>.php declaring class <Name>Plugin)"
done

# Remove plugins downloaded on an earlier start that are no longer listed.
if [ -f "$DOWNLOADED_MARK" ]; then
	while read -r old; do
		valid_name "$old" || continue
		[ -n "${downloaded[$old]:-}" ] && continue
		log "Removing $old: no longer in MANTIS_PLUGINS"
		rm -rf "${PLUGINS_DIR:?}/$old"
	done < "$DOWNLOADED_MARK"
fi

for item in "${staged[@]}"; do
	name=${item%%$'\t'*}
	src=${item#*$'\t'}
	if [ -d "$PLUGINS_DIR/$name" ] && ! grep -qxF "$name" "$DOWNLOADED_MARK" 2>/dev/null; then
		warn "Replacing your own folder $PLUGINS_DIR/$name with $name from ${downloaded[$name]}"
	fi
	rm -rf "${PLUGINS_DIR:?}/$name"
	cp -R "$src" "$PLUGINS_DIR/$name"
done
if (( ${#downloaded[@]} )); then
	printf '%s\n' "${!downloaded[@]}" | sort > "$DOWNLOADED_MARK"
else
	: > "$DOWNLOADED_MARK"
fi

# Archives no longer referenced, and an earlier version's .cache folder.
for f in "$CACHE_PREFIX"*; do
	[ -e "$f" ] || continue
	[ -n "${wanted_sums[${f#"$CACHE_PREFIX"}]:-}" ] || rm -f "$f"
done
rm -rf "${PLUGINS_DIR:?}/.cache"

# --- Report -------------------------------------------------------------------
own=()
for d in "$PLUGINS_DIR"/*/; do
	name=$(basename "$d")
	[[ " ${bundled[*]} " == *" $name "* ]] && continue
	[ -n "${downloaded[$name]:-}" ] && continue
	own+=("$name")
done
names=''
(( ${#downloaded[@]} )) && names=$(printf '%s\n' "${!downloaded[@]}" | sort | paste -sd' ')
log "Plugins: bundled ${bundled[*]}; downloaded ${names:-(none)}; your own ${own[*]:-(none)}"
