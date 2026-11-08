#!/usr/bin/env bash
#
# Install the newest Slackware-current kernel-generic next to the installed
# ones, and print recommended custom GRUB entries for all installed kernels.
# The newest kernel's entry uses the unversioned symlinks (/boot/vmlinuz,
# /boot/initrd.gz) kept up to date by the kernel package; older kernels get
# versioned entries.
#
# Follows slackware-notes: docs/README-slackware-current-kernel-update.md
# (kernel-generic stays blacklisted in slackpkg; installpkg, never upgradepkg).
#
# Usage: kernel-update.sh [-c]
#   (no option)  check the mirror, download, verify (md5 + gpg) and install a
#                newer kernel-generic after confirmation, then print GRUB entries
#   -c           check only: list installed kernels, compare with the mirror,
#                print GRUB entries (no root needed, nothing is changed)
#
# Planned: -d to removepkg kernels older than the "previous" one. For now the
# script only prints the removepkg commands.
#
# Environment overrides:
#   MIRROR   slackware64-current mirror (default below)
#   KDIR     download directory (default /root/kernel-current)
#   ROOTDEV  root device for GRUB entries (default: device mounted on /)
#   BOOT, PKGDB, MODDIR  for testing (default /boot, /var/lib/pkgtools/packages,
#            /lib/modules)

MIRROR=${MIRROR:-https://mirrors.slackware.com/slackware/slackware64-current}
KDIR=${KDIR:-/root/kernel-current}
BOOT=${BOOT:-/boot}
PKGDB=${PKGDB:-/var/lib/pkgtools/packages}
MODDIR=${MODDIR:-/lib/modules}
PKGNAME=kernel-generic

usage() {
    cat <<EOF2
Usage: $0 [-c]
  (no option)  download, verify and install a newer $PKGNAME from the mirror
               (asks before downloading and before installpkg), then print
               recommended GRUB entries
  -c           check only: list installed kernels, compare with the mirror,
               print recommended GRUB entries (no root needed)
Mirror: $MIRROR
EOF2
    exit "${1:-0}"
}

CHECK_ONLY=0
while getopts "ch" opt; do
    case $opt in
        c) CHECK_ONLY=1 ;;
        h) usage 0 ;;
        *) usage 1 ;;
    esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage 1

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

ask() {
    local a
    read -r -p "$1 [y/N] " a < /dev/tty
    [ "$a" = y ] || [ "$a" = Y ]
}

