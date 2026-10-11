# myAlpine-wsl

A small Alpine Linux development environment packaged as an importable WSL 2 root filesystem. The build installs common development tools and runs Docker Engine inside the distro; Docker Desktop is not required.

## Download and import

Download `alpine-wsl.tar.gz` from the [latest GitHub Release](https://github.com/MichaelSatoshi1983/myAlpine-wsl/releases/latest). In PowerShell, choose an install directory and import it as WSL 2:

```powershell
mkdir "$env:LOCALAPPDATA\AlpineWSL" -Force
wsl --import Alpine "$env:LOCALAPPDATA\AlpineWSL" .\alpine-wsl.tar.gz --version 2
wsl -d Alpine
```

The image defaults to the `alpine` user and Windows 10 compatibility. In GitHub Actions, choose `windows10` or `windows11` under **Run workflow**. Scheduled and PR builds default to `windows10`. Both configurations use OpenRC and leave systemd disabled.

Windows 10 builds omit `[boot]` from `/etc/wsl.conf`. On both targets, entering an interactive Zsh session inside WSL starts Docker through OpenRC if it is not already started. The startup helper initializes OpenRC's runtime state because WSL's init does not run the normal OpenRC boot sequence. To start it manually or inspect a startup error:

```sh
sudo wsl-start-docker
docker version
docker run --rm hello-world
```

Windows 11 builds also call the helper through the WSL boot command; this applies to supported Windows Server 2022 WSL installations. On Windows 10, Docker starts when the first interactive Zsh session opens, so running only a noninteractive `wsl --exec` command does not trigger it. `rc-update add docker default` alone does not start services under WSL's default init. The Windows version option configures the downloaded image; it does not modify an already imported distro.

To disable shell-triggered Docker startup, add `export WSL_DOCKER_AUTOSTART=0` above the startup block in `~/.zshrc`. On Windows 11, also remove the `[boot]` command from `/etc/wsl.conf` if you want to disable automatic startup entirely.

To edit an imported distro's settings, back up `/etc/wsl.conf` with `sudo cp /etc/wsl.conf /etc/wsl.conf.bak`, then run `sudo nvim /etc/wsl.conf`. For Windows 10, remove the `[boot]` section and its `command` entry. Do not add `systemd=true` to this OpenRC image. In PowerShell, run `wsl --terminate Alpine` and `wsl -d Alpine` to apply changes, replacing `Alpine` with your distro name. CPU and memory settings belong in Windows `%UserProfile%\.wslconfig` instead.

The configured user belongs to the `docker` group so it can use Docker without `sudo`. Access to the Docker socket is effectively root access inside the distro. To stop the daemon, run `sudo rc-service docker stop`.

Container output logs use the `json-file` driver with rotation: each file is limited to 10 MB and up to three files are retained per container (roughly 30 MB per container). This controls container stdout/stderr logs, not image, volume, or Docker daemon log sizes. Edit `/etc/docker/daemon.json` to change the defaults. After changing the settings on an existing installation, restart Docker and recreate containers to apply the new defaults. Individual containers or Compose services can override them. The build validates the daemon configuration without starting Docker.

## Migrate from an existing WSL distro

The new image includes an interactive `wsl-migrate` command. It makes a full WSL export of the old distro, then imports that export under a second name. The old distro stays registered, and the clone contains the old distro's persistent filesystem: Alpine version, installed packages, system configuration, users, home files, and Docker images, containers, and volumes.

Start the new image and run the command there. Replace `Alpine` with the old distro name from `wsl -l -q` in PowerShell:

```sh
wsl-migrate --dry-run Alpine
wsl-migrate Alpine
```

The script proposes `Alpine-migrated` as the new name and asks before stopping the old distro. It retains a full export under `Documents/myAlpine-wsl-backups` and imports the clone as WSL 2 under `%LOCALAPPDATA%/AlpineWSL-<new-name>`. Use `--backup-dir` and `--install-location` to choose different paths on mounted Windows drives. It also offers to make the clone the default after import; it never unregisters either distro or deletes the export. To restore the prior default later, run `wsl-migrate --rollback Alpine`.

A full clone preserves the old environment; it does not upgrade the cloned Alpine packages or system files to the new Release image. The script warns and asks before continuing because:

- a WSL 1 source will be imported as WSL 2, which can change behavior;
- Windows-side `.wslconfig`, Windows Terminal profiles, WSL registration settings, and files outside the distro filesystem are not included;
- the old `/etc/wsl.conf` is kept verbatim, so boot commands and default-user settings may need review;
- running both copies can start duplicate services and Docker workloads, contend for ports, or access the same cloned container data;
- the source is terminated before export so filesystem and Docker data are captured consistently; unsaved process state is lost.

The full export is kept as a recovery copy. Check that Windows has enough free disk space before starting. After import, test the clone before making it your default. The script itself is added to the clone as `/usr/local/bin/wsl-migrate`.

## Build locally

Build on an x86_64 Linux host with root privileges, `wget`, `tar`, and `mountpoint` installed. The build fetches the current Alpine stable minirootfs and writes `alpine-wsl.tar.gz` in the repository root.

```sh
sudo env WSL_USERNAME=developer BUILD_COMMIT="$(git rev-parse HEAD)" ./scripts/build.sh
```

`WSL_USERNAME` is optional and defaults to `alpine`. It must start with a lowercase letter and contain only lowercase letters, digits, `_` or `-`. The build grants this user passwordless sudo to support an out-of-box development environment.

`WSL_WINDOWS_VERSION` defaults to `windows10`; set it to `windows11` to include Docker's WSL boot command.

## Included tools

The image includes Zsh, Bash, Git, OpenSSH, Neovim, tmux, common shell utilities, Go, Ruby, Node.js/npm, pnpm, TypeScript, Docker Engine, Docker CLI, and the Docker Compose CLI plugin. The image targets x86_64 only.

## JetBrains Remote Development

The image includes a musl compatibility shim for JetBrains Runtime and configures it in the default user's Zsh environment. This works around missing glibc large-file symbols and a verifier failure reported with some JetBrains backends on Alpine. The workaround is based on [this Alpine JetBrains Remote Development guide](https://www.eth0.bond/2026/06/03/%E6%AD%A3%E7%A1%AE%E9%85%8D%E7%BD%AE%20Alpine%20%E4%B8%8A%E7%9A%84%20Jetbrains%20%E8%BF%9C%E7%A8%8B%E5%BC%80%E5%8F%91/).

JetBrains documents glibc-based Linux hosts for Remote Development and does not list Alpine as supported. This compatibility layer is a community workaround; behavior may vary across IDE and JBR versions. Gateway must connect through the configured user's Zsh login environment for these settings to apply.

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

`/etc/alpine-wsl-build` inside the image records the Alpine version, source commit, Windows target, and UTC build time. GitHub Actions validates shell syntax, the packaged metadata, and the target's WSL configuration. It uploads each successful build as an Actions artifact, but creates a GitHub Release only when there is no existing release for that Alpine version, source commit, and Windows target. Release tags end with `windows10` or `windows11` so the two configurations have separate downloads. Daily scheduled builds therefore do not create repeated releases for unchanged inputs.

The startup helper uses OpenRC (`rc-service --nodeps --ifnotstarted docker start`); Alpine's default service manager is OpenRC. WSL provides the network, devices, and mounts, so the helper skips the normal OpenRC boot dependencies. Docker Engine requires WSL 2 and working kernel support for containers. The Windows host's WSL kernel configuration can limit Docker features.
