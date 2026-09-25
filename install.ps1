<#
.SYNOPSIS
    Downloads and starts the Apache / PHP / MariaDB configuration utility.

.DESCRIPTION
    This is the only file that "irm ... | iex" has to run. It downloads the
    latest StackConfig.zip asset from the GitHub release for this repository,
    checks that the package contains every runtime file, and starts the utility
    in Windows PowerShell 5.1 as Administrator. Temporary files are removed when
    the utility closes.

    The bootstrap script has no #requires statement on purpose: it is designed
    to be run from Windows PowerShell 5.1 or PowerShell 7, and it always starts
    the WPF utility with the Windows PowerShell 5.1 executable.

.EXAMPLE
    irm https://raw.githubusercontent.com/Lasyanga/StackConfig_util/main/install.ps1 | iex

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>

$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This utility is Windows-only because it uses WPF, Windows services, and the Windows firewall.'
}

# Older Windows PowerShell installs can still negotiate TLS 1.0 by default.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$repository = 'Lasyanga/StackConfig_util'
$packageUrl = "https://github.com/$repository/releases/latest/download/StackConfig.zip"

$baseDirectory = Join-Path $env:LOCALAPPDATA 'StackConfigUtility'
$runDirectory = Join-Path $baseDirectory ([guid]::NewGuid().ToString('N'))
$packageDirectory = Join-Path $runDirectory 'package'
$zipPath = Join-Path $runDirectory 'StackConfig.zip'

try {
    New-Item -ItemType Directory -Path $packageDirectory -Force | Out-Null

    Write-Host "Downloading the latest StackConfig package from $repository ..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $packageUrl -OutFile $zipPath
    }
    catch {
        throw "The release package could not be downloaded from $packageUrl. Publish a GitHub release that contains an asset named StackConfig.zip. Original error: $($_.Exception.Message)"
    }

    Expand-Archive -LiteralPath $zipPath -DestinationPath $packageDirectory -Force

    $applicationScript = Join-Path $packageDirectory 'StackConfig.ps1'
    $requiredFiles = @(
        $applicationScript
        (Join-Path $packageDirectory 'StackConfig.xaml')
        (Join-Path $packageDirectory 'modules\StackConfig.psm1')
    )
    foreach ($requiredFile in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "The downloaded package is incomplete. Missing: $requiredFile"
        }
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile'
        '-STA'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        ('"' + $applicationScript + '"')
        '-NoElevation'
    )

    Write-Host 'Starting the utility. Accept the Windows UAC prompt to continue.'
    try {
        $process = Start-Process -FilePath $windowsPowerShell -ArgumentList $arguments -Verb RunAs -Wait -PassThru
    }
    catch {
        throw "Administrator elevation was cancelled or failed: $($_.Exception.Message)"
    }

    if ($null -ne $process -and $null -ne $process.ExitCode -and $process.ExitCode -ne 0) {
        Write-Warning "The utility exited with code $($process.ExitCode). Review the activity log inside the utility for details."
    }
}
finally {
    if (Test-Path -LiteralPath $runDirectory) {
        Remove-Item -LiteralPath $runDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
