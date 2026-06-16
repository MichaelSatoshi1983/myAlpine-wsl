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

rm -rf "$ROOTFS"
mkdir "$ROOTFS"

tar -xzf alpine.tar.gz -C "$ROOTFS"

echo "prepare dns"
cp /etc/resolv.conf "$ROOTFS/etc/"

echo "copy setup script"
cp scripts/setup.sh "$ROOTFS/setup.sh"

chmod +x "$ROOTFS/setup.sh"

echo "enter chroot"
chroot "$ROOTFS" /bin/sh /setup.sh

echo "packaging"
cd "$ROOTFS"

tar --numeric-owner -czf ../alpine-wsl.tar.gz .

echo "done"
