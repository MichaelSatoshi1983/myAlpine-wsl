#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
ROOTFS="$REPO_DIR/rootfs"
ARCHIVE="$REPO_DIR/alpine.tar.gz"
OUTPUT="$REPO_DIR/alpine-wsl.tar.gz"
WSL_USERNAME=${WSL_USERNAME:-alpine}
if [ -z "${BUILD_COMMIT:-}" ]; then
  BUILD_COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || printf 'unknown')
fi

case "$WSL_USERNAME" in
  ''|[!a-z]*|*[!a-z0-9_-]*)
    echo "WSL_USERNAME must start with a lowercase letter and contain only lowercase letters, digits, _ or -" >&2
    exit 2
    ;;
esac

unmount_rootfs_mounts() {
  for name in sys proc dev; do
    mount_path="$ROOTFS/$name"
    if mountpoint -q "$mount_path"; then
      umount "$mount_path"
    fi
  done
}

cleanup() {
  set +e
  unmount_rootfs_mounts || echo "warning: one or more rootfs mounts could not be removed" >&2
  rm -f "$ROOTFS/setup.sh" "$ARCHIVE"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$REPO_DIR"

echo "fetch latest Alpine version"
LATEST_FILE=$(wget -qO- \
  https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/ \
  | grep -oE 'alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-x86_64\.tar\.gz' \
  | sort -Vu \
  | tail -n1 || true)

if [ -z "$LATEST_FILE" ]; then
  echo "failed to detect latest Alpine release" >&2
  exit 1
fi

LATEST_VERSION=$(printf '%s\n' "$LATEST_FILE" | sed -E 's/alpine-minirootfs-(.*)-x86_64.tar.gz/\1/')
MAJOR_VERSION=$(printf '%s\n' "$LATEST_VERSION" | cut -d. -f1,2)
DOWNLOAD_URL="https://dl-cdn.alpinelinux.org/alpine/v${MAJOR_VERSION}/releases/x86_64/${LATEST_FILE}"
echo "latest Alpine version: $LATEST_VERSION"

echo "download and validate Alpine rootfs"
wget -qO "$ARCHIVE" "$DOWNLOAD_URL"
tar -tzf "$ARCHIVE" >/dev/null

echo "prepare rootfs"
unmount_rootfs_mounts
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
tar -xzf "$ARCHIVE" -C "$ROOTFS"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
cp "$SCRIPT_DIR/setup.sh" "$ROOTFS/setup.sh"
chmod +x "$ROOTFS/setup.sh"

echo "mount virtual filesystems"
for name in dev proc sys; do
  mount --bind "/$name" "$ROOTFS/$name"
done

echo "configure Alpine WSL rootfs"
chroot "$ROOTFS" /usr/bin/env WSL_USERNAME="$WSL_USERNAME" /bin/sh /setup.sh

mkdir -p "$ROOTFS/etc"
{
  printf 'Alpine version: %s\n' "$LATEST_VERSION"
  printf 'Source commit: %s\n' "$BUILD_COMMIT"
  printf 'Built at (UTC): %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
} > "$ROOTFS/etc/alpine-wsl-build"

echo "package and verify WSL rootfs"
tar --numeric-owner -czf "$OUTPUT" -C "$ROOTFS" .
gzip -t "$OUTPUT"
tar -tzf "$OUTPUT" | grep -Fx './etc/alpine-wsl-build' >/dev/null

echo "created $OUTPUT"
