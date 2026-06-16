#!/bin/sh
set -e

ROOTFS="rootfs"

echo "fetch latest alpine version"

LATEST_VERSION=$(wget -qO- \
https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml \
| grep minirootfs \
| head -n1 \
| awk '{print $2}')

MAJOR_VERSION=$(echo "$LATEST_VERSION" | cut -d. -f1,2)

echo "latest alpine version: $LATEST_VERSION"

echo "download alpine rootfs"

wget -qO alpine.tar.gz \
https://dl-cdn.alpinelinux.org/alpine/v${MAJOR_VERSION}/releases/x86_64/alpine-minirootfs-${LATEST_VERSION}-x86_64.tar.gz

echo "prepare rootfs"

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

tar -xzf alpine.tar.gz -C "$ROOTFS"

echo "prepare dns"

cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

echo "copy setup script"

cp scripts/setup.sh "$ROOTFS/setup.sh"

chmod +x "$ROOTFS/setup.sh"

echo "enter chroot"

mount --bind /dev "$ROOTFS/dev"
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"

chroot "$ROOTFS" /bin/sh /setup.sh

echo "cleanup mounts"

umount "$ROOTFS/dev"
umount "$ROOTFS/proc"
umount "$ROOTFS/sys"

rm -f "$ROOTFS/setup.sh"

echo "packaging"

tar --numeric-owner -czf alpine-wsl.tar.gz -C "$ROOTFS" .

echo "done"
