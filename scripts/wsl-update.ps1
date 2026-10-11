param(
    [Parameter(Mandatory = $true)]
    [string]$StateFile,

    [switch]$Child
)

$ErrorActionPreference = 'Stop'

if (-not $Child) {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        throw "Update state file not found: $StateFile"
    }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Child -StateFile "{1}"' -f $PSCommandPath, $StateFile
    Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Normal | Out-Null
    exit 0
}

$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$exitCode = 0

try {
    $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    foreach ($property in @('tag', 'sourceDistro', 'installPath', 'archivePath', 'sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$state.$property)) {
            throw "Update state is missing '$property'."
        }
    }

    if ($state.tag -notmatch '^Alpine_[0-9]{6}_win(10|11)x64_[0-9a-f]{12}$') {
        throw "Refusing an invalid Release name: $($state.tag)"
    }
    if ($state.sourceDistro -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "The source distro name contains characters unsupported by wsl-migrate: $($state.sourceDistro)"
    }
    if ($state.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'The archive checksum in the update state is invalid.'
    }
    if (-not (Test-Path -LiteralPath $state.archivePath -PathType Leaf)) {
        throw "Verified archive not found: $($state.archivePath)"
    }

    $actualHash = (Get-FileHash -LiteralPath $state.archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $state.sha256) {
        throw 'The saved archive changed after the updater verified it.'
    }

    $registered = @(& $wsl --list --quiet 2>$null | ForEach-Object { (([string]$_) -replace "`0", '').Trim() })
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read the registered WSL distributions.'
    }
    $alreadyRegistered = $registered -contains [string]$state.tag

    if (-not $alreadyRegistered) {
        if (Test-Path -LiteralPath $state.installPath) {
            $existingItems = @(Get-ChildItem -LiteralPath $state.installPath -Force -ErrorAction SilentlyContinue)
            if ($existingItems.Count -gt 0) {
                throw "The install directory already contains data and was left untouched: $($state.installPath)"
            }
        } else {
            New-Item -ItemType Directory -Path $state.installPath -Force | Out-Null
        }

        Write-Host "Importing $($state.tag) as a separate WSL distro..."
        & $wsl --import $state.tag $state.installPath $state.archivePath --version 2
        if ($LASTEXITCODE -ne 0) {
            throw 'WSL import failed. The verified archive and existing distro remain available.'
        }
    } else {
        Write-Host "The distro $($state.tag) is already registered. This is a recovery run; no re-import will occur."
    }

    $completionMarker = & $wsl --distribution $state.tag --user root --exec /bin/sh -c "grep -Fx 'Source distro: $($state.sourceDistro)' /etc/wsl-migrate/last-complete"
    $migrationAlreadyCompleted = ($LASTEXITCODE -eq 0)
    if ($migrationAlreadyCompleted) {
        Write-Host "Migration from $($state.sourceDistro) already completed. Skipping a second data copy."
    } else {
        if ($alreadyRegistered) {
            $answer = Read-Host 'The distro is imported but migration is incomplete. Run or retry migration? [R/N]'
            if ($answer -notin @('R', 'r', '')) {
                Write-Host "Left $($state.tag) and the old distro unchanged. Run wsl-update again to retry."
                exit 0
            }
        }

        Write-Host "`nStarting the interactive migration from $($state.sourceDistro) into $($state.tag)."
        Write-Host 'This PowerShell window owns the update, so it remains open if migration stops the source distro.'
        & $wsl --distribution $state.tag --user root --exec /usr/local/bin/wsl-migrate $state.sourceDistro
        if ($LASTEXITCODE -ne 0) {
            throw "Migration did not finish. The new distro is registered and the old distro remains available. Retry with wsl-update."
        }
    }

    Write-Host "`nRestarting $($state.tag) and checking its core commands and default user..."
    & $wsl --terminate $state.tag
    if ($LASTEXITCODE -ne 0) {
        throw "Could not restart-check $($state.tag); start it manually with: wsl -d `"$($state.tag)`" -u root"
    }

    $healthCheck = 'test -s /etc/alpine-wsl-build && test -s /etc/wsl-migrate/last-complete && test -x /usr/local/bin/wsl-update && test -x /usr/local/bin/wsl-migrate && test -x /usr/local/sbin/wsl-start-docker && user=$(awk -F= ''/^[[:space:]]*default[[:space:]]*=/ {gsub(/[[:space:]]/, "", $2); print $2; exit}'' /etc/wsl.conf) && [ -n "$user" ] && grep -q "^$user:" /etc/passwd'
    & $wsl --distribution $state.tag --user root --exec /bin/sh -c $healthCheck
    if ($LASTEXITCODE -ne 0) {
        throw "The new distro restarted, but its post-migration health check failed. Inspect it with: wsl -d `"$($state.tag)`" -u root"
    }

    Write-Host 'Checking Docker on the new WSL kernel...'
    & $wsl --distribution $state.tag --user root --exec /usr/local/sbin/wsl-start-docker
    if ($LASTEXITCODE -eq 0) {
        & $wsl --distribution $state.tag --user root --exec docker version --format '{{.Server.Version}}'
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Docker started, but the server did not answer. Check the WSL kernel and Docker service.'
        }
    } else {
        Write-Warning 'The distro and migration checks passed, but Docker did not start on this host.'
    }

    Write-Host "`nUpdate and migration completed. Both distros remain registered."
    Write-Host "New distro: $($state.tag)"
    Write-Host "Old distro: $($state.sourceDistro)"
} catch {
    Write-Host "`nUpdate needs attention: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host 'The old distro, verified archive, and any imported new distro were retained.'
    $exitCode = 1
} finally {
    [void](Read-Host 'Press Enter to close this update window')
}

exit $exitCode
