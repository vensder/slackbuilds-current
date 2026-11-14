#!/usr/bin/env bash
#
# List installed custom packages (build tag alien, vensder or _SBo) that need
# a rebuild after system packages were updated (e.g. slackpkg upgrade-all).
# For each ELF file in a package's file list:
#   BROKEN   ldd reports a library "not found" (e.g. a soname bump: poppler,
#            icu4c, boost); the program or plugin no longer loads
#   UPDATED  a library it links to directly comes from a package that was
#            installed or upgraded after this package (ABI may have changed,
#            e.g. KF6/Qt6 for okular); rebuild to be safe
# Read-only: nothing on the system is changed. No root needed.
#
# Usage: check-rebuild.sh [-t tree] [-b] [name...]
#   -t tree  only packages of this tree: alien, vensder or sbo (default: all)
#   -b       broken only: skip the UPDATED check
#   name     only these package names (e.g. okular)
#
# Environment overrides:
#   IGNORE_DEPS  packages never reported as UPDATED (backward compatible
#                base libraries; default below)
#   PKGDB        for testing (default /var/lib/pkgtools/packages)

PKGDB=${PKGDB:-/var/lib/pkgtools/packages}
IGNORE_DEPS=${IGNORE_DEPS:-"aaa_glibc-solibs aaa_libraries glibc glibc-solibs gcc gcc-g++"}
TREES="alien vensder sbo"

usage() {
    sed -n '/^# Usage:/,/^#   name/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

TREE=
BROKEN_ONLY=0
while getopts "bt:h" opt; do
    case $opt in
        b) BROKEN_ONLY=1 ;;
        t) TREE=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

case $TREE in
    "")      TAGRE='(alien|vensder|_SBo)' ;;
    alien)   TAGRE='alien' ;;
    vensder) TAGRE='vensder' ;;
    sbo)     TAGRE='_SBo' ;;
    *) echo "ERROR: unknown tree '$TREE' (use one of: $TREES)" >&2; exit 1 ;;
esac

if [ ! -d "$PKGDB" ]; then
    echo "Cannot find $PKGDB" >&2
    exit 1
fi
for cmd in file ldd readelf; do
    if ! command -v $cmd >/dev/null; then
        echo "ERROR: $cmd not found" >&2
        exit 1
    fi
done

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# Package name: strip version, arch and build fields
pkg_name() {
    local rest=${1%-*-*-*}
    echo "$rest"
}

# Tree of a package (for the build command), from its build tag
pkg_tree() {
    case $1 in
        *_SBo)    echo sbo ;;
        *vensder) echo vensder ;;
        *)        echo alien ;;
    esac
}

# Installed custom packages
PKGS=()
for f in "$PKGDB"/*; do
    [ -f "$f" ] || continue
    pkg=${f##*/}
    printf '%s\n' "$pkg" | grep -qE -- "-[0-9]+$TAGRE\$" || continue
    if [ $# -gt 0 ]; then
        name=$(pkg_name "$pkg")
        case " $* " in
            *" $name "*) ;;
            *) continue ;;
        esac
    fi
    PKGS+=("$pkg")
