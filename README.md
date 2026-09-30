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

## Build locally

Build on an x86_64 Linux host with root privileges, `wget`, `tar`, and `mountpoint` installed. The build fetches the current Alpine stable minirootfs and writes `alpine-wsl.tar.gz` in the repository root.

```sh
sudo env WSL_USERNAME=developer BUILD_COMMIT="$(git rev-parse HEAD)" ./scripts/build.sh
```

`WSL_USERNAME` is optional and defaults to `alpine`. It must start with a lowercase letter and contain only lowercase letters, digits, `_` or `-`. The build grants this user passwordless sudo to support an out-of-box development environment.

## Included tools

The image includes Zsh, Bash, Git, OpenSSH, Neovim, tmux, common shell utilities, Go, Ruby, Node.js/npm, pnpm, TypeScript, Docker Engine, Docker CLI, and the Docker Compose CLI plugin. The image targets x86_64 only.

## Build metadata and releases

`/etc/alpine-wsl-build` inside the image records the Alpine version, source commit, and UTC build time. GitHub Actions validates shell syntax and the packaged metadata. It uploads each successful build as an Actions artifact, but creates a GitHub Release only when there is no existing release for that Alpine version and source commit. Daily scheduled builds therefore do not create repeated releases for unchanged inputs.

The WSL startup command uses OpenRC (`rc-service docker start`); Alpine's default service manager is OpenRC. Docker Engine requires WSL 2 and working kernel support for containers. The Windows host's WSL kernel configuration can limit Docker features.
