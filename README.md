# myAlpine-wsl

A small Alpine Linux development environment packaged as an importable WSL 2 root filesystem. The build installs common development tools and runs Docker Engine inside the distro; Docker Desktop is not required.

## Download and import

Download `alpine-wsl.tar.gz` from the [latest GitHub Release](https://github.com/MichaelSatoshi1983/myAlpine-wsl/releases/latest). In PowerShell, choose an install directory and import it as WSL 2:

```powershell
mkdir "$env:LOCALAPPDATA\AlpineWSL" -Force
wsl --import Alpine "$env:LOCALAPPDATA\AlpineWSL" .\alpine-wsl.tar.gz --version 2
wsl -d Alpine
```

The image defaults to the `alpine` user. GitHub Actions builds both Windows 10 and Windows 11 images for pull requests, manual runs, and the daily schedule. Both configurations use OpenRC and leave systemd disabled.

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

The new image includes an interactive `wsl-migrate` command. It keeps the new Release Alpine system and migrates the old environment's data, compatible APK packages, users, OpenRC service selections, and application configuration into it. The old distro stays registered and unchanged.

Import the new Release image as a second WSL distro, start it, and run the command as root. Replace `Alpine` with the old distro name from `wsl -l -q` in PowerShell:

```sh
sudo -E wsl-migrate --dry-run Alpine
sudo -E wsl-migrate Alpine
```

The script checks source/target sizes and backup space, then shows a processing overview and waits for confirmation. It asks you to stop app/database workloads and type `READY`, stops Docker in both distros when possible, syncs and gracefully powers off the source, and asks for a separate `FORCE` confirmation if it remains running. The complete source export, target snapshot, checksum, and file manifest are kept under `Documents/myAlpine-wsl-backups` by default. The estimate includes headroom for the archive, target snapshot, and restored data.

By default, it migrates `/home`, `/root`, `/opt`, `/srv`, `/usr/local`, `/var/www`, and application data under `/var/lib`. Add another persistent path with `--include /path`. For example, `sudo -E wsl-migrate --include /data Alpine` also copies `/data`. The script retains the new OS, APK database, WSL boot/network configuration, and machine identity. It installs packages from the old `/etc/apk/world` where current repositories can resolve them; if old version pins are unavailable, it shows the plan and asks before installing current versions. It recreates compatible non-system users/groups with matching numeric IDs and keeps conflicting identities for review.

Old non-system `/etc` configuration files are merged. Missing files are copied automatically. When a file differs, the script lists the conflicts and asks whether to use the old or new versions. The complete old `/etc` tree is also retained under `/var/lib/wsl-migrate/<run>/source-etc/etc`; old system-owned files such as `/etc/wsl.conf`, build metadata, account databases, APK state, OpenRC init scripts, host keys, and machine identity are preserved there but not activated. The new Release's `wsl-update`, `wsl-migrate`, Docker startup helper, build metadata, and compatibility shim remain in place. Compatible regular users and groups are recreated, including their password entries; root password settings remain from the new Release. The old WSL default user is applied only if that account exists in the new system. SSH host keys are regenerated for the new distro.

Docker files under `/var/lib/docker` and other application data are copied while both Docker services are stopped. APK, OpenRC, DBus, and miscellaneous runtime state under `/var/lib` stays from the new Release. A newer Docker or kernel/storage driver may not be able to use old container state; the script reports this risk and verifies copied content, ownership, permissions, and symlink targets. If verification finds differences, it shows a short diff and requires typing `CONTINUE` to finish. Missing packages, user/group ID conflicts, and unavailable services are listed in the migration warnings and report. Old files outside the included paths remain in the full source export; add them explicitly with `--include`.

Custom executables and libraries under `/usr/local`, `/opt`, and migrated application directories may depend on the old Alpine or musl version; they are preserved, but may need to be rebuilt or reconfigured for the new Release.

If a run stops after creating the export, resume without exporting again: `sudo -E wsl-migrate --resume /mnt/c/Users/you/Documents/myAlpine-wsl-backups/Alpine-20261011T080000Z.tar Alpine`. The old distro remains registered throughout; no distro or backup is automatically deleted. To restore the previous WSL default, run `wsl-migrate --rollback` inside the new distro. The old distro and complete export remain available for recovery.



## Check for release updates

New images include the `wsl-update` command. Run it inside the distro you want to migrate from:

```sh
wsl-update
```

The command checks for the newest published Release matching the image's Windows target and x64 architecture. It downloads the archive, verifies the SHA-256 checksum and embedded build metadata, then offers three choices:

- **Automatic** opens a separate PowerShell window, imports the new image side by side under a Release-tagged WSL name in `%LOCALAPPDATA%\AlpineWSL\releases`, and starts the interactive `wsl-migrate` flow there. The coordinator survives the source distro stopping during migration, restarts the new distro afterward, and checks its core commands and default user.
- **Manual** keeps the verified archive under `Documents\myAlpine-wsl-updates` and prints the PowerShell import and migration commands.
- **Skip** leaves the verified download in place without importing it.

The migration still shows its overview and asks before changing data. The old distro remains registered. If a previous run imported the new distro but did not finish migration, run `wsl-update` again and choose **R** in the PowerShell recovery window to retry migration without importing over it. Partial downloads resume when you run the updater again. The updater never unregisters an old or new distro or deletes its data.

Use these options to control the check:

```sh
wsl-update --check   # check only; do not download
wsl-update --auto    # download, import side by side, and start migration
wsl-update --manual  # download and print the PowerShell steps
```

Release tags use `Alpine_DDMMYY_win10x64_<12-character-commit>` or `Alpine_DDMMYY_win11x64_<12-character-commit>`. The date is UTC. Each updater only offers Releases matching the Windows target recorded in its image, so a Windows 10 image will not offer a Windows 11 build.

Images published before the updater was added do not contain `wsl-update`. To start using it, manually import the first Release built with this updater as a second distro, then run `sudo -E wsl-migrate <old-distro-name>` there; subsequent releases can be checked from inside the new distro.

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

`/etc/alpine-wsl-build` inside the image records the Alpine version, source commit, Windows target, Release tag, and UTC build time. GitHub Actions validates shell syntax, the packaged metadata, both update commands, and the target's WSL configuration. It uploads each target as a separate Actions artifact and publishes both root filesystems with their SHA-256 files. Release tags follow `Alpine_DDMMYY_win10x64_<12-character-commit>` or `Alpine_DDMMYY_win11x64_<12-character-commit>`; the date is UTC.

To exercise a built image on Windows, run the isolated integration check from PowerShell. It imports temporary source and target distros, performs a real data migration, restarts the target, checks the migrated marker and default user, verifies the existing WSL default was unchanged, then unregisters only those temporary distros:

```powershell
.\scripts\test-wsl-integration.ps1 -ArchivePath .\alpine-wsl.tar.gz
```

The startup helper uses OpenRC (`rc-service --nodeps --ifnotstarted docker start`); Alpine's default service manager is OpenRC. WSL provides the network, devices, and mounts, so the helper skips the normal OpenRC boot dependencies. Docker Engine requires WSL 2 and working kernel support for containers. The Windows host's WSL kernel configuration can limit Docker features.

