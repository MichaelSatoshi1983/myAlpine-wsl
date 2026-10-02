#!/bin/sh
set -eu

WSL_USERNAME=${WSL_USERNAME:-alpine}
OH_MY_ZSH_COMMIT=4d4cfc287e9d887b81242c0e431b5f49f9cec5c1

echo "update apk indexes"

apk update

echo "install packages"

apk add \
  zsh \
  zsh-autosuggestions \
  zsh-syntax-highlighting \
  ca-certificates \
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

ZSH_DIR="/home/$WSL_USERNAME/.oh-my-zsh"
git init -q "$ZSH_DIR"
git -C "$ZSH_DIR" remote add origin https://github.com/ohmyzsh/ohmyzsh.git
git -C "$ZSH_DIR" fetch --depth=1 origin "$OH_MY_ZSH_COMMIT"
git -C "$ZSH_DIR" checkout -q -b master FETCH_HEAD
git -C "$ZSH_DIR" config branch.master.remote origin
git -C "$ZSH_DIR" config branch.master.merge refs/heads/master

# shellcheck disable=SC2016
cat > "/home/$WSL_USERNAME/.zshrc" <<'EOF'
export EDITOR=nvim
export VISUAL=nvim

export GOPATH="$HOME/go"
export PATH="$PATH:$GOPATH/bin"

export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME:$PATH"

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"

# Update deliberately instead of making shell startup depend on the network.
zstyle ':omz:update' mode disabled
plugins=(git docker docker-compose sudo z)
source "$ZSH/oh-my-zsh.sh"

HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_SPACE HIST_IGNORE_ALL_DUPS SHARE_HISTORY
bindkey -e

source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
# Keep syntax highlighting last so it sees the other plugins' widgets.
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF

echo "create common directories"

mkdir -p "/home/$WSL_USERNAME/go"
mkdir -p "/home/$WSL_USERNAME/.local/share/pnpm"

touch "/home/$WSL_USERNAME/.hushlogin"

echo "set ownership"

chown -R "$WSL_USERNAME:$WSL_USERNAME" "/home/$WSL_USERNAME"

echo "validate zsh configuration"
zsh -n "/home/$WSL_USERNAME/.zshrc"
# shellcheck disable=SC2016
su - "$WSL_USERNAME" -c 'zsh -i -c '\''[[ $ZSH_THEME == robbyrussell ]] && (( $+functions[git_prompt_info] )) && (( $+functions[_zsh_autosuggest_start] )) && (( $+functions[_zsh_highlight] ))'\'''

echo "done"
