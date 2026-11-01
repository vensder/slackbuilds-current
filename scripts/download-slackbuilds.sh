#!/usr/bin/env bash
#
# Download a SlackBuild and, recursively, its dependencies into this repo:
#   -t alien (default): from Alien Bob's repository into alien/<package>/build/
#                       (dependencies from slack-required)
#   -t sbo:             from SlackBuilds.org into sbo/<package>/
#                       (dependencies from REQUIRES in <package>.info)
# Source archives are not downloaded (build-slackbuild.sh handles that).
#
# Usage: download-slackbuilds.sh [-t alien|sbo] <package|link>

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
REPO_DIR=$(dirname "$SCRIPT_DIR")
PKGDB=${PKGDB:-/var/lib/pkgtools/packages}
ALIEN_URL=${ALIEN_URL:-http://www.slackware.com/~alien/slackbuilds}
SBO_VER=${SBO_VER:-15.0}
SBO_URL=${SBO_URL:-https://slackbuilds.org/slackbuilds/$SBO_VER}

# slackware.com delays requests with the default wget user agent by ~8-10s;
# an honest, descriptive one is not delayed
USER_AGENT="download-slackbuilds.sh (Slackware user)"

usage() {
    cat <<EOF
Usage: $0 [-t alien|sbo] <package|link>
  -t alien  (default) <package> or link to its build/ dir, e.g.
            $0 amsynth
            $0 $ALIEN_URL/amsynth/build/
  -t sbo    <package>, <category>/<package> or SBo page link, e.g.
            $0 -t sbo yoshimi
            $0 -t sbo audio/yoshimi
            (SBo $SBO_VER, override with SBO_VER=...; an existing
            sbo/<package> dir is kept, remove it to download again)
SlackBuilds dir: $REPO_DIR/<tree> (override with SBDIR=...)
EOF
    exit 1
}

TREE=alien
while getopts "t:h" opt; do
    case $opt in
        t) TREE=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage
case $TREE in
    alien|sbo) ;;
    vensder) echo "ERROR: vensder/ holds own SlackBuilds, nothing to download"; exit 1 ;;
    *) echo "ERROR: unknown tree '$TREE' (use alien or sbo)"; exit 1 ;;
esac
SBDIR=${SBDIR:-$REPO_DIR/$TREE}

# Return 0 if package $1 is installed
is_installed() {
    ls "$PKGDB" 2>/dev/null | grep -qE "^$(printf '%s' "$1" | sed 's/[][\.*^$()+?{}|/]/\\&/g')-[^-]+-[^-]+-[^-]+$"
}

# ---- Alien ----

download_alien() {
    local LINK=$1 PACKAGE_NAME BASE_LINK BUILD_PATH DEPENDENCY_FILE line
    echo "Build to download: $LINK"

    # --cut-dirs=2 drops "~alien/slackbuilds", so files land in $SBDIR/<package>/build/
    # --reject-regex skips Apache's column-sort links (?C=N;O=D etc.), which
    # wget would otherwise download (8 extra requests per directory).
    # Source archives are skipped: the SlackBuild downloads the version it
    # builds from SRCURL. Compressed patches (*.diff.gz etc.) are still fetched.
    wget -r -N -np -nH --cut-dirs=2 -U "$USER_AGENT" -P "$SBDIR" \
        -R "index.html*,*.tar.*,*.tgz,*.tbz,*.tbz2,*.txz,*.zip,*.7z" \
        --reject-regex '\?C=' "$LINK"

    echo "Downloaded build: $LINK"

    PACKAGE_NAME=$(echo "$LINK" | awk -F '/' '{ print $(NF-2) }')
    echo "Package name: $PACKAGE_NAME"

    BASE_LINK=$(echo "$LINK" | awk -F "/$PACKAGE_NAME" '{ print $1 }')
    echo "Base link: $BASE_LINK"

    BUILD_PATH="$SBDIR/$PACKAGE_NAME/build"
    echo "Build path: $BUILD_PATH"

    DEPENDENCY_FILE="$BUILD_PATH/slack-required"

    if [[ -f "$DEPENDENCY_FILE" ]]; then
        echo "Dependency file: $DEPENDENCY_FILE exists. Dependencies:"
        cat "$DEPENDENCY_FILE"

        # First word of each line (lines may look like "pkg >= 1.0")
        while read -r line _; do
            if [ -n "$line" ]; then
                echo "Processing: $line"
                download_alien "$BASE_LINK/$line/build/"
            fi
        done < "$DEPENDENCY_FILE"

    else
        echo "No dependencies file for $PACKAGE_NAME"
    fi
}

