param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [switch]$UseWorkingTreeScripts
)

$ErrorActionPreference = 'Stop'
$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$archive = (Resolve-Path -LiteralPath $ArchivePath).Path
$runId = [Guid]::NewGuid().ToString('N')
$source = "AlpineSmokeSrc_$($runId.Substring(0, 8))"
$target = "AlpineSmokeNew_$($runId.Substring(8, 8))"
$testRoot = Join-Path $env:LOCALAPPDATA "AlpineWSL\tests\wsl-smoke-$runId"
$sourcePath = Join-Path $testRoot 'source'
$targetPath = Join-Path $testRoot 'target'
$backupPath = Join-Path $testRoot 'backups'
$registeredByTest = [System.Collections.Generic.List[string]]::new()

function Get-RegisteredDistros {
    @(& $wsl --list --quiet 2>$null | ForEach-Object { (([string]$_) -replace "`0", '').Trim() } | Where-Object { $_ })
}

function Get-DefaultDistro {
    $line = @(& $wsl --list --verbose 2>$null | ForEach-Object { ([string]$_) -replace "`0", '' } | Where-Object { $_.TrimStart().StartsWith('*') } | Select-Object -First 1)
    if ($line.Count -eq 0) { throw 'Could not identify the current default WSL distro.' }
    (([string]$line[0]).Trim() -replace '^\*\s*', '') -split '\s+' | Select-Object -First 1
}

function Send-MigrationAnswer {
    param([System.Diagnostics.Process]$Process, [string]$Answer)
    $Process.StandardInput.NewLine = "`n"
    $Process.StandardInput.WriteLine($Answer)
    $Process.StandardInput.Flush()
}

function Get-MigrationAnswer {
    param([string]$Text)
    $Text = ($Text -replace "`0", '').TrimEnd("`r")
    if ($Text -match 'Proceed\? \[y/N\]') { return 'y' }
    if ($Text -match 'type READY:') { return 'READY' }
    if ($Text -match 'type FORCE') { return 'FORCE' }
    if ($Text -match 'type LATEST') { return 'LATEST' }
    if ($Text -match 'type CONTINUE') { return 'CONTINUE' }
    if ($Text -match 'type OLD to apply') { return 'NEW' }
    if ($Text -match 'Set the new Alpine distro as WSL default\?') { return 'N' }
    return $null
}

function Invoke-MigrationWithAnswers {
    param([string]$Arguments, [int]$TimeoutMinutes = 30)

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $wsl
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    [void]$process.Start()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)

    $buffer = ''
    $character = New-Object char[] 1
    $readTask = $process.StandardOutput.ReadAsync($character, 0, 1)
    while (-not $process.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) {
            $process.Kill()
            throw "Migration exceeded the $TimeoutMinutes minute smoke-test limit."
        }
        if (-not $readTask.Wait(250)) {
            continue
        }
        if ($readTask.Result -eq 0) { break }

        $current = $character[0]
        if ($current -ne "`n") { $buffer += $current }
        $answer = Get-MigrationAnswer $buffer
        if ($answer) {
            Write-Host "Smoke-test response: $answer"
            Send-MigrationAnswer $process $answer
            $buffer = ''
        }
        if ($current -eq "`n") {
            if ($buffer) { Write-Host $buffer }
            $buffer = ''
        }
        $readTask = $process.StandardOutput.ReadAsync($character, 0, 1)
    }

    $process.WaitForExit()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    if ($stderr) { Write-Host $stderr }
    if ($process.ExitCode -ne 0) { throw "Migration exited with code $($process.ExitCode)." }
}

