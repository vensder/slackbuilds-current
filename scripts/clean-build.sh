#!/usr/bin/env bash
#
# Show free disk space and the build leftovers of SlackBuilds, and remove them.
# Leftovers (source/build dirs and package staging dirs):
#   $TMP/*        Alien/vensder SlackBuilds (TMP default /tmp/build:
#                 tmp-<pkg>, package-<pkg>, ...)
#   $SBO_TMP/*    SlackBuilds.org (default /tmp/SBo: <pkg>-<ver>, package-<pkg>)
#   /tmp/package-<name>, /tmp/<pkg>-<ver>
#                 Slackware-style SlackBuilds with TMP=/tmp (e.g. raptor2);
#                 <pkg> must be a SlackBuild in this repo
# With -p also built packages and logs in $OUTPUT (default /tmp):
#   <name>-<ver>-<arch>-<build>.t?z  only if that package, or another version
#                 of it, is installed (built but not installed ones are kept)
#   build-*.log and Alien's {checkout,configure,make,install,error,makepkg,
#                 patch}-*.log
# With -s also downloaded source archives in the repo trees (alien, vensder,
# sbo): files git ignores and does not track, named *.tar.*, *.tgz, *.tbz,
# *.tbz2, *.zip, *.7z or *.backup. Tracked files and patches are never
# touched. The SlackBuilds download them again on the next build.
# Nothing else in /tmp is touched (X11, tmux, browser dirs, ...).
# Default: dry run, only lists sizes. Deleting needs -y and root.
#
# Usage: clean-build.sh [-p] [-s] [-y]
#   -p  also built package files and build logs in OUTPUT (see above)
#   -s  also source archives in the repo trees (see above)
#   -y  really delete (as root: su -c 'scripts/clean-build.sh -y')
#
# Environment overrides: TMP, SBO_TMP, OUTPUT, PKGDB, STRAY_DIR (default /tmp)

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
REPO_DIR=$(dirname "$SCRIPT_DIR")
TREES="alien vensder sbo"
TMP=${TMP:-/tmp/build}
SBO_TMP=${SBO_TMP:-/tmp/SBo}
OUTPUT=${OUTPUT:-/tmp}
PKGDB=${PKGDB:-/var/lib/pkgtools/packages}
STRAY_DIR=${STRAY_DIR:-/tmp}

usage() {
    sed -n '/^# Usage:/,/^#   -y/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

PACKAGES=0
SOURCES=0
DELETE=0
while getopts "psyh" opt; do
    case $opt in
        p) PACKAGES=1 ;;
        s) SOURCES=1 ;;
        y) DELETE=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage

if [ $DELETE -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: deleting requires root (build dirs are owned by root), e.g.:"
    echo "  su -c '$0 $*'"
    exit 1
fi

# Never empty a dir like / or /tmp itself (TMP=/tmp would wipe all of /tmp)
for d in "$TMP" "$SBO_TMP"; do
    case $(readlink -m "$d") in
        /|/tmp|/var/tmp|/root|/home|/home/*[!/]|/usr|/opt|/var)
            [[ $(readlink -m "$d") == /home/*/* ]] && continue
            echo "ERROR: refusing to clean '$d' (TMP/SBO_TMP must be a build-only dir)"
            exit 1
            ;;
    esac
done

# A running build would lose its files
if [ $DELETE -eq 1 ] && pgrep -f '\.SlackBuild( |$)' >/dev/null; then
    echo "ERROR: a SlackBuild is running, try again after it finishes:"
    pgrep -af '\.SlackBuild( |$)'
    exit 1
fi

echo "== Disk space"
df -h "$STRAY_DIR" "$OUTPUT" "$TMP" "$SBO_TMP" 2>/dev/null | awk 'NR == 1 || !seen[$0]++'

# Package names of all SlackBuilds in the repo trees
repo_names() {
    local t d
    for t in $TREES; do
        for d in "$REPO_DIR/$t"/*/; do
            [ -d "$d" ] && basename "$d"
        done
    done | sort -u
}

# Source archives: untracked files that .gitignore ignores, archives only
# (safe.directory: the repo belongs to the user, this runs as root)
list_sources() {
    local t
    for t in $TREES; do
        [ -d "$REPO_DIR/$t" ] || continue
        git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" ls-files -z \
            --others --ignored --exclude-standard -- "$t" ||
            echo "WARNING: git ls-files failed in $REPO_DIR, source archives skipped" >&2
    done | tr '\0' '\n' | grep -E '\.(tar\.[^/]+|tgz|tbz2?|zip|7z|backup)$' |
        sed "s|^|$REPO_DIR/|"
}

# Candidates, one path per line
list_targets() {
    local d f name
    for d in "$TMP" "$SBO_TMP"; do
        [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1
    done
    find "$STRAY_DIR" -mindepth 1 -maxdepth 1 -type d -name 'package-*'
    while read -r name; do
        find "$STRAY_DIR" -mindepth 1 -maxdepth 1 -type d -name "$name-[0-9]*"
    done < <(repo_names)

    [ $SOURCES -eq 1 ] && list_sources

    [ $PACKAGES -eq 1 ] || return 0
    # name-ver-arch-build.t?z: installed itself, or another version installed
    local installed
    installed=$(ls "$PKGDB" | rev | cut -d- -f4- | rev)
    for f in "$OUTPUT"/*-*-*-*.t?z; do
        [ -f "$f" ] || continue
        f=${f##*/}
        name=$(echo "${f%.t?z}" | rev | cut -d- -f4- | rev)
        if [ -e "$PKGDB/${f%.t?z}" ] || grep -qxF -- "$name" <<< "$installed"; then
            echo "$OUTPUT/$f"
        fi
    done
    find "$OUTPUT" -mindepth 1 -maxdepth 1 -type f \( -name 'build-*.log' \
        -o -name 'checkout-*.log' -o -name 'configure-*.log' -o -name 'make-*.log' \
        -o -name 'install-*.log' -o -name 'error-*.log' -o -name 'makepkg-*.log' \
        -o -name 'patch-*.log' \)
}

mapfile -t TARGETS < <(list_targets | sort -u)

echo
if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "== Nothing to clean"
    exit 0
fi

echo "== Build leftovers"
du -sh "${TARGETS[@]}" 2>/dev/null | sort -h
echo "Total: $(du -sch "${TARGETS[@]}" 2>/dev/null | tail -n1 | cut -f1)"
if [ $PACKAGES -eq 0 ]; then
    echo "(built packages and logs in $OUTPUT not included, add -p)"
fi
if [ $SOURCES -eq 0 ]; then
    echo "(source archives in $REPO_DIR not included, add -s)"
fi

echo
if [ $DELETE -eq 0 ]; then
    opts=
    [ $PACKAGES -eq 1 ] && opts="$opts -p"
    [ $SOURCES -eq 1 ] && opts="$opts -s"
    opts="${opts# } -y"
    echo "Dry run, nothing deleted. To delete: su -c '$0 $opts'"
    exit 0
fi

rm -rf -- "${TARGETS[@]}"
echo "Deleted ${#TARGETS[@]} entries."
echo
echo "== Disk space"
df -h "$STRAY_DIR" "$OUTPUT" "$TMP" "$SBO_TMP" 2>/dev/null | awk 'NR == 1 || !seen[$0]++'
