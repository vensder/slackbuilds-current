#!/usr/bin/env bash
#
# List installed official Slackware packages that a desktop usually does not
# need (servers and the like, left over from a full install), check whether
# something still uses them, and remove them with removepkg on request.
# Slackware has no dependency tracking, so for each candidate it checks:
#   SERVICE  one of its /etc/rc.d/rc.* scripts is executable (started at boot)
#   RUNNING  one of its programs is running now
#   LIBRARY  a shared library from it is linked (NEEDED) by a program or
#            library of another package, or of no package (/opt, /usr/local)
#   REPO     a SlackBuild in this repo lists it as a dependency
#   NOTE     what you lose besides the server (informational only)
# A candidate with any finding except NOTE is never removed by -y.
# Not detected: libraries loaded with dlopen(), programs run by scripts.
# Default: dry run, nothing is changed. Removing needs -y and root.
#
# Usage: check-unneeded.sh [-y] [name...]
#   -y    remove the candidates without findings (as root:
#         su -c 'scripts/check-unneeded.sh -y httpd php')
#   name  only these packages (default: the built-in list below without
#         KEEP); any installed package name works, e.g. kernel-source
#
# Environment overrides: KEEP (candidates never checked unless named,
# default below; KEEP= checks all), PKGDB, SCAN_DIRS (where linking programs
# are searched), BLACKLIST (default /etc/slackpkg/blacklist)

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
REPO_DIR=$(dirname "$SCRIPT_DIR")
PKGDB=${PKGDB:-/var/lib/pkgtools/packages}
SCAN_DIRS=${SCAN_DIRS:-"/bin /sbin /lib /lib64 /usr/bin /usr/sbin /usr/lib /usr/lib64 /usr/libexec /usr/local /opt"}
BLACKLIST=${BLACKLIST:-/etc/slackpkg/blacklist}
# Kept on purpose: dig/host (bind), local mail for cron (postfix), Akonadi
# (mariadb), Windows shares (samba), NFS, hotspot (dnsmasq), libraries
# used by hplip/sane (net-snmp), building lsp-plugins (php)
KEEP=${KEEP-"bind postfix mariadb samba nfs-utils rpcbind dnsmasq inetd net-snmp dhcp php"}

