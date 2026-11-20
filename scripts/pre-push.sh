#!/bin/sh
# sow: public
# dt-media-vault main-push guard v1; deliberately no build, gate, or network.
set -eu
updates=$(cat)
printf '%s\n' "$updates" | while read -r local_ref local_oid remote_ref remote_oid; do
    if [ "$remote_ref" = refs/heads/main ]; then
        echo 'REFUSED: pushes to main are reserved for the authorized merger.' >&2
        exit 1
    fi
done
previous="$(dirname -- "$0")/pre-push.media-vault-previous"
if [ -x "$previous" ]; then
    printf '%s\n' "$updates" | "$previous" "$@"
fi
