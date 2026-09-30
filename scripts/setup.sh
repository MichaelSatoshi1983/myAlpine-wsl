#!/bin/sh
set -eu

WSL_USERNAME=${WSL_USERNAME:-alpine}

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
  openrc \
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
  docker \
  docker-cli \
  docker-cli-compose \
  docker-openrc

echo "install global npm packages"

npm install -g \
  pnpm \
  typescript

echo "create user"

adduser -D -s /bin/zsh "$WSL_USERNAME"

echo "configure sudo"

printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$WSL_USERNAME" > /etc/sudoers.d/90-wsl-user
chmod 0440 /etc/sudoers.d/90-wsl-user
visudo -cf /etc/sudoers.d/90-wsl-user

echo "configure Docker access"

if ! grep -q '^docker:' /etc/group; then
  addgroup -S docker
fi
addgroup "$WSL_USERNAME" docker
rc-update add docker default

echo "configure wsl"

cat > /etc/wsl.conf <<EOF
[boot]
command=/sbin/rc-service docker start

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
default=$WSL_USERNAME
EOF

echo "configure zsh environment"

# shellcheck disable=SC2016
cat > "/home/$WSL_USERNAME/.zshrc" <<'EOF'
export EDITOR=nvim
export VISUAL=nvim

export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"

export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

export TERM=xterm-256color
EOF

echo "create common directories"

mkdir -p "/home/$WSL_USERNAME/go"
mkdir -p "/home/$WSL_USERNAME/.local/share/pnpm"

touch "/home/$WSL_USERNAME/.hushlogin"

echo "set ownership"

chown -R "$WSL_USERNAME:$WSL_USERNAME" "/home/$WSL_USERNAME"

echo "done"