done
if [ ${#PKGS[@]} -eq 0 ]; then
    echo "No installed packages match (tag regex: $TAGRE)"
    exit 0
fi

# Pass 1: per package, record broken libraries and resolved direct
# dependencies. Records (tab separated) in $TMP/rec:
#   pkg B file library
#   pkg D file /real/path/of/library
echo "Checking ${#PKGS[@]} package(s) ..." >&2
for pkg in "${PKGS[@]}"; do
    # Files after "FILE LIST:", directories skipped, only usual binary dirs
    sed -n '/^FILE LIST:/,$p' "$PKGDB/$pkg" | sed 1d \
        | grep -v '/$' \
        | grep -E '^(bin|sbin|lib|lib64|opt|usr/(bin|sbin|lib|lib64|libexec|games))/' \
        | sed 's|^|/|' > "$TMP/files"
    [ -s "$TMP/files" ] || continue
    tr '\n' '\0' < "$TMP/files" \
        | xargs -0 -r file -N -F '|' --mime-type 2>/dev/null \
        | awk -F'[|] ' '$2 ~ /^application\/x-(sharedlib|executable|pie-executable)$/ { print $1 }' \
        > "$TMP/elfs"
    while IFS= read -r elf; do
        [ -f "$elf" ] || continue
        # ldd exits non-zero when a library is missing: keep its output
        lddout=$(ldd "$elf" 2>/dev/null)
        [ -n "$lddout" ] || continue
        printf '%s\n' "$lddout" | awk -v p="$pkg" -v f="${elf#/}" \
            '$2 == "=>" && $3 == "not" { print p "\tB\t" f "\t" $1 }' >> "$TMP/rec"
        [ $BROKEN_ONLY -eq 1 ] && continue
        # Direct dependencies only (NEEDED), resolved by ldd
        readelf -d "$elf" 2>/dev/null \
            | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p' > "$TMP/needed"
        printf '%s\n' "$lddout" \
            | awk 'FNR == NR { need[$1] = 1; next }
                   $2 == "=>" && ($1 in need) && $3 ~ /^\// { print $3 }' \
                  "$TMP/needed" - \
            | while IFS= read -r lib; do
                  printf '%s\tD\t%s\t%s\n' "$pkg" "${elf#/}" "$(readlink -f "$lib")"
              done >> "$TMP/rec"
    done < "$TMP/elfs"
done
touch "$TMP/rec"

# Owner package of each dependency path (file lists have no leading "/")
if [ $BROKEN_ONLY -eq 0 ]; then
    awk -F'\t' '$2 == "D" { sub(/^\//, "", $4); print $4 }' "$TMP/rec" \
        | sort -u > "$TMP/deps"
    if [ -s "$TMP/deps" ]; then
        awk 'FNR == NR { need[$0] = 1; next }
             FNR == 1 { p = FILENAME; sub(/.*\//, "", p); inlist = 0 }
             /^FILE LIST:/ { inlist = 1; next }
             inlist && ($0 in need) { print $0 "\t" p }' \
            "$TMP/deps" "$PKGDB"/* > "$TMP/owners"
    fi
    touch "$TMP/owners"
fi

# Pass 2: report
fmt_time() {
    date -d "@$1" '+%Y-%m-%d %H:%M'
}

REBUILD=()
CMDS=()
for pkg in "${PKGS[@]}"; do
    name=$(pkg_name "$pkg")
    itime=$(stat -c %Y "$PKGDB/$pkg")
    out=

    # BROKEN: one line per missing library, with the first file needing it
    broken=$(awk -F'\t' -v p="$pkg" '$1 == p && $2 == "B" && !seen[$4]++ {
                 print "  BROKEN   " $4 " not found (" $3 ")" }' "$TMP/rec")
    [ -n "$broken" ] && out=$broken$'\n'

    # UPDATED: owner packages of direct dependencies, newer than this package
    if [ $BROKEN_ONLY -eq 0 ]; then
        while IFS= read -r owner; do
            [ -n "$owner" ] || continue
            oname=$(pkg_name "$owner")
            [ "$oname" = "$name" ] && continue
            case " $IGNORE_DEPS " in
                *" $oname "*) continue ;;
            esac
            otime=$(stat -c %Y "$PKGDB/$owner")
            [ "$otime" -gt "$itime" ] || continue
            out+="  UPDATED  $owner ($(fmt_time "$otime"))"$'\n'
        done < <(awk -F'\t' -v p="$pkg" '
                     FNR == NR { own[$1] = $2; next }
                     $1 == p && $2 == "D" { sub(/^\//, "", $4); if ($4 in own) print own[$4] }' \
                     "$TMP/owners" "$TMP/rec" | sort -u)
    fi

    [ -n "$out" ] || continue
    echo "$pkg (installed $(fmt_time "$itime"))"
    printf '%s' "$out"
    REBUILD+=("$name")
    CMDS+=("su -c 'scripts/build-slackbuild.sh -t $(pkg_tree "$pkg") -f -i $name'")
done

echo
if [ ${#REBUILD[@]} -eq 0 ]; then
    echo "No rebuilds needed (${#PKGS[@]} package(s) checked)."
    exit 0
fi
echo "Rebuild (${#REBUILD[@]} of ${#PKGS[@]}): ${REBUILD[*]}"
printf '  %s\n' "${CMDS[@]}"
exit 1
