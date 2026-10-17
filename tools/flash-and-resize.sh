#!/bin/sh
# Write an OpenWrt x86 image to the internal disk and grow its root partition
# to fill the disk - safely, from a LIVE USB stick.
#
# Why this exists: the stock image only uses ~120 MB of the disk. Growing the
# root filesystem while the router is running FROM it can corrupt it
# (ext4 "invalid block bitmap", remounted read-only, won't boot).
# Doing it here, while the target disk is not mounted, avoids that.
#
# Run on the live USB system:
#   sh flash-and-resize.sh /tmp/openwrt-...-x86-64-generic-ext4-combined-efi.img.gz /dev/nvme0n1
#
# Optional:  FIRSTBOOT_DHCP=1  -> the new install boots as a DHCP *client* with
# its DHCP server off, so you can plug it into an existing network for setup
# without clashing with your current router.

set -eu

IMAGE="${1:-}"
DISK="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$IMAGE" ] && [ -n "$DISK" ] || die "usage: sh $0 <image.img.gz> </dev/disk>"
[ -f "$IMAGE" ] || die "image not found: $IMAGE"
[ -b "$DISK" ] || die "$DISK is not a block device"
case "$IMAGE" in *ext4-combined*) ;; *) die "use an *ext4-combined* image (squashfs images can't be grown this way)" ;; esac

# Partition names: /dev/sda -> /dev/sda2, /dev/nvme0n1 -> /dev/nvme0n1p2
case "$DISK" in
    *[0-9]) PART="${DISK}p2" ;;
    *)      PART="${DISK}2" ;;
esac

# Refuse to touch the disk we're running from or anything mounted on it.
if grep -q "^$DISK" /proc/mounts; then
    die "$DISK (or a partition on it) is mounted. Is this the disk you booted from?"
fi

echo
echo "  Image : $IMAGE"
echo "  Target: $DISK  ($(awk -v d="$(basename "$DISK")" '$4==d {printf "%.1f GB", $3/1048576}' /proc/partitions))"
echo
echo "  EVERYTHING on $DISK will be erased."
printf "  Type the disk name (%s) to continue: " "$(basename "$DISK")"
read -r answer
[ "$answer" = "$(basename "$DISK")" ] || die "aborted"

echo "==> Installing tools"
for t in parted e2fsprogs resize2fs; do
    command -v "$t" >/dev/null 2>&1 || apk add "$t" >/dev/null 2>&1 || true
done
command -v parted >/dev/null || die "parted missing and could not be installed (is the live USB online?)"
command -v resize2fs >/dev/null || die "resize2fs missing and could not be installed"

echo "==> Wiping start of disk"
dd if=/dev/zero of="$DISK" bs=1M count=100 2>/dev/null

echo "==> Writing image (this takes a minute)"
gunzip -c "$IMAGE" | dd of="$DISK" bs=1M conv=fsync 2>/dev/null || true   # gunzip warns about trailing garbage; harmless
sync

echo "==> Growing partition 2 to fill the disk"
parted -f -s "$DISK" resizepart 2 100%
sleep 2
[ -b "$PART" ] || die "$PART not found after resize"

echo "==> Checking and growing the filesystem (offline - this is the safe way)"
e2fsck -f -y "$PART" || true
resize2fs "$PART"

if [ "${FIRSTBOOT_DHCP:-0}" = "1" ]; then
    echo "==> Adding first-boot DHCP-client script"
    mkdir -p /mnt/owrt-target
    mount "$PART" /mnt/owrt-target
    cat > /mnt/owrt-target/etc/uci-defaults/99-temp-dhcp-client <<'EOF'
uci set network.lan.proto='dhcp'
uci -q delete network.lan.ipaddr
uci commit network
uci set dhcp.lan.ignore='1'
uci commit dhcp
EOF
    umount /mnt/owrt-target
fi

echo
lsblk "$DISK" 2>/dev/null || cat /proc/partitions
echo
echo "Done. Power off, remove the USB stick, and boot from $DISK."
[ "${FIRSTBOOT_DHCP:-0}" = "1" ] && echo "It will ask your existing router for an IP - check that router's DHCP list to find it."