# Candidates: name|description (NOTE lines start with "!")
CANDIDATES='
httpd|Apache web server
php|PHP (mod_php for httpd, php-fpm, php CLI)
!php|lsp-plugins needs the php CLI to build
bind|DNS server (named)
!bind|also provides dig, host, nslookup and nsupdate; keep bind if you use them
sendmail|mail server (MTA)
sendmail-cf|sendmail configuration files
postfix|mail server (MTA)
!sendmail|without an MTA cron and mail(1) cannot deliver local mail
!postfix|without an MTA cron and mail(1) cannot deliver local mail
dovecot|IMAP/POP3 server
imapd|UW IMAP/POP3 server
mariadb|MySQL server
!mariadb|KDE Akonadi (KMail, KOrganizer, Kontact) runs its own mysqld from it
nodejs|JavaScript runtime
!nodejs|some build systems and editor language servers need node
samba|SMB/CIFS file server
!samba|also provides smbclient and libsmbclient (smb:// in Dolphin, VLC, mpv)
nfs-utils|NFS server and client
!nfs-utils|needed to mount NFS shares
rpcbind|RPC portmapper (for NFS)
vsftpd|FTP server
proftpd|FTP server
dnsmasq|DNS/DHCP server
!dnsmasq|NetworkManager uses it for connection sharing (hotspot)
tftp-hpa|TFTP server and client
inetd|Internet super-server
yptools|NIS client and server
net-snmp|SNMP agent and tools
dhcp|ISC DHCP server and client (dhcpd, dhclient)
kea|ISC Kea DHCP server
netatalk|AFP file server (for old Macs)
ulogd|netfilter (iptables/nftables) logging daemon
nut|UPS monitoring (Network UPS Tools)
!nut|keep it if a UPS is connected to this machine
qemu|QEMU emulator and virtual machines
!qemu|virt-manager, libvirt and GNOME Boxes run it; also provides qemu-img
'

usage() {
    sed -n '/^# Usage:/,/^# Environment/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 1
}

REMOVE=0
while getopts "yh" opt; do
    case $opt in
        y) REMOVE=1 ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [ $REMOVE -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: removing packages requires root, e.g.:"
    echo "  su -c '$0 -y $*'"
    exit 1
fi
if [ ! -d "$PKGDB" ]; then
    echo "Cannot find $PKGDB" >&2
    exit 1
fi
for cmd in readelf; do
    if ! command -v $cmd >/dev/null; then
        echo "ERROR: $cmd not found" >&2
        exit 1
    fi
done

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# Package name: strip version, arch and build fields
pkg_name() {
    echo "${1%-*-*-*}"
}

# Installed package (name-ver-arch-build) for a name, empty if none
installed_pkg() {
    local f
    for f in "$PKGDB/$1"-*-*-*; do
        [ -f "$f" ] || continue
        [ "$(pkg_name "${f##*/}")" = "$1" ] && { echo "${f##*/}"; return; }
    done
}

# Files of a package (no leading "/", no directories)
pkg_files() {
    sed -n '/^FILE LIST:/,$p' "$PKGDB/$1" | sed 1d | grep -v '/$'
}

desc_of() {
    printf '%s\n' "$CANDIDATES" | awk -F'|' -v n="$1" '$1 == n { print $2; exit }'
}

notes_of() {
    printf '%s\n' "$CANDIDATES" | awk -F'|' -v n="!$1" '$1 == n { print $2 }'
}

# Names to check
if [ $# -gt 0 ]; then
    NAMES=("$@")
else
    mapfile -t NAMES < <(printf '%s\n' "$CANDIDATES" \
        | awk -F'|' -v keep=" $KEEP " '$1 != "" && $1 !~ /^!/ && index(keep, " " $1 " ") == 0 { print $1 }')
    [ -n "$KEEP" ] && echo "Kept (KEEP, not checked): $KEEP"
fi

PKGS=()
for name in "${NAMES[@]}"; do
    pkg=$(installed_pkg "$name")
    if [ -n "$pkg" ]; then
        PKGS+=("$pkg")
    elif [ $# -gt 0 ]; then
        echo "Not installed: $name"
    fi
done
if [ ${#PKGS[@]} -eq 0 ]; then
    echo "None of the candidates is installed."
    exit 0
fi

# Shared libraries of the candidates (SONAME, or file name without one):
#   $TMP/libs  soname<TAB>pkg
for pkg in "${PKGS[@]}"; do
    pkg_files "$pkg" | grep -E '^(lib|lib64|usr/lib|usr/lib64)/.*\.so(\.|$)' \
        | while IFS= read -r f; do
              [ -f "/$f" ] || continue
              so=$(readelf -d "/$f" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\]$/\1/p')
              [ -n "$so" ] || so=${f##*/}
              printf '%s\t%s\n' "$so" "$pkg"
          done
done | sort -u > "$TMP/libs"

# Programs and libraries that link one of them: $TMP/users  soname<TAB>/path
touch "$TMP/users" "$TMP/owners"
if [ -s "$TMP/libs" ]; then
    echo "Searching for programs that link $(wc -l < "$TMP/libs") library(s) ..." >&2
    # shellcheck disable=SC2086
    find $SCAN_DIRS -xdev -type f \( -name '*.so*' -o -perm /111 \) -print0 2>/dev/null \
        | xargs -0 -r readelf -d /dev/null 2>/dev/null \
        | awk -F'\t' 'FNR == NR { lib[$1] = 1; next }
                      /^File: / { f = substr($0, 7); next }
                      /\(NEEDED\)/ { s = $0; sub(/.*\[/, "", s); sub(/\]$/, "", s)
                                     if (s in lib) print s "\t" f }' \
              "$TMP/libs" - | sort -u > "$TMP/users"
    # Owner package of each user path (file lists have no leading "/")
    if [ -s "$TMP/users" ]; then
        cut -f2 "$TMP/users" | sed 's|^/||' | sort -u > "$TMP/paths"
        awk 'FNR == NR { need[$0] = 1; next }
             FNR == 1 { p = FILENAME; sub(/.*\//, "", p); inlist = 0 }
             /^FILE LIST:/ { inlist = 1; next }
             inlist && ($0 in need) { print "/" $0 "\t" p }' \
            "$TMP/paths" "$PKGDB"/* > "$TMP/owners"
    fi
fi

# Running programs (comm is cut to 15 characters)
ps -eo comm= 2>/dev/null | sort -u > "$TMP/running"

# Dependency lists of the SlackBuilds in this repo
repo_users() {
    local f
    for f in "$REPO_DIR"/{alien,vensder}/*/build/slack-required \
             "$REPO_DIR"/{alien,vensder}/*/slack-required; do
        [ -f "$f" ] || continue
        awk '{ print $1 }' "$f" | grep -qxF -- "$1" && echo "${f#"$REPO_DIR"/}"
    done
    for f in "$REPO_DIR"/sbo/*/*.info; do
        [ -f "$f" ] || continue
        sed -n 's/^REQUIRES="\(.*\)"/\1/p' "$f" | tr ' ' '\n' | grep -qxF -- "$1" \
            && echo "${f#"$REPO_DIR"/} REQUIRES"
    done
}

SAFE=()
CHECK=()
for pkg in "${PKGS[@]}"; do
    name=$(pkg_name "$pkg")
    size=$(sed -n 's/^UNCOMPRESSED PACKAGE SIZE: *//p' "$PKGDB/$pkg")
    desc=$(desc_of "$name")
    out=
    reasons=

    # SERVICE: rc scripts (installed as rc.x.new, then renamed)
    while IFS= read -r rc; do
        rc=/${rc%.new}
        if [ -x "$rc" ]; then
            out+="  SERVICE  $rc is executable (started at boot)"$'\n'
            reasons+=" service"
        fi
    done < <(pkg_files "$pkg" | grep -E '^etc/rc\.d/rc\.[^/]+$' | sort -u)

    # RUNNING: programs of this package
    while IFS= read -r prog; do
        out+="  RUNNING  $prog"$'\n'
        reasons+=" running"
    done < <(pkg_files "$pkg" \
                 | grep -E '^(bin|sbin|usr/bin|usr/sbin|usr/libexec)/[^/]+$' \
                 | sed 's|.*/||' | cut -c1-15 | sort -u \
                 | grep -xF -f "$TMP/running")

    # LIBRARY: users outside this package
    lib=$(awk -F'\t' -v p="$pkg" '
              FILENAME == ARGV[1] { if ($2 == p) mine[$1] = 1; next }
              FILENAME == ARGV[2] { own[$1] = $2; next }
              ($1 in mine) { o = ($2 in own) ? own[$2] : "no package"
                             if (o != p && !seen[$1 FS o]++)
                                 print "  LIBRARY  " $1 " used by " o " (" $2 ")" }' \
              "$TMP/libs" "$TMP/owners" "$TMP/users")
    if [ -n "$lib" ]; then
        out+=$lib$'\n'
        reasons+=" library"
    fi

    # REPO: build dependency of a SlackBuild here
    while IFS= read -r f; do
        out+="  REPO     listed in $f"$'\n'
        reasons+=" repo"
    done < <(repo_users "$name")

    while IFS= read -r note; do
        [ -n "$note" ] && out+="  NOTE     $note"$'\n'
    done < <(notes_of "$name")

    echo
    printf '%-40s %6s  %s\n' "$pkg" "$size" "$desc"
    if [ -n "$reasons" ]; then
        printf '%s' "$out"
        reasons=$(printf '%s\n' $reasons | sort -u | tr '\n' ' ')
        CHECK+=("$name (${reasons% })")
    else
        printf '%s' "$out"
        echo "  OK       nothing found that uses it"
        SAFE+=("$name")
    fi
done

echo
if [ ${#CHECK[@]} -gt 0 ]; then
    echo "Check first, not removed by -y:"
    printf '  %s\n' "${CHECK[@]}"
    echo "  (disable a service: chmod -x /etc/rc.d/rc.NAME and stop it; or"
    echo "  remove by hand: su -c 'removepkg NAME')"
fi
if [ ${#SAFE[@]} -eq 0 ]; then
    echo "Nothing to remove without checking first."
    exit 0
fi
echo "No findings: ${SAFE[*]}"

# Removed names not yet in the slackpkg blacklist
blacklist_hint() {
    local n missing=()
    for n in "$@"; do
        grep -qxF -- "$n" "$BLACKLIST" 2>/dev/null || missing+=("$n")
    done
    [ ${#missing[@]} -gt 0 ] || return 0
    echo
    echo "Keep 'slackpkg install-new' from installing them again:"
    echo "  su -c 'printf \"%s\\n\" ${missing[*]} >> $BLACKLIST'"
}

echo
if [ $REMOVE -eq 0 ]; then
    echo "Dry run, nothing removed. Drop the names you want to keep, then:"
    echo "  su -c '$0 -y ${SAFE[*]}'"
    blacklist_hint "${SAFE[@]}"
    exit 0
fi

REMOVED=()
for name in "${SAFE[@]}"; do
    echo "== removepkg $name"
    if removepkg "$name"; then
        REMOVED+=("$name")
    else
        echo "ERROR: removepkg $name failed"
    fi
done
echo
echo "Removed: ${REMOVED[*]:-none}"
[ ${#REMOVED[@]} -gt 0 ] && blacklist_hint "${REMOVED[@]}"
exit 0
