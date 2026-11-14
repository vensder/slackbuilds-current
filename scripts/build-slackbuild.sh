#!/usr/bin/env bash
#
# Build (and optionally install) SlackBuilds from this repo's trees:
#   alien/<package>/build/    (Alien Bob, fetched with download-slackbuilds.sh)
#   vensder/<package>/build/  (own SlackBuilds)
#   sbo/<package>/            (SlackBuilds.org; source downloaded from .info)
#
# Usage: build-slackbuild.sh [-t tree] [-cdfinqv] [-V version] <package>
#        build-slackbuild.sh [-t tree] -a [-cdfinqv]

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
REPO_DIR=$(dirname "$SCRIPT_DIR")
# Trees in the order searched for dependencies (after the selected one)
TREES="vensder alien sbo"
OUTPUT=${OUTPUT:-/tmp}
export OUTPUT
PKGDB=${PKGDB:-/var/lib/pkgtools/packages}

usage() {
    cat <<EOF
Usage: $0 [-t tree] [-cdfinqv] [-V version] <package>
       $0 [-t tree] -a [-cdfinqv]
  -t tree     SlackBuild tree: alien (default), vensder or sbo
              ($REPO_DIR/<tree>; without -t, SBDIR=... overrides it)
  -a          all installed packages with the tree's build tag
              (alien, vensder, _SBo; override with PKGTAG=...) instead of <package>;
              -a -c checks them all, -a -n -i upgrades them to newest upstream
  -c          check only: show versions (incl. upstream), do not build
  -d          also process dependencies from slack-required, recursively;
              missing or outdated dependencies are built and installed first
  -f          rebuild <package> even if this version is already installed
              (keeps the installed version if it is newer than the default)
  -i          install/upgrade <package> after a successful build
  -n          build the newest upstream version instead of the SlackBuild default
  -q          quiet: send SlackBuild output to a log file in $OUTPUT
              (shows the last lines on failure)
  -v          verbose: show URLs requested by the upstream version check
  -V version  build this exact version of <package>
Dependencies come from slack-required (alien, vensder) or REQUIRES in
<package>.info (sbo, names mapped via sbo/.aliases); they are looked up in the selected tree first, then in
the others ($TREES).
sbo: missing sources are downloaded from DOWNLOAD in <package>.info (MD5
checked only for the .info version; for -V/-n the version in the URL is replaced).
Hold list: <tree>/.hold (skipped by -a/-d; override with HOLD_FILE=...)
EOF
    exit 1
}

ALL=0
CHECK_ONLY=0
DEPS=0
FORCE=0
INSTALL=0
NEWEST=0
QUIET=0
VERBOSE=0
USER_VER=
TREE=alien
TREE_SET=0
while getopts "acdfinqt:vV:h" opt; do
    case $opt in
        a) ALL=1 ;;
        c) CHECK_ONLY=1 ;;
        d) DEPS=1 ;;
        f) FORCE=1 ;;
        i) INSTALL=1 ;;
        n) NEWEST=1 ;;
        q) QUIET=1 ;;
        t) TREE=$OPTARG; TREE_SET=1 ;;
        v) VERBOSE=1 ;;
        V) USER_VER=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
case " $TREES " in
    *" $TREE "*) ;;
    *) echo "ERROR: unknown tree '$TREE' (use one of: $TREES)"; exit 1 ;;
esac
# -t wins over SBDIR/PKGTAG/HOLD_FILE left in the environment
if [ $TREE_SET -eq 1 ]; then
    unset SBDIR PKGTAG HOLD_FILE
fi
SBDIR=${SBDIR:-$REPO_DIR/$TREE}
# Build tag of the packages handled by -a
case $TREE in
    sbo) PKGTAG=${PKGTAG:-_SBo} ;;
    *)   PKGTAG=${PKGTAG:-$TREE} ;;
