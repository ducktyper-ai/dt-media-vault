#!/bin/sh
# sow: public
# dt-media-vault main-push guard v1; deliberately no build, gate, or network.
set -eu
umask 077
updates=$(mktemp "${TMPDIR:-/tmp}/dt-media-vault-pre-push.XXXXXX")
trap 'rm -f -- "$updates"' 0
trap 'exit 1' 1 2 15
cat > "$updates"
while read -r local_ref local_oid remote_ref remote_oid ||
      [ -n "${local_ref-}${local_oid-}${remote_ref-}${remote_oid-}" ]; do
    if [ "${remote_ref-}" = refs/heads/main ]; then
        echo 'REFUSED: pushes to main are reserved for the authorized merger.' >&2
        exit 1
    fi
done < "$updates"
previous="$(dirname -- "$0")/pre-push.media-vault-previous"
if [ -x "$previous" ]; then
    "$previous" "$@" < "$updates"
fi
