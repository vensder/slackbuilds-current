#!/usr/bin/env bash
#
# Show what uses the most disk space: directories and installed Slackware
# packages at or above a size threshold (default 1G).
#   Directories  du of the given dirs (default /) and every subdir at any
#                depth that is at least SIZE, biggest first; a parent is
#                listed together with its big subdirs. Stays on one
#                filesystem (du -x) unless -a is given.
#   Packages     installed packages whose "UNCOMPRESSED PACKAGE SIZE" in
#                PKGDB is at least SIZE, biggest first.
#   Hints        pointers to the other scripts for known space hogs (build
#                leftovers in /tmp, more than two kernels installed).
# Read-only: nothing is deleted or changed.
# Run as root to see all dirs (as a user, unreadable dirs are skipped):
#   su -c 'scripts/disk-usage.sh'
#
# Usage: disk-usage.sh [-s SIZE] [-d DEPTH] [-a] [dir...]
#   -s SIZE  threshold, e.g. 500M, 2G (default 1G)
#   -d DEPTH only dirs up to DEPTH levels below each dir (default: any)
#   -a       cross filesystem boundaries (default: stay on each dir's fs)
#   dir      dirs to scan (default /)
#
# Environment overrides: PKGDB

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
PKGDB=${PKGDB:-/var/lib/pkgtools/packages}

usage() {
    sed -n '/^# Usage:/,/^#   dir/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

SIZE=1G
ONEFS=-x
DEPTH=
while getopts "s:d:ah" opt; do
    case $opt in
        s) SIZE=$OPTARG ;;
        d) DEPTH=$OPTARG ;;
        a) ONEFS= ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] && set -- /

# Threshold in bytes (accepts 1G, 500M, 1.5G, 2048K, plain bytes)
LIMIT=$(numfmt --from=iec "${SIZE^^}" 2>/dev/null)
if [ -z "$LIMIT" ] || [ "$LIMIT" -le 0 ]; then
    echo "ERROR: bad size '$SIZE' (examples: 500M, 1G, 2.5G)"
    exit 1
fi
case $DEPTH in
    *[!0-9]*) echo "ERROR: bad depth '$DEPTH' (a number)"; exit 1 ;;
esac
for d in "$@"; do
    [ -d "$d" ] || { echo "ERROR: not a directory: $d"; exit 1; }
done

echo "== Disk space"
df -h "$@" | awk 'NR == 1 || !seen[$0]++'

echo
echo "== Directories >= $SIZE ($*${ONEFS:+, one filesystem})"
[ "$(id -u)" -ne 0 ] && echo "(not root: unreadable dirs are skipped and sizes may be low)"
DIRS=$(du $ONEFS ${DEPTH:+-d "$DEPTH"} -t "$LIMIT" -B1 -- "$@" 2>/dev/null | sort -rn)
if [ -n "$DIRS" ]; then
    echo "$DIRS" | numfmt --to=iec --round=nearest --field=1 --format='%8.1f' | tr '\t' ' '
else
    echo "none"
fi

echo
echo "== Packages >= $SIZE (uncompressed, from $PKGDB)"
PKGS=$(for f in "$PKGDB"/*; do
    [ -f "$f" ] || continue
    s=$(sed -n 's/^UNCOMPRESSED PACKAGE SIZE:[[:space:]]*//p' "$f" | tr -d ' ')
    [ -n "$s" ] || continue
    b=$(numfmt --from=iec "${s^^}" 2>/dev/null) || continue
    echo "$b ${f##*/}"
done | sort -rn)
BIG=$(echo "$PKGS" | awk -v l="$LIMIT" '$1 >= l')
if [ -n "$BIG" ]; then
    echo "$BIG" | numfmt --to=iec --round=nearest --field=1 --format='%8.1f'
else
    echo "none"
fi
if [ -n "$PKGS" ]; then
    echo "All $(echo "$PKGS" | wc -l) packages: $(echo "$PKGS" | awk '{t += $1} END {print t}' | numfmt --to=iec --round=nearest --format='%.1f')"
fi

# Hints, only for what was found above
HINTS=
if echo "$DIRS" | grep -qE '[[:space:]]/tmp(/build|/SBo)?$'; then
    HINTS="$HINTS
- /tmp is big: build leftovers are listed by $SCRIPT_DIR/clean-build.sh -p
  (delete with su -c '$SCRIPT_DIR/clean-build.sh -p -y')"
fi
REPO_DIR=$(dirname "$SCRIPT_DIR")
if echo "$DIRS" | awk -F'\t' -v r="$REPO_DIR" '$2 == r {f = 1} END {exit !f}'; then
    HINTS="$HINTS
- $REPO_DIR is big: downloaded source archives are listed by
  $SCRIPT_DIR/clean-build.sh -s (delete with su -c '$SCRIPT_DIR/clean-build.sh -s -y')"
fi
NKERN=$(ls "$PKGDB" 2>/dev/null | grep -c '^kernel-generic-[0-9]')
if [ "$NKERN" -gt 2 ]; then
    HINTS="$HINTS
- $NKERN kernels installed: su -c '$SCRIPT_DIR/kernel-update.sh -d' removes all but the newest two"
fi
if [ -n "$HINTS" ]; then
    echo
    echo "== Hints$HINTS"
fi