esac
# Packages on hold (one name per line, # comments): skipped by -a and -d,
# built only when named directly. E.g. carla kept at a stable release while
# the SlackBuild default is a newer-sorting git snapshot.
HOLD_FILE=${HOLD_FILE:-$SBDIR/.hold}
if [ $ALL -eq 1 ]; then
    [ $# -eq 0 ] || usage
    if [ -n "$USER_VER" ]; then
        echo "ERROR: -V can't be used with -a"
        exit 1
    fi
else
    [ $# -eq 1 ] || usage
fi

if [ $CHECK_ONLY -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: building requires root, e.g.: su -c '$0 $*'"
    exit 1
fi

# Download a URL to stdout for the version check. Short timeout and one retry,
# so an unresponsive site can't hang the run (wget default: 900s, 20 tries)
fetch() {
    [ $VERBOSE -eq 1 ] && echo "  fetching: $1" >&2
    wget -qO- -T 15 -t 2 "$1"
}

# Escape a string for use in an extended regex (and as a sed pattern)
re_escape() {
    printf '%s' "$1" | sed 's/[][\.*^$()+?{}|/]/\\&/g'
}

# Return 0 if version $1 is greater than version $2
ver_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Installed version of a package name, empty if not installed
installed_version() {
    ls "$PKGDB" 2>/dev/null \
        | grep -E "^$(re_escape "$1")-[^-]+-[^-]+-[^-]+$" \
        | sed -E 's/.*-([^-]+)-[^-]+-[^-]+$/\1/' | head -n1
}

# Evaluate the top-level "VAR=..." lines of a SlackBuild one by one (so a
# multi-line assignment can't break the rest), stopping after the line that
# sets variable $2. Prints that variable's value. Runs in a subshell.
# $3: initial value of VERSION (empty = unset)
sb_eval_var() {
    local file var=$2 init=$3
    file=$(readlink -f "$1")
    (
        # Run in the build dir like the SlackBuild itself (some derive
        # VERSION from the tarball there, e.g. VERSION=$(ls *.tar.* ...))
        cd "$(dirname "$file")" || exit
        unset VERSION
        [ -n "$init" ] && VERSION=$init
        while IFS= read -r line; do
            # $0 is the SlackBuild when it runs, not this script
            line=${line//\$\{0\}/$file}
            line=${line//\$0/$file}
            # skip lines that don't parse alone (would abort the subshell)
            bash -n -c "$line" 2>/dev/null && eval "$line" 2>/dev/null
        done < <(awk -v v="$var" '
            $0 ~ "^" v "(\\[0\\])?=" { sub("^" v "\\[0\\]=", v "="); print; exit }
            /^[A-Za-z_][A-Za-z0-9_]*=/ { print }' "$file")
        printf '%s\n' "${!var}"
    )
}

# Default VERSION of SlackBuild $1, with variables resolved, e.g.
# VERSION=${VERSION:-${MINGW}_gcc${GCC}} -> v11.0.0_gcc13.1.0
# Some Alien SlackBuilds set VERSION=${VERSION:-""} and pick it later from
# VERSION_CUR (-current) or VERSION_150 (15.0): use VERSION_CUR then.
sb_version() {
    local v
    v=$(sb_eval_var "$1" VERSION "")
    [ -n "$v" ] || v=$(sb_eval_var "$1" VERSION_CUR "")
    printf '%s\n' "$v"
}

# SRCURL from SlackBuild $1, with @VERSION@ in place of the version
srcurl_template() {
    sb_eval_var "$1" SRCURL @VERSION@
}

# Read text on stdin, print versions found as <prefix>VERSION<suffix>
extract_versions() {
    local pre suf
    pre=$(re_escape "$1")
    suf=$(re_escape "$2")
    grep -oE "${pre}[0-9]+(\.[0-9]+)*${suf}" | sed -E "s/^${pre}//; s/${suf}\$//"
}

# Print a variable from an SBo .info file (shell variable assignments)
info_var() {
    ( . "$1" 2>/dev/null; printf '%s\n' "${!2}" )
}

# Source URLs of an SBo .info, one "url md5" per line
# (DOWNLOAD_x86_64 if set and not UNSUPPORTED, else DOWNLOAD)
info_sources() {
    (
        . "$1" 2>/dev/null
        if [ "$(uname -m)" = x86_64 ] && [ -n "$DOWNLOAD_x86_64" ] \
            && [ "$DOWNLOAD_x86_64" != UNSUPPORTED ]; then
            DOWNLOAD=$DOWNLOAD_x86_64
            MD5SUM=$MD5SUM_x86_64
        fi
        # shellcheck disable=SC2086
        set -- $MD5SUM
        for url in $DOWNLOAD; do
            echo "$url ${1:-}"
            [ $# -gt 0 ] && shift
        done
    )
}

# Source URL template (@VERSION@ for the version) of an SBo .info
info_url_template() {
    local ver url
    ver=$(info_var "$1" VERSION)
    url=$(info_sources "$1" | awk 'NR == 1 { print $1 }')
    [ -n "$ver" ] && [ -n "$url" ] && printf '%s\n' "${url//$ver/@VERSION@}"
}

# Download missing sources of an SBo package into its dir.
# $1 = dir, $2 = .info file, $3 = version to build
fetch_sources() {
    local dir=$1 info=$2 target=$3 info_ver url md5 file
    info_ver=$(info_var "$info" VERSION)
    while read -r url md5; do
        [ -n "$url" ] || continue
        if [ "$target" != "$info_ver" ]; then
            url=${url//$info_ver/$target}
            md5=
        fi
        file=${url##*/}
        if [ -f "$dir/$file" ]; then
            echo "Source exists:      $file"
        else
            echo "Downloading:        $url"
            if ! wget -q --show-progress -T 30 -t 3 -O "$dir/$file.part" "$url"; then
                rm -f "$dir/$file.part"
                echo "ERROR: download failed. Download it manually into $dir"
                return 1
            fi
            mv "$dir/$file.part" "$dir/$file"
        fi
        if [ -n "$md5" ]; then
            ( cd "$dir" && echo "$md5  $file" | md5sum -c ) || return 1
        else
            echo "No MD5 for $target (.info has $info_ver), not checked"
        fi
    done < <(info_sources "$info")
}

# Map SBo dependency names (stdin, one per line) to local package names
# using sbo/.aliases ("<sbo name> <local name>" per line, # comments),
# e.g. "jack jack2"
sbo_alias() {
    awk -v f="$REPO_DIR/sbo/.aliases" '
        BEGIN { while ((getline l < f) > 0) { sub(/#.*/, "", l); split(l, a, " "); if (a[2] != "") m[a[1]] = a[2] } }
        { print (($1 in m) ? m[$1] : $1) }'
}

# Dir holding <package>.SlackBuild: <tree>/<pkg>/build or <tree>/<pkg>.
# Searches $SBDIR, then (unless $2 is "strict") the other trees.
find_build_dir() {
    local pkg=$1 d t
    local -a dirs=("$SBDIR")
    if [ "$2" != strict ]; then
        for t in $TREES; do
            [ "$REPO_DIR/$t" != "$SBDIR" ] && dirs+=("$REPO_DIR/$t")
        done
    fi
    for d in "${dirs[@]}"; do
        for d in "$d/$pkg/build" "$d/$pkg"; do
            if [ -f "$d/$pkg.SlackBuild" ]; then
                echo "$d"
                return 0
            fi
        done
    done
    return 1
}

# Latest stable version from the source site of a SRCURL template
latest_upstream() {
    local tpl=$1 file pre suf path
    case $tpl in *@VERSION@*) ;; *) return 1 ;; esac
    file=${tpl##*/}
    pre=${file%%@VERSION@*}
    suf=${file#*@VERSION@}
    case $tpl in
        *://github.com/*|*://codeload.github.com/*)
            # Latest published release (no tags: old/odd tags give wrong results)
            fetch "https://api.github.com/repos/$(echo "$tpl" | cut -d/ -f4-5)/releases/latest" \
                | sed -nE 's/.*"tag_name": *"[^0-9"]*([0-9]+(\.[0-9]+)*)".*/\1/p'
            ;;
        *sourceforge.net/*)
            path=${tpl#*sourceforge.net/}
            path=${path#project/}
            fetch "https://sourceforge.net/projects/${path%%/*}/rss?path=/" \
                | extract_versions "$pre" "$suf"
            ;;
        *)
            path=${tpl%/*}
            case $path in *@VERSION@*) return 1 ;; esac
            # Need a file extension after the version, or the match is unreliable
            [ -n "$suf" ] || return 1
            fetch "$path/" | extract_versions "$pre" "$suf"
            ;;
    esac | sort -uV | tail -n1
}

# Fallback: newest version known to repology.org (tracks most distros)
repology_version() {
    fetch "https://repology.org/api/v1/project/$1" \
        | grep -oE '\{[^{}]*\}' | grep -E '"status": *"newest"' \
        | sed -nE 's/.*"version": *"([^"]+)".*/\1/p' \
        | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -uV | tail -n1
}

VISITED=" "
HELD=()       # packages skipped because they are on hold

# Return 0 if package $1 is listed in the hold file
on_hold() {
    [ -f "$HOLD_FILE" ] && sed 's/#.*//' "$HOLD_FILE" | awk '{ print $1 }' | grep -qxF -- "$1"
}
UPDATES=()    # "name: installed -> upstream", for the -a summary
NOSB=()       # installed packages without a downloaded SlackBuild

# Process one package: show info, handle deps (with -d), then build.
# $1 = package, $2 = parent package (empty for the top-level one)
process_pkg() {
    local pkg=$1 parent=$2
    local build_dir sb_file info_file
    local prgnam sb_ver inst_ver latest from target pkgfile dep need_build=1
    local -a deps=()

    case $VISITED in *" $pkg "*) return 0 ;; esac
    VISITED="$VISITED$pkg "

    if { [ -n "$parent" ] || [ $ALL -eq 1 ]; } && on_hold "$pkg"; then
        echo
        echo "== $pkg: on hold ($HOLD_FILE), skipping (installed: $(installed_version "$pkg"))"
        HELD+=("$pkg")
        return 0
    fi

    echo
    if [ -n "$parent" ]; then
        echo "== $pkg (dependency of $parent)"
    else
        echo "== $pkg"
    fi

    # The package itself only from the selected tree, dependencies from any
    if [ -n "$parent" ]; then
        build_dir=$(find_build_dir "$pkg")
    else
        build_dir=$(find_build_dir "$pkg" strict)
    fi
    if [ -z "$build_dir" ]; then
        inst_ver=$(installed_version "$pkg")
        if [ -n "$inst_ver" ]; then
            echo "Installed version:  $inst_ver (no SlackBuild downloaded, skipping)"
            NOSB+=("$pkg")
            return 0
        fi
        echo "ERROR: no $pkg.SlackBuild in $SBDIR/$pkg. Download it first, e.g.:"
        case $TREE in
            alien|sbo) echo "  $SCRIPT_DIR/download-slackbuilds.sh -t $TREE $pkg" ;;
        esac
        return 1
    fi
    sb_file=$build_dir/$pkg.SlackBuild
    info_file=$build_dir/$pkg.info
    [ -f "$info_file" ] || info_file=
    echo "SlackBuild dir:     ${build_dir#"$REPO_DIR"/}"

    prgnam=$(sed -nE 's/^PRGNAM=//p' "$sb_file" | head -n1 | tr -d '"')
    prgnam=${prgnam:-$pkg}
    sb_ver=$(sb_version "$sb_file")
    inst_ver=$(installed_version "$prgnam")

    echo "SlackBuild version: ${sb_ver:-unknown}"
    echo "Installed version:  ${inst_ver:-not installed}"

    target=$sb_ver
    if [ -z "$parent" ] && [ -n "$USER_VER" ]; then
        target=$USER_VER
    elif [ $NEWEST -eq 1 ] || [ $CHECK_ONLY -eq 1 ]; then
        if [ -n "$info_file" ]; then
            latest=$(latest_upstream "$(info_url_template "$info_file")")
        else
            latest=$(latest_upstream "$(srcurl_template "$sb_file")")
        fi
        from="source site"
        if [ -z "$latest" ]; then
            latest=$(repology_version "$prgnam")
            from="repology.org"
        fi
        if [ -n "$latest" ]; then
            echo "Upstream version:   $latest (from $from)"
            if [ -n "$inst_ver" ] && ver_gt "$latest" "$inst_ver"; then
                UPDATES+=("$prgnam: $inst_ver -> $latest")
            fi
        else
            echo "Upstream version:   could not detect automatically"
        fi
        if [ $NEWEST -eq 1 ] && [ -n "$latest" ] && ver_gt "$latest" "$sb_ver"; then
            target=$latest
        fi
    fi

    # -f without -V/-n rebuilds the installed version when it is newer than
    # the SlackBuild default (installed earlier with -V or -n): no downgrade.
    # Only for plain versions (git tags/nightly names differ from the
    # package version, e.g. sq8l v1.0.0-beta.3 -> 1.0.0_beta.3).
    if [ -z "$parent" ] && [ $FORCE -eq 1 ] && [ -z "$USER_VER" ] && [ $NEWEST -eq 0 ] \
        && [[ $inst_ver == [0-9]* ]] && [[ $target == [0-9]* ]] \
        && ver_gt "$inst_ver" "$target"; then
        echo "Installed $inst_ver is newer than the SlackBuild default, rebuilding $inst_ver (-f)."
        target=$inst_ver
    fi

    if [ -z "$target" ]; then
        echo "ERROR: no version to build for $pkg, use -V <version>"
        return 1
    fi
    echo "Version to build:   $target"

    if [ -n "$inst_ver" ] && ! ver_gt "$target" "$inst_ver"; then
        if [ -z "$parent" ] && [ $FORCE -eq 1 ]; then
            echo "Already installed, rebuilding (-f)."
        else
            echo "Installed version is up to date."
            need_build=0
        fi
    fi

    # Dependencies: process them with -d, otherwise just warn
    if [ -f "$build_dir/slack-required" ]; then
        mapfile -t deps < <(awk '!/^#/ && NF { print $1 }' "$build_dir/slack-required")
    elif [ -n "$info_file" ]; then
        # %README% means "see README for optional deps", not a package
        mapfile -t deps < <(info_var "$info_file" REQUIRES | tr -s ' ' '\n' \
            | grep -v -e '^%README%$' -e '^$' | sbo_alias)
    fi
    for dep in "${deps[@]}"; do
        if [ $DEPS -eq 1 ]; then
            process_pkg "$dep" "$pkg" || [ $CHECK_ONLY -eq 1 ] || return 1
        elif [ -z "$(installed_version "$dep")" ]; then
            echo "WARNING: dependency not installed: $dep"
        fi
    done

    [ $need_build -eq 1 ] || return 0
    [ $CHECK_ONLY -eq 1 ] && return 0

    if [ -n "$info_file" ]; then
        fetch_sources "$build_dir" "$info_file" "$target" || return 1
    fi

    echo
    echo "== Building $prgnam $target in $build_dir ..."
    local log=$OUTPUT/build-$prgnam-$target.log
    local stamp
    stamp=$(mktemp)
    # Pass VERSION only when it differs from the SlackBuild default: some
    # SlackBuilds (e.g. git snapshots) behave differently when it is preset
    local -a run_env=()
    [ "$target" != "$sb_ver" ] && run_env=("VERSION=$target")
    if [ $QUIET -eq 1 ]; then
        echo "Build log: $log (follow with: tail -f $log)"
        ( cd "$build_dir" && env "${run_env[@]}" bash "./$pkg.SlackBuild" ) > "$log" 2>&1
    else
        ( cd "$build_dir" && env "${run_env[@]}" bash "./$pkg.SlackBuild" )
    fi

    # Only accept a package created by this build, not one left from earlier
    pkgfile=$(find "$OUTPUT" -maxdepth 1 -name "$prgnam-$target-*.t?z" -newer "$stamp" | head -n1)
    rm -f "$stamp"
    if [ -z "$pkgfile" ]; then
        if [ $QUIET -eq 1 ]; then
            echo "---- last 30 lines of $log ----"
            tail -n 30 "$log"
            echo "----"
        fi
        echo "ERROR: build failed, no new $prgnam-$target package in $OUTPUT"
        return 1
    fi
    echo "Package created: $pkgfile"

    # Dependencies are always installed (needed to build the parent)
    # -f: --reinstall, or upgradepkg skips a package of the same version
    local -a upg=(--install-new)
    [ -z "$parent" ] && [ $FORCE -eq 1 ] && upg+=(--reinstall)
    if [ -n "$parent" ] || [ $INSTALL -eq 1 ]; then
        upgradepkg "${upg[@]}" "$pkgfile" || return 1
    else
        echo "Install with: upgradepkg --install-new $pkgfile"
    fi
}

if [ $ALL -eq 0 ]; then
    process_pkg "$1" ""
    exit
fi

# -a: every installed package whose build field ends with the tag (e.g. 1alien).
# Names are what is left after stripping the version, arch and build fields.
FAILED=()
for p in $(ls "$PKGDB" | grep -E -- "-[0-9]+$(re_escape "$PKGTAG")\$" | rev | cut -d- -f4- | rev); do
    process_pkg "$p" "" || FAILED+=("$p")
done

echo
echo "== Summary"
if [ $NEWEST -eq 1 ] || [ $CHECK_ONLY -eq 1 ]; then
    if [ ${#UPDATES[@]} -gt 0 ]; then
        echo "Newer upstream versions:"
        printf '  %s\n' "${UPDATES[@]}"
    else
        echo "No newer upstream versions found."
    fi
fi
if [ ${#NOSB[@]} -gt 0 ]; then
    echo "Skipped, no SlackBuild downloaded: ${NOSB[*]}"
fi
if [ ${#HELD[@]} -gt 0 ]; then
    echo "Skipped, on hold: ${HELD[*]}"
fi
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "Failed: ${FAILED[*]}"
    exit 1
fi
