#!/bin/sh
set -e

echo "update apk indexes"

apk update

echo "install packages"

apk add \
  zsh \
  bash \
  git \
  curl \
  wget \
  sudo \
  openssh \
  neovim \
  tmux \
  htop \
  ripgrep \
  fd \
  tree \
  less \
  grep \
  build-base \
  go \
  gopls \
  ruby \
  ruby-dev \
  ruby-bundler \
  nodejs \
  npm \
  docker-cli \
  docker-compose

echo "install global npm packages"

npm install -g \
  pnpm \
  typescript

echo "create user"

adduser -D -s /bin/zsh michaelmason

echo "configure sudo"

echo "michaelmason ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

echo "prepare home directory"

mkdir -p /home/michaelmason

echo "configure wsl"

cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[automount]
enabled=true
root=/mnt/
options="metadata,umask=22,fmask=11,case=off"

[interop]
enabled=true
appendWindowsPath=false

[network]
generateResolvConf=true

[user]
default=michaelmason
EOF

echo "configure zsh environment"

cat > /home/michaelmason/.zshrc <<'EOF'
export EDITOR=nvim
export VISUAL=nvim

export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"

export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

export TERM=xterm-256color
EOF

echo "create common directories"

mkdir -p /home/michaelmason/go
mkdir -p /home/michaelmason/.local/share/pnpm

echo "set ownership"

chown -R michaelmason:michaelmason /home/michaelmason

echo "done"
