#!/bin/sh
set -e

ROOTFS="rootfs"

echo "fetch latest alpine release metadata"

LATEST_FILE=$(wget -qO- \
https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml \
| grep "file: alpine-minirootfs" \
| head -n1 \
| cut -d' ' -f2)

LATEST_VERSION=$(echo "$LATEST_FILE" \
| sed -E 's/alpine-minirootfs-(.*)-x86_64.tar.gz/\1/')

MAJOR_VERSION=$(echo "$LATEST_VERSION" | cut -d. -f1,2)

echo "latest alpine version: $LATEST_VERSION"

DOWNLOAD_URL="https://dl-cdn.alpinelinux.org/alpine/v${MAJOR_VERSION}/releases/x86_64/${LATEST_FILE}"

echo "download alpine rootfs"

wget -qO alpine.tar.gz "$DOWNLOAD_URL"

echo "prepare rootfs"

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

tar -xzf alpine.tar.gz -C "$ROOTFS"

echo "prepare dns"

cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

echo "copy setup script"

cp scripts/setup.sh "$ROOTFS/setup.sh"

chmod +x "$ROOTFS/setup.sh"

echo "mount virtual filesystems"

mount --bind /dev "$ROOTFS/dev"
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"

echo "enter chroot"

chroot "$ROOTFS" /bin/sh /setup.sh

echo "cleanup mounts"

umount "$ROOTFS/dev"
umount "$ROOTFS/proc"
umount "$ROOTFS/sys"

rm -f "$ROOTFS/setup.sh"

echo "packaging rootfs"

tar --numeric-owner -czf alpine-wsl.tar.gz -C "$ROOTFS" .

echo "done"