try {
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Archive not found: $archive" }
    $defaultBefore = Get-DefaultDistro
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

    $linuxBackup = @(& $wsl --distribution $defaultBefore --user root --exec wslpath -u $backupPath)
    if ($LASTEXITCODE -ne 0 -or $linuxBackup.Count -eq 0) { throw 'Could not translate the temporary backup path into WSL.' }
    $linuxBackup = ([string]$linuxBackup[0]).Trim()

    Write-Host "Importing disposable source distro $source..."
    & $wsl --import $source $sourcePath $archive --version 2
    if ($LASTEXITCODE -ne 0) { throw 'Could not import the disposable source distro.' }
    $registeredByTest.Add($source)

    & $wsl --distribution $source --user root --exec /bin/sh -c 'mkdir -p /home/alpine && printf "migration-smoke\n" > /home/alpine/wsl-integration-smoke.txt'
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare the source data marker.' }

    Write-Host "Importing disposable target distro $target..."
    & $wsl --import $target $targetPath $archive --version 2
    if ($LASTEXITCODE -ne 0) { throw 'Could not import the disposable target distro.' }
    $registeredByTest.Add($target)

    if ($UseWorkingTreeScripts) {
        $repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $linuxRepository = @(& $wsl --distribution $defaultBefore --user root --exec wslpath -u $repositoryRoot)
        if ($LASTEXITCODE -ne 0 -or $linuxRepository.Count -eq 0) { throw 'Could not translate the repository path into WSL.' }
        $linuxRepository = ([string]$linuxRepository[0]).Trim() -replace "`0", ''
        $linuxRepository = $linuxRepository.Replace("'", "'\''")
        $injectCommand = "mkdir -p /usr/local/lib && sed 's/\r`$//' '$linuxRepository/scripts/wsl-migrate.sh' > /usr/local/bin/wsl-migrate && sed 's/\r`$//' '$linuxRepository/scripts/wsl-update.sh' > /usr/local/bin/wsl-update && cp '$linuxRepository/scripts/wsl-update.ps1' /usr/local/lib/wsl-update.ps1 && chmod 0755 /usr/local/bin/wsl-migrate /usr/local/bin/wsl-update"
        & $wsl --distribution $target --user root --exec /bin/sh -c $injectCommand
        if ($LASTEXITCODE -ne 0) { throw 'Could not install the working-tree migration and update helpers into the disposable target.' }
    }

    Write-Host 'Running the real interactive migration with isolated test distros and an isolated backup folder...'
    $arguments = '--distribution {0} --user root --exec /usr/local/bin/wsl-migrate --backup-dir "{1}" {2}' -f $target, $linuxBackup, $source
    Invoke-MigrationWithAnswers -Arguments $arguments

    & $wsl --terminate $target
    if ($LASTEXITCODE -ne 0) { throw 'Could not terminate the disposable target for restart verification.' }
    & $wsl --distribution $target --user root --exec /bin/sh -c 'test -s /etc/alpine-wsl-build && test -s /etc/wsl-migrate/last-complete && test -s /usr/local/lib/wsl-update.ps1 && test -x /usr/local/bin/wsl-update && test -x /usr/local/bin/wsl-migrate && test -x /usr/local/sbin/wsl-start-docker && grep -Fxq migration-smoke /home/alpine/wsl-integration-smoke.txt'
    if ($LASTEXITCODE -ne 0) { throw 'The target failed the post-restart data and command checks.' }

    & $wsl --distribution $target --user root --exec /usr/local/sbin/wsl-start-docker
    if ($LASTEXITCODE -ne 0) { throw 'The Docker startup helper failed in the disposable target.' }
    & $wsl --distribution $target --user root --exec docker version --format '{{.Server.Version}}'
    if ($LASTEXITCODE -ne 0) { throw 'The Docker server did not answer in the disposable target.' }

    $defaultAfter = Get-DefaultDistro
    if ($defaultAfter -ne $defaultBefore) { throw "Smoke test changed the default WSL distro from '$defaultBefore' to '$defaultAfter'." }
    Write-Host "PASS: source data migrated, target restarted, core commands and Docker passed, and default distro stayed '$defaultBefore'." -ForegroundColor Green
} finally {
    foreach ($name in $registeredByTest) {
        if ((Get-RegisteredDistros) -contains $name) {
            & $wsl --unregister $name | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Warning "Could not unregister test distro $name." }
        }
    }

    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTestParent = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'AlpineWSL\tests'))
    if ($resolvedTestRoot.StartsWith($resolvedTestParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and $resolvedTestRoot -match 'wsl-smoke-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