# Returns 0 if version $1 sorts after version $2
newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Installed kernel-generic packages, one "version fullname" per line, oldest first
installed_kernels() {
    local f pkg rest
    for f in "$PKGDB/$PKGNAME"-*; do
        [ -f "$f" ] || continue
        pkg=${f##*/}
        rest=${pkg%-*}          # strip build
        rest=${rest%-*}         # strip arch
        [ "${rest%-*}" = "$PKGNAME" ] || continue
        echo "${rest##*-} $pkg"
    done | sort -V
}

# Kernel image of version $1 (15.0 kernels use vmlinuz-generic-VER)
kernel_file() {
    local f
    for f in vmlinuz-$1 vmlinuz-generic-$1; do
        [ -f "$BOOT/$f" ] && [ ! -L "$BOOT/$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

# Initrd of version $1 (-current: initrd-VER.img, older: .gz names)
initrd_file() {
    local f
    for f in initrd-$1.img initrd-$1.gz initrd-generic-$1.img initrd-generic-$1.gz; do
        [ -f "$BOOT/$f" ] && [ ! -L "$BOOT/$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

# Modules version inside an initrd, empty if unreadable
initrd_modules() {
    zcat "$1" 2>/dev/null | cpio -t 2>/dev/null | grep -m1 -o 'lib/modules/[^/]*' |
        sed 's|lib/modules/||'
}

# Newest kernel-generic on the mirror: sets AVAIL_PKG, AVAIL_VER, AVAIL_MD5
mirror_newest() {
    local tmp line
    tmp=$(mktemp) || return 1
    if ! wget -q -O "$tmp" "$MIRROR/CHECKSUMS.md5"; then
        rm -f "$tmp"
        return 1
    fi
    # lines: <md5>  ./slackware64/a/kernel-generic-VER-x86_64-BUILD.txz
    line=$(grep -E "/slackware64/a/$PKGNAME-[^/-]+-x86_64-[0-9]+\.txz\$" "$tmp" |
           awk '{ n = $2; sub(/.*\//, "", n); print n, $1 }' | sort -V | tail -n1)
    rm -f "$tmp"
    [ -n "$line" ] || return 1
    AVAIL_PKG=${line% *}
    AVAIL_MD5=${line#* }
    AVAIL_VER=${AVAIL_PKG#$PKGNAME-}
    AVAIL_VER=${AVAIL_VER%%-*}
}

list_kernels() {
    local running latest_k latest_i ver pkg k i mods
    running=$(uname -r)
    latest_k=$(readlink "$BOOT/vmlinuz" 2>/dev/null)
    latest_i=$(readlink "$BOOT/initrd.gz" 2>/dev/null)
    echo "Installed $PKGNAME packages (running: $running):"
    printf '  %-12s %-26s %-26s %-8s %s\n' VERSION KERNEL INITRD MODULES NOTES
    while read -r ver pkg; do
        k=$(kernel_file "$ver") || k="MISSING"
        i=$(initrd_file "$ver") || i="MISSING"
        if [ -d "$MODDIR/$ver" ]; then mods=ok; else mods=MISSING; fi
        notes=""
        [ "$ver" = "$running" ] && notes="$notes running"
        [ -n "$latest_k" ] && [ "$latest_k" = "$k" ] && notes="$notes vmlinuz"
        [ -n "$latest_i" ] && [ "$latest_i" = "$i" ] && notes="$notes initrd.gz"
        printf '  %-12s %-26s %-26s %-8s %s\n' "$ver" "$k" "$i" "$mods" "${notes# }"
    done <<< "$KERNELS"
    echo "  $BOOT/vmlinuz -> ${latest_k:-NOT A SYMLINK}"
    echo "  $BOOT/initrd.gz -> ${latest_i:-NOT A SYMLINK}"
}

# Checks that the symlinks and the initrd belong to version $1
check_latest() {
    local ver=$1 k i mods ok=0
    k=$(kernel_file "$ver") || { warn "no kernel image for $ver in $BOOT"; ok=1; }
    i=$(initrd_file "$ver") || { warn "no initrd for $ver in $BOOT"; ok=1; }
    [ -d "$MODDIR/$ver" ] || { warn "$MODDIR/$ver is missing"; ok=1; }
    if [ -n "$k" ] && [ "$(readlink "$BOOT/vmlinuz")" != "$k" ]; then
        warn "$BOOT/vmlinuz does not point to $k"; ok=1
    fi
    if [ -n "$i" ]; then
        [ "$(readlink "$BOOT/initrd.gz")" = "$i" ] ||
            { warn "$BOOT/initrd.gz does not point to $i"; ok=1; }
        if [ -r "$BOOT/$i" ]; then
            mods=$(initrd_modules "$BOOT/$i")
            [ "$mods" = "$ver" ] ||
                { warn "$i contains lib/modules/${mods:-?}, expected $ver"; ok=1; }
        else
            echo "Note: cannot read $BOOT/$i (not root), initrd content not checked"
        fi
    fi
    if [ $ok -ne 0 ]; then
        echo "To rebuild the initrd for $ver (as root):"
        echo "  mkinitrd -c -k $ver -f $FSTYPE -r $ROOTDEV -u -o $BOOT/initrd-$ver.img"
        echo "  (or see: /usr/share/mkinitrd/mkinitrd_command_generator.sh -k $ver -r)"
    fi
    return $ok
}

grub_entry() {
    local title=$1 kernel=$2 initrd=$3
    echo "menuentry \"$title\" {"
    echo "    insmod part_gpt"
    echo "    insmod $GRUB_FSMOD"
    echo "    $GRUB_SEARCH"
    echo "    linux /boot/$kernel root=$GRUB_ROOT ro"
    echo "    initrd ${UCODE}/boot/$initrd"
    echo "}"
    echo
}

print_grub() {
    local newest ver pkg k i n=0
    newest=$(tail -n1 <<< "$KERNELS" | cut -d' ' -f1)
    echo
    echo "Recommended custom GRUB entries (Fedora: /etc/grub.d/40_custom,"
    echo "then grub2-mkconfig -o /boot/grub2/grub.cfg):"
    echo "----------------------------------------------------------------"
    grub_entry "Slackware -current" vmlinuz initrd.gz
    while read -r ver pkg; do
        [ "$ver" = "$newest" ] && continue
        k=$(kernel_file "$ver") || { warn "skipping $ver: no kernel image"; continue; }
        i=$(initrd_file "$ver") || { warn "skipping $ver: no initrd"; continue; }
        n=$((n + 1))
        if [ $n -eq 1 ]; then
            grub_entry "Slackware -current ($ver previous)" "$k" "$i"
        else
            grub_entry "Slackware -current ($ver)" "$k" "$i"
        fi
    done < <(sort -rV <<< "$KERNELS")
    echo "----------------------------------------------------------------"
    echo "\"Slackware -current\" follows $BOOT/vmlinuz and $BOOT/initrd.gz ($newest)."
    echo "Other entries (NetBSD etc.) are not generated; keep them as they are."
}

print_removable() {
    local count ver pkg
    count=$(wc -l <<< "$KERNELS")
    [ "$count" -gt 2 ] || return 0
    echo
    echo "More than two kernels installed. Once the newest one boots fine, the"
    echo "older ones can be removed (as root, then drop their GRUB entries):"
    head -n $((count - 2)) <<< "$KERNELS" | while read -r ver pkg; do
        echo "  removepkg $pkg"
    done
}

# --- main ---

[ -d "$PKGDB" ] || die "cannot find $PKGDB"
KERNELS=$(installed_kernels)
[ -n "$KERNELS" ] || die "no $PKGNAME package installed"
NEWEST=$(tail -n1 <<< "$KERNELS" | cut -d' ' -f1)

# Root filesystem for GRUB entries: label search if there is a label, else UUID
ROOTDEV=${ROOTDEV:-$(findmnt -n -o SOURCE /)}
FSTYPE=$(lsblk -n -o FSTYPE "$ROOTDEV" 2>/dev/null)
LABEL=$(lsblk -n -o LABEL "$ROOTDEV" 2>/dev/null)
UUID=$(lsblk -n -o UUID "$ROOTDEV" 2>/dev/null)
case $FSTYPE in
    ext*) GRUB_FSMOD=ext2 ;;
    "")   GRUB_FSMOD=ext2; FSTYPE=ext4; warn "cannot detect fs type of $ROOTDEV, assuming ext4" ;;
    *)    GRUB_FSMOD=$FSTYPE ;;
esac
GRUB_ROOT=$ROOTDEV
if [ -n "$LABEL" ]; then
    GRUB_SEARCH="search --no-floppy --label --set=root $LABEL"
elif [ -n "$UUID" ]; then
    GRUB_SEARCH="search --no-floppy --fs-uuid --set=root $UUID"
    GRUB_ROOT="UUID=$UUID"
else
    GRUB_SEARCH="search --no-floppy --label --set=root CHANGE-ME"
    warn "no label or UUID found for $ROOTDEV, fix the search line"
fi
UCODE=""
for f in intel-ucode.img amd-ucode.img; do
    [ -f "$BOOT/$f" ] && UCODE="$UCODE/boot/$f "
done

list_kernels
echo

AVAIL_VER=""
if mirror_newest; then
    echo "Newest on mirror: $AVAIL_PKG"
else
    warn "could not read $PKGNAME list from $MIRROR/CHECKSUMS.md5"
fi

if [ $CHECK_ONLY -eq 1 ] || [ -z "$AVAIL_VER" ] || ! newer "$AVAIL_VER" "$NEWEST"; then
    if [ -n "$AVAIL_VER" ]; then
        if newer "$AVAIL_VER" "$NEWEST"; then
            echo "NEW KERNEL AVAILABLE: $AVAIL_VER (installed newest: $NEWEST)"
        else
            echo "Up to date (installed newest: $NEWEST)"
        fi
    fi
    echo
    echo "Checking the newest installed kernel ($NEWEST):"
    check_latest "$NEWEST" && echo "OK: symlinks, initrd and modules match $NEWEST"
    print_grub
    print_removable
    exit 0
fi

# --- update ---

[ "$(id -u)" -eq 0 ] || die "installing needs root: su -c '$0'"
echo "NEW KERNEL AVAILABLE: $AVAIL_VER (installed newest: $NEWEST)"
if [ "$(uname -r)" != "$NEWEST" ]; then
    warn "running $(uname -r), not the newest installed $NEWEST (not tested yet?)"
fi
ask "Download $AVAIL_PKG to $KDIR?" || exit 0

mkdir -p "$KDIR" || die "cannot create $KDIR"
cd "$KDIR" || die "cannot cd to $KDIR"
for f in "$AVAIL_PKG" "$AVAIL_PKG.asc"; do
    if [ -s "$f" ]; then
        echo "Using existing $KDIR/$f"
    else
        wget -O "$f" "$MIRROR/slackware64/a/$f" || { rm -f "$f"; die "download of $f failed"; }
    fi
done

echo "Checking md5..."
[ "$(md5sum < "$AVAIL_PKG" | cut -d' ' -f1)" = "$AVAIL_MD5" ] ||
    die "md5 mismatch for $KDIR/$AVAIL_PKG (delete it and run again)"
echo "Checking gpg signature..."
if ! gpg --verify "$AVAIL_PKG.asc" "$AVAIL_PKG"; then
    echo "If the key is missing, import it once:"
    echo "  wget $MIRROR/GPG-KEY && gpg --import GPG-KEY"
    die "gpg verification failed for $AVAIL_PKG"
fi
echo "Signature OK (the \"not certified with a trusted signature\" warning is normal)."
echo

ask "Install $AVAIL_PKG with installpkg (keeps the installed kernels)?" || exit 0
installpkg "$KDIR/$AVAIL_PKG" || die "installpkg failed"

KERNELS=$(installed_kernels)
NEWEST=$(tail -n1 <<< "$KERNELS" | cut -d' ' -f1)
[ "$NEWEST" = "$AVAIL_VER" ] || warn "newest installed is $NEWEST, expected $AVAIL_VER"
echo
list_kernels
echo
echo "Checking the new kernel ($NEWEST):"
check_latest "$NEWEST" && echo "OK: symlinks, initrd and modules match $NEWEST"
print_grub
echo
echo "Next: update the GRUB entries above, reboot into \"Slackware -current\","
echo "check uname -r ($NEWEST) and dmesg --level=err,warn."
print_removable
