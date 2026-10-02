# myAlpine-wsl

A small Alpine Linux development environment packaged as an importable WSL 2 root filesystem. The build installs common development tools and runs Docker Engine inside the distro; Docker Desktop is not required.

## Download and import

Download `alpine-wsl.tar.gz` from the [latest GitHub Release](https://github.com/MichaelSatoshi1983/myAlpine-wsl/releases/latest). In PowerShell, choose an install directory and import it as WSL 2:

```powershell
mkdir "$env:LOCALAPPDATA\AlpineWSL" -Force
wsl --import Alpine "$env:LOCALAPPDATA\AlpineWSL" .\alpine-wsl.tar.gz --version 2
wsl -d Alpine
```

The image defaults to the `alpine` user. On supported Windows 11 / Windows Server 2022 WSL versions, Docker starts when the distro starts. On older WSL versions, start it manually inside Alpine:

```sh
sudo rc-service docker start
docker version
docker run --rm hello-world
```

The configured user belongs to the `docker` group so it can use Docker without `sudo`. Access to the Docker socket is effectively root access inside the distro. To stop the daemon, run `sudo rc-service docker stop`.

Container output logs use the `json-file` driver with rotation: each file is limited to 10 MB and up to three files are retained per container (roughly 30 MB per container). This controls container stdout/stderr logs, not image, volume, or Docker daemon log sizes. Edit `/etc/docker/daemon.json` to change the defaults. After changing the settings on an existing installation, restart Docker and recreate containers to apply the new defaults. Individual containers or Compose services can override them. The build validates the daemon configuration without starting Docker.

## Build locally

Build on an x86_64 Linux host with root privileges, `wget`, `tar`, and `mountpoint` installed. The build fetches the current Alpine stable minirootfs and writes `alpine-wsl.tar.gz` in the repository root.

```sh
sudo env WSL_USERNAME=developer BUILD_COMMIT="$(git rev-parse HEAD)" ./scripts/build.sh
```

`WSL_USERNAME` is optional and defaults to `alpine`. It must start with a lowercase letter and contain only lowercase letters, digits, `_` or `-`. The build grants this user passwordless sudo to support an out-of-box development environment.

## Included tools

The image includes Zsh, Bash, Git, OpenSSH, Neovim, tmux, common shell utilities, Go, Ruby, Node.js/npm, pnpm, TypeScript, Docker Engine, Docker CLI, and the Docker Compose CLI plugin. The image targets x86_64 only.

## Network diagnostics

The image includes `iproute2`, `bind-tools`, `iputils`, `traceroute`, `mtr`, `netcat-openbsd`, and `tcpdump`. Builds check that their main commands are available.

```sh
ip address                       # network interfaces and addresses
ip route                         # routing table
ss -lnt                          # listening TCP ports
dig example.com                  # DNS lookup
ping -c 4 1.1.1.1                # basic connectivity
traceroute example.com           # route to a host
mtr --report --report-cycles 10 example.com  # route and packet loss
nc -vz -w 3 example.com 443       # TCP connection check
sudo tcpdump -i any -nn -c 20     # capture 20 packets
```

## Zsh

Zsh uses Oh My Zsh with the `robbyrussell` theme: a simple `➜ ~` prompt at home, with the current directory and Git branch elsewhere. No Nerd Font is required.

Enabled plugins:

- `zsh-autosuggestions`: suggests commands from history; press the right arrow to accept.
- `zsh-syntax-highlighting`: highlights commands as you type.
- `git`, `docker`, `docker-compose`: aliases and completions.
- `sudo`: press Escape twice to prepend `sudo` to the current command.
- `z`: jump to previously visited directories with `z <name>`.

History is shared between terminals and retains up to 10,000 entries. Commands starting with a space are excluded from history. Edit `~/.zshrc` to change the theme or plugins.

Oh My Zsh is installed at a pinned commit during the build. Automatic updates are disabled, so opening a terminal does not trigger an update check. The two external plugins are managed by Alpine's package manager. After import, update them with `sudo apk upgrade`; run `omz update` to update Oh My Zsh manually. Builds check Zsh syntax and verify that the theme and external plugins load as the configured user.

## Build metadata and releases

`/etc/alpine-wsl-build` inside the image records the Alpine version, source commit, and UTC build time. GitHub Actions validates shell syntax and the packaged metadata. It uploads each successful build as an Actions artifact, but creates a GitHub Release only when there is no existing release for that Alpine version and source commit. Daily scheduled builds therefore do not create repeated releases for unchanged inputs.

The WSL startup command uses OpenRC (`rc-service docker start`); Alpine's default service manager is OpenRC. Docker Engine requires WSL 2 and working kernel support for containers. The Windows host's WSL kernel configuration can limit Docker features.
