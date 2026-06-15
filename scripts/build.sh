#!/bin/sh
set -e

ROOTFS="rootfs"

ALPINE_VERSION="3.20.3"

echo "download alpine rootfs"
wget -qO alpine.tar.gz \
https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz

rm -rf "$ROOTFS"
mkdir "$ROOTFS"

tar -xzf alpine.tar.gz -C "$ROOTFS"

echo "prepare dns"
echo "nameserver 8.8.8.8" > "$ROOTFS/etc/resolv.conf"

echo "enter chroot and install packages"
cp /etc/resolv.conf "$ROOTFS/etc/"

cat > "$ROOTFS/setup.sh" <<'EOF'
#!/bin/sh
set -e

apk update

apk add \
  zsh \
  git \
  curl \
  wget \
  sudo \
  neovim \
  go \
  ruby \

adduser -D -s /bin/zsh michaelmason

echo "michaelmason ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
EOF

chmod +x "$ROOTFS/setup.sh"

chroot "$ROOTFS" /bin/sh /setup.sh

echo "packaging"
cd "$ROOTFS"
tar --numeric-owner -czf ../alpine-wsl.tar.gz .

echo "done"