# ---- SBo ----

SBO_LIST=
VISITED=" "
TMPDIR_DL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_DL"' EXIT

# <category>/<name> of SBo package $1, from SLACKBUILDS.TXT (fetched once)
sbo_location() {
    if [ -z "$SBO_LIST" ]; then
        SBO_LIST=$TMPDIR_DL/SLACKBUILDS.TXT
        if ! wget -q -T 30 -t 3 -O "$SBO_LIST" "$SBO_URL/SLACKBUILDS.TXT"; then
            echo "ERROR: cannot download $SBO_URL/SLACKBUILDS.TXT" >&2
            return 1
        fi
    fi
    awk -v n="$1" '
        $0 == "SLACKBUILD NAME: " n { found = 1; next }
        found && /^SLACKBUILD LOCATION: / { sub(/^SLACKBUILD LOCATION: \.\//, ""); print; exit }' "$SBO_LIST"
}

# $1 = <name> or <category>/<name>, $2 = parent package (empty for top level)
download_sbo() {
    local arg=$1 parent=$2 name loc t dep found
    name=${arg##*/}
    case $VISITED in *" $name "*) return 0 ;; esac
    VISITED="$VISITED$name "

    echo
    if [ -n "$parent" ]; then
        echo "== $name (dependency of $parent)"
        if is_installed "$name"; then
            echo "Installed, skipping"
            return 0
        fi
        found=
        for t in vensder alien; do
            [ -f "$REPO_DIR/$t/$name/build/$name.SlackBuild" ] && found=$t
        done
        if [ -n "$found" ]; then
            echo "Found in $found/, skipping"
            return 0
        fi
    else
        echo "== $name"
    fi

    if [ -d "$SBDIR/$name" ]; then
        echo "$SBDIR/$name exists, keeping it (remove it to download again)"
    else
        case $arg in
            */*) loc=$arg ;;
            *)   loc=$(sbo_location "$name") || return 1 ;;
        esac
        if [ -z "$loc" ]; then
            echo "ERROR: $name not found in SBo $SBO_VER"
            return 1
        fi
        echo "Downloading: $SBO_URL/$loc.tar.gz"
        mkdir -p "$SBDIR"
        if ! wget -q -T 30 -t 3 -O "$TMPDIR_DL/$name.tar.gz" "$SBO_URL/$loc.tar.gz" \
            || ! tar xzf "$TMPDIR_DL/$name.tar.gz" -C "$SBDIR"; then
            echo "ERROR: download of $SBO_URL/$loc.tar.gz failed"
            return 1
        fi
        echo "Downloaded to: $SBDIR/$name"
    fi

    if [ ! -f "$SBDIR/$name/$name.info" ]; then
        echo "No $name.info, dependencies unknown"
        return 0
    fi
    # %README% means "see README for optional deps", not a package
    for dep in $(. "$SBDIR/$name/$name.info" 2>/dev/null; echo "$REQUIRES"); do
        [ "$dep" = "%README%" ] && continue
        download_sbo "$dep" "$name" || return 1
    done
}

if [ "$TREE" = alien ]; then
    case $1 in
        *://*) LINK=$1 ;;
        *)     LINK=$ALIEN_URL/$1/build/ ;;
    esac
    download_alien "$LINK"
else
    ARG=$1
    case $ARG in
        # SBo page link: .../repository/15.0/<category>/<name>/
        *://*) ARG=${ARG%/}; ARG=$(echo "$ARG" | awk -F/ '{ print $(NF-1) "/" $NF }') ;;
    esac
    download_sbo "$ARG" ""
fi
