#requires -Version 5.1
<#
    Background-safe configuration functions for the Apache / PHP / MariaDB utility.
    These functions do not access WPF controls. Use Write-StackEvent and
    Set-StackStatus to communicate with the UI dispatcher.
#>

Set-StrictMode -Version Latest

function Write-StackEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')][string]$Level = 'INFO'
    )

    if (-not (Test-Path Variable:\Sync)) {
        throw 'Stack configuration synchronization table is not available.'
    }

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $Sync.LogQueue.Enqueue("[$timestamp] [$Level] $Message")
}

function Set-StackStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    if (-not (Test-Path Variable:\Sync)) {
        throw 'Stack configuration synchronization table is not available.'
    }

    $Sync.Status = $Message
}

function Invoke-StackSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Work
    )

    try {
        Set-StackStatus "$Name..."
        & $Work
        Set-StackStatus "$Name completed. See log."
    }
    catch {
        Write-StackEvent -Level ERROR -Message "$Name failed: $($_.Exception.Message)"
        Set-StackStatus "$Name failed. See log."
        throw
    }
}

function Get-StackLeaf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedName
    )

    if ((Split-Path -Path $Path -Leaf) -ne $ExpectedName) {
        throw "Refusing to use '$Path': expected a file named '$ExpectedName'."
    }
    $Path
}

function Test-StackFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Write-StackText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-StackApacheFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApachePath,
        [Parameter(Mandatory)][string]$DocumentRoot
    )

    [pscustomobject]@{
        Home      = $ApachePath
        Httpd     = Join-Path $ApachePath 'bin\httpd.exe'
        HttpdConf = Join-Path $ApachePath 'conf\httpd.conf'
        FcgidSo   = Join-Path $ApachePath 'modules\mod_fcgid.so'
        FcgidConf = Join-Path $ApachePath 'conf\extra\httpd-fcgid.conf'
        DocumentRoot = $DocumentRoot
    }
}

function Get-StackPHPExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PhpPath)

    foreach ($candidate in @(
            (Join-Path $PhpPath 'php-cgi.exe'),
            (Join-Path $PhpPath 'bin\php-cgi.exe')
        )) {
        if (Test-StackFile $candidate) { return $candidate }
    }
    throw "php-cgi.exe was not found under '$PhpPath'. Install PHP 7.3 before configuring it."
}

function Get-StackPHPBuildInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PhpExecutable)

    $output = (& $PhpExecutable '-n' '-i' 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Unable to inspect the PHP CGI build (exit code $exitCode): $($output.Trim())"
    }

    $plainInfo = [regex]::Replace($output, '(?s)<[^>]+>', ' ')
    $plainInfo = [System.Net.WebUtility]::HtmlDecode($plainInfo)
    $plainInfo = [regex]::Replace($plainInfo, '\s+', ' ').Trim()
    $versionMatch = [regex]::Match($plainInfo, '\bPHP Version\s+([0-9]+(?:\.[0-9]+){1,2})\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $threadMatch = [regex]::Match($plainInfo, '\bThread Safety\s+(enabled|disabled)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $versionMatch.Success) { throw 'PHP CGI did not report a recognizable version number.' }
    if (-not $threadMatch.Success) { throw 'PHP CGI did not report whether thread safety is enabled or disabled.' }

    [pscustomobject]@{
        Executable   = $PhpExecutable
        Version      = $versionMatch.Groups[1].Value
        ThreadSafety = $threadMatch.Groups[1].Value.ToLowerInvariant()
    }
}

function Assert-StackPHPVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PhpExecutable)

    $info = Get-StackPHPBuildInfo -PhpExecutable $PhpExecutable
    if ($info.Version -notmatch '^7\.3\.') {
        throw "PHP $($info.Version) was detected at '$PhpExecutable'. This utility requires PHP 7.3."
    }

    $info
}

function Get-StackPHPModules {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PhpExecutable)

    $output = (& $PhpExecutable '-n' '-m' 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $output -notmatch '(?m)^\s*\[PHP Modules\]\s*$') {
        throw "Unable to read the PHP module list (exit code $exitCode): $($output.Trim())"
    }

    $modules = New-Object 'System.Collections.Generic.List[string]'
    $insideModules = $false
    foreach ($line in [regex]::Split($output, '\r?\n')) {
        $name = $line.Trim()
        if ($name -eq '[PHP Modules]') {
            $insideModules = $true
            continue
        }
        if ($name -eq '[Zend Modules]') { break }
        if ($insideModules -and $name) { $modules.Add($name) }
    }
    if ($modules.Count -eq 0) { throw 'PHP CGI returned an empty module list.' }

    $modules.ToArray()
}

function Get-StackPHPExtensionAliases {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ExtensionName)

    if ($ExtensionName -eq 'gd') { return @('gd', 'gd2') }
    @($ExtensionName)
}

function Remove-StackExtensionDirectives {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ExtensionName
    )

    $aliases = @(Get-StackPHPExtensionAliases -ExtensionName $ExtensionName)
    $lineBreak = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $kept = New-Object 'System.Collections.Generic.List[string]'

    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        $match = [regex]::Match($line, '^[ \t]*extension[ \t]*=[ \t]*(?<value>.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $value = $match.Groups['value'].Value
            $commentStart = $value.IndexOf(';')
            if ($commentStart -ge 0) { $value = $value.Substring(0, $commentStart) }
            $value = $value.Trim()
            if ($value.Length -ge 2 -and (
                    ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                    ($value.StartsWith("'") -and $value.EndsWith("'"))
                )) {
                $value = $value.Substring(1, $value.Length - 2).Trim()
            }

            $leaf = [regex]::Match($value, '[^\\/]+$').Value.ToLowerInvariant()
            $module = $leaf -replace '^php_', '' -replace '\.dll$', ''
            if ($aliases -contains $module) { continue }
        }
        $kept.Add($line)
    }

    $updated = [string]::Join($lineBreak, $kept)
    $hadTrailingBreak = $Text.EndsWith($lineBreak) -or $Text.EndsWith("`n")
    if ($hadTrailingBreak -and -not $updated.EndsWith($lineBreak)) { $updated += $lineBreak }
    $updated
}

function Resolve-StackPHPExtensionFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExtensionDirectory,
        [Parameter(Mandatory)][string]$ExtensionName
    )

    foreach ($alias in @(Get-StackPHPExtensionAliases -ExtensionName $ExtensionName)) {
        $candidate = Join-Path $ExtensionDirectory "php_$alias.dll"
        if (Test-StackFile $candidate) { return Get-Item -LiteralPath $candidate -ErrorAction Stop }
    }
    $null
}

function Add-StackExtensionDirective {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$ExtensionPath
    )

    $replacement = 'extension = "' + ($ExtensionPath -replace '\\', '/') + '"'
    $Text.TrimEnd() + [Environment]::NewLine + $replacement + [Environment]::NewLine
}

function Get-StackMariaPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MariaDBPath)

    $bin = Join-Path $MariaDBPath 'bin'
    $mysqld = Join-Path $bin 'mysqld.exe'
    $mysql = Join-Path $bin 'mysql.exe'
    $configCandidates = @(
        (Join-Path $MariaDBPath 'my.ini'),
        (Join-Path $MariaDBPath 'my.cnf'),
        (Join-Path $MariaDBPath 'data\my.ini'),
        (Join-Path $MariaDBPath 'data\my.cnf'),
        (Join-Path $MariaDBPath 'bin\my.ini'),
        (Join-Path $MariaDBPath 'bin\my.cnf')
    )
    $config = $null

    foreach ($candidate in $configCandidates) {
        if (Test-StackFile $candidate) {
            $config = $candidate
            break
        }
    }

    [pscustomobject]@{
        Home            = $MariaDBPath
        Mysqld          = $mysqld
        Mysql           = $mysql
        Config          = $config
        ConfigCandidates = $configCandidates
        DataDir         = Join-Path $MariaDBPath 'data'
    }
}

function Resolve-StackService {
    [CmdletBinding()]
    param([string[]]$Candidates = @(), [string[]]$Wildcards = @())

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $match = @(Get-Service -Name $candidate -ErrorAction SilentlyContinue)
        if ($match.Count -gt 0) { return $match[0] }
    }

    foreach ($pattern in $Wildcards) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $match = @(Get-Service -Name $pattern -ErrorAction SilentlyContinue)
        if ($match.Count -gt 0) { return $match[0] }
    }

    $null
}

function Backup-StackFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-StackEvent "No existing file to back up: $Path"
        return $null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $backup = "$Path.bak-$stamp-$suffix"
    Copy-Item -LiteralPath $Path -Destination $backup -Force -ErrorAction Stop
    Write-StackEvent -Level SUCCESS -Message "Backup created: $backup"
    $backup
}

function Backup-StackConfigs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApachePath,
        [Parameter(Mandatory)][string]$PhpPath,
        [Parameter(Mandatory)][string]$MariaDBPath
    )

    Invoke-StackSafe -Name 'Backing up configuration files' -Work {
        $apache = Get-StackApacheFiles -ApachePath $ApachePath -DocumentRoot (Join-Path $ApachePath 'htdocs')
        $php = Get-StackPHPExecutable -PhpPath $PhpPath
        $maria = Get-StackMariaPaths -MariaDBPath $MariaDBPath

        $files = @(
            @(
                $apache.HttpdConf,
                $apache.FcgidConf,
                (Join-Path (Split-Path $php -Parent) 'php.ini'),
                (Join-Path (Split-Path $php -Parent) 'php.ini-development')
            ) + @($maria.ConfigCandidates) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique
        )

        if ($files.Count -eq 0) {
            throw 'No existing configuration files were found to back up.'
        }

        foreach ($file in $files) { $null = Backup-StackFile $file }
        Write-StackEvent -Level SUCCESS -Message "Backed up $($files.Count) existing file(s). No files were changed."
    }
}

function Backup-StackMariaData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MariaDBPath,
        [string]$ServiceName = 'MariaDB'
    )

    Invoke-StackSafe -Name 'Backing up MariaDB data directory' -Work {
        $maria = Get-StackMariaPaths -MariaDBPath $MariaDBPath
        if (-not (Test-Path -LiteralPath $maria.DataDir -PathType Container)) {
            throw "MariaDB data directory not found: $($maria.DataDir). There is nothing to back up yet."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $maria.DataDir 'mysql') -PathType Container)) {
            Write-StackEvent "MariaDB data directory is empty or not initialized: $($maria.DataDir). Nothing to back up."
            return
        }

        foreach ($candidate in $maria.ConfigCandidates) {
            if (Test-StackFile $candidate) { $null = Backup-StackFile $candidate }
        }

        $service = Resolve-StackService -Candidates @($ServiceName) -Wildcards @("$ServiceName*", 'MySQL*')
        if ($service) {
            Write-StackEvent "MariaDB service found: $($service.Name) ($($service.Status))."
        }
        else {
            $runningProcess = @(Get-Process -Name 'mysqld' -ErrorAction SilentlyContinue)
            if ($runningProcess.Count -gt 0) {
                throw 'mysqld is running but no MariaDB service was found. Stop it manually and run this action again so data files are not copied while in use.'
            }
            Write-StackEvent 'No MariaDB service or running mysqld process was found. Data files are not locked.'
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $destination = Join-Path $MariaDBPath "data-backup-$stamp-$suffix"
        $restoreService = $false
        $stopped = $false

        try {
            if ($service -and $service.Status -ne 'Stopped') {
                $restoreService = $true
                Stop-Service -Name $service.Name -Force -ErrorAction Stop
                $stopped = $true
                Write-StackEvent "Stopped service $($service.Name) to copy a consistent data directory."
            }

            New-Item -ItemType Directory -Path $destination -Force -ErrorAction Stop | Out-Null
            $items = @(Get-ChildItem -LiteralPath $maria.DataDir -Force -ErrorAction Stop)
            foreach ($item in $items) {
                Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force -ErrorAction Stop
            }

            $infoPath = Join-Path $destination 'data-backup-info.txt'
            $info = @(
                "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                "Source: $($maria.DataDir)"
                "Service at backup time: $(if ($service) { "$($service.Name) ($($service.Status))" } else { 'not installed' })"
                'Restore: stop the MariaDB service, replace the contents of the data directory with this folder, then start the service again.'
            ) -join [Environment]::NewLine
            Write-StackText $infoPath $info

            $total = [math]::Round((Get-ChildItem -LiteralPath $destination -Recurse -Force -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum / 1MB, 1)
            Write-StackEvent -Level SUCCESS -Message "MariaDB data backup created: $destination ($total MB, $($items.Count) top-level item(s))."
            Write-StackEvent 'This is a raw file copy. Keep the original data directory until the new installation is verified.'
        }
        finally {
            if ($stopped -and $restoreService) {
                try {
                    Start-Service -Name $service.Name -ErrorAction Stop
                    Write-StackEvent -Level SUCCESS -Message "Service $($service.Name) was restarted."
                }
                catch {
                    Write-StackEvent -Level ERROR -Message "Service $($service.Name) could not be restarted automatically. Start it manually. $($_.Exception.Message)"
                }
            }
        }
    }
}

function Test-StackPrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApachePath,
        [Parameter(Mandatory)][string]$PhpPath,
        [Parameter(Mandatory)][string]$MariaDBPath
    )

    Invoke-StackSafe -Name 'Checking prerequisites' -Work {
        Write-StackEvent '--- Apache, PHP, and MariaDB prerequisites ---'
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-StackEvent -Level SUCCESS -Message 'Administrator rights: OK.'
        }
        else {
            Write-StackEvent -Level WARNING -Message 'Not running as Administrator. Service, firewall, machine environment, and some file actions will fail.'
        }

        $apache = Get-StackApacheFiles -ApachePath $ApachePath -DocumentRoot (Join-Path $ApachePath 'htdocs')
        $cgi = $null
        try { $cgi = Get-StackPHPExecutable -PhpPath $PhpPath } catch { }
        $phpHome = if ($cgi) { Split-Path -Path $cgi -Parent } else { $PhpPath }
        $checks = @(
            @{ Label = 'Apache httpd.exe'; Path = $apache.Httpd; Required = $true },
            @{ Label = 'Apache httpd.conf'; Path = $apache.HttpdConf; Required = $true },
            @{ Label = 'mod_fcgid.so'; Path = $apache.FcgidSo; Required = $true },
            @{ Label = 'PHP php-cgi.exe'; Path = $(if ($cgi) { $cgi } else { (Join-Path $PhpPath 'php-cgi.exe') }); Required = $true },
            @{ Label = 'PHP extension directory'; Path = (Join-Path $phpHome 'ext'); Required = $true },
            @{ Label = 'MariaDB mysqld.exe'; Path = (Join-Path $MariaDBPath 'bin\mysqld.exe'); Required = $true },
            @{ Label = 'MariaDB mysql.exe'; Path = (Join-Path $MariaDBPath 'bin\mysql.exe'); Required = $true }
        )

        $missing = 0
        foreach ($check in $checks) {
            if (Test-Path -LiteralPath $check.Path) {
                Write-StackEvent -Level SUCCESS -Message "OK: $($check.Label) -> $($check.Path)"
            }
            else {
                $missing++
                Write-StackEvent -Level WARNING -Message "Missing: $($check.Label) -> $($check.Path)"
            }
        }

        $phpCompatibilityErrors = 0
        if ($cgi) {
            try {
                $phpInfo = Get-StackPHPBuildInfo -PhpExecutable $cgi
                if ($phpInfo.Version -notmatch '^7\.3\.') {
                    $phpCompatibilityErrors++
                    Write-StackEvent -Level WARNING -Message "PHP $($phpInfo.Version) was detected at $($phpInfo.Executable). This utility requires PHP 7.3."
                }
                if ($phpInfo.ThreadSafety -eq 'enabled') {
                    Write-StackEvent -Level WARNING -Message "PHP $($phpInfo.Version) Thread Safe (TS) build detected. The utility will continue with the selected build."
                }
                if ($phpCompatibilityErrors -eq 0) {
                    $threadLabel = if ($phpInfo.ThreadSafety -eq 'enabled') { 'TS' } else { 'NTS' }
                    Write-StackEvent -Level SUCCESS -Message "PHP build detected: $($phpInfo.Version) $threadLabel ($($phpInfo.Executable))."
                }
            }
            catch {
                $phpCompatibilityErrors++
                Write-StackEvent -Level WARNING -Message "PHP build could not be verified: $($_.Exception.Message)"
            }
        }

        if ($missing -gt 0) {
            Write-StackEvent -Level WARNING -Message "$missing prerequisite(s) are missing. Install the programs separately; this utility only configures them."
        }
        elseif ($phpCompatibilityErrors -gt 0) {
            Write-StackEvent -Level WARNING -Message 'Expected files were found, but the PHP version requirement was not met. Use PHP 7.3 before configuring FastCGI.'
        }
        else {
            Write-StackEvent -Level SUCCESS -Message 'All expected program files were found.'
        }
    }
}

function Set-StackHttpdConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApachePath,
        [Parameter(Mandatory)][string]$PhpPath,
        [Parameter(Mandatory)][string]$DocumentRoot
    )

    Invoke-StackSafe -Name 'Updating httpd.conf' -Work {
        $apache = Get-StackApacheFiles -ApachePath $ApachePath -DocumentRoot $DocumentRoot
        if (-not (Test-StackFile $apache.HttpdConf)) { throw "Apache configuration not found: $($apache.HttpdConf)" }
        if (-not (Test-StackFile $apache.FcgidSo)) { throw "mod_fcgid is not installed: $($apache.FcgidSo)" }
        $phpCgi = Get-StackPHPExecutable -PhpPath $PhpPath
        $null = Assert-StackPHPVersion -PhpExecutable $phpCgi
        if (-not (Test-Path -LiteralPath $DocumentRoot -PathType Container)) { throw "Document root does not exist: $DocumentRoot" }

        $null = Backup-StackFile $apache.HttpdConf
        $text = Get-Content -LiteralPath $apache.HttpdConf -Raw -ErrorAction Stop
        $include = 'Include conf/extra/httpd-fcgid.conf'
        $documentRootLine = 'DocumentRoot "' + ($DocumentRoot -replace '\\', '/') + '"'
        $changed = $false

        $hasActiveFcgidModule = $text -match '(?im)^[ \t]*LoadModule[ \t]+fcgid_module[ \t]+'
        if ($hasActiveFcgidModule) {
            Write-StackEvent -Level WARNING -Message 'An active fcgid_module LoadModule directive already exists in httpd.conf; no second module load or include will be added.'
        }
        elseif ($text -match "(?im)^[ \t]*$([regex]::Escape($include))[ \t]*\r?$") {
            Write-StackEvent 'The mod_fcgid configuration include already exists.'
        }
        else {
            $text += [Environment]::NewLine + '# BEGIN Apache PHP FCGID Utility' + [Environment]::NewLine +
                $include + [Environment]::NewLine + '# END Apache PHP FCGID Utility' + [Environment]::NewLine
            $changed = $true
            Write-StackEvent "Added: $include"
        }

        if ($text -match '(?im)^[ \t]*DocumentRoot[ \t]+') {
            $existing = [regex]::Match($text, '(?im)^[ \t]*DocumentRoot[ \t]+.*$').Value.Trim()
            if ($existing -ne $documentRootLine) {
                $text = [regex]::Replace($text, '(?im)^[ \t]*DocumentRoot[ \t]+.*$', [System.Text.RegularExpressions.MatchEvaluator]{ param($match)
                        $documentRootLine
                    }, 1)
                $changed = $true
                Write-StackEvent "Updated DocumentRoot to: $DocumentRoot"
            }
        }
        else {
            $text += [Environment]::NewLine + $documentRootLine + [Environment]::NewLine
            $changed = $true
            Write-StackEvent "Added: $documentRootLine"
        }

        if ($changed) { Write-StackText $apache.HttpdConf $text }
        Write-StackEvent -Level SUCCESS -Message "httpd.conf is ready. Run 'Test Apache config' before restarting the service."
    }
}

function Set-StackFcgidConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApachePath,
        [Parameter(Mandatory)][string]$PhpPath,
        [Parameter(Mandatory)][string]$DocumentRoot
    )

    Invoke-StackSafe -Name 'Creating mod_fcgid configuration' -Work {
        $apache = Get-StackApacheFiles -ApachePath $ApachePath -DocumentRoot $DocumentRoot
        if (-not (Test-StackFile $apache.FcgidSo)) { throw "mod_fcgid is not installed: $($apache.FcgidSo)" }
        $phpCgi = Get-StackPHPExecutable -PhpPath $PhpPath
        $null = Assert-StackPHPVersion -PhpExecutable $phpCgi
        $extra = Split-Path -Path $apache.FcgidConf -Parent
        if (-not (Test-Path -LiteralPath $extra -PathType Container)) {
            New-Item -ItemType Directory -Path $extra -Force -ErrorAction Stop | Out-Null
        }

        $null = Backup-StackFile $apache.FcgidConf
        $phpPathForward = $PhpPath -replace '\\', '/'
        $phpCgiForward = $phpCgi -replace '\\', '/'
        $documentRootForward = $DocumentRoot -replace '\\', '/'
        $windows = ($env:SystemRoot -replace '\\', '/')
        $tempPath = "$windows/TEMP"
        $windowsPath = "$windows/system32;$windows;$windows/System32/Wbem"

        $text = @"
# BEGIN Apache PHP FCGID Utility
# Generated for PHP 7.3 through mod_fcgid. Edit with care; backup before changing.
LoadModule fcgid_module modules/mod_fcgid.so

<IfModule fcgid_module>
    FcgidWrapper "$phpCgiForward" .php
    FcgidInitialEnv PHPRC "$phpPathForward"
    FcgidInitialEnv PATH "$phpPathForward;$windowsPath"
    FcgidInitialEnv SystemRoot "$windows"
    FcgidInitialEnv SystemDrive "C:"
    FcgidInitialEnv TEMP "$tempPath"
    FcgidInitialEnv TMP "$tempPath"
    FcgidInitialEnv windir "$windows"

    FcgidMaxProcesses 15
    FcgidMaxRequestsPerProcess 1000
    FcgidProcessLifeTime 3600
    FcgidIOTimeout 60
    FcgidConnectTimeout 10
    FcgidOutputBufferSize 65536
    FcgidMaxRequestLen 67108864
    FcgidBusyTimeout 300
    FcgidBusyScanInterval 120
    FcgidFixPathinfo 1

    <FilesMatch "\.php$">
        Options +ExecCGI
        SetHandler fcgid-script
    </FilesMatch>

    <Directory "$documentRootForward">
        Options +ExecCGI
        Require all granted
    </Directory>
</IfModule>
# END Apache PHP FCGID Utility
"@
        Write-StackText $apache.FcgidConf $text
        Write-StackEvent -Level SUCCESS -Message "Created: $($apache.FcgidConf)"
        Write-StackEvent 'The PHP wrapper mapping and environment are in this file, not duplicated in httpd.conf.'
    }
}

function Set-StackIniDirective {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $pattern = '(?m)^[ \t]*;?[ \t]*' + [regex]::Escape($Name) + '[ \t]*=.*$'
    $replacement = "$Name = $Value"
    $regex = [regex]::new($pattern)
    $updated = $regex.Replace($Text, $replacement, 1)
    if ($updated -eq $Text) {
        return $Text.TrimEnd() + [Environment]::NewLine + $replacement + [Environment]::NewLine
    }
    $updated
}

function Test-StackPHPStartup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PhpExecutable,
        [Parameter(Mandatory)][string]$ConfigText,
        [Parameter(Mandatory)][string]$WorkingDirectory
    )

    $temp = Join-Path $WorkingDirectory ('.stack-php-check-' + [guid]::NewGuid().ToString('N') + '.ini')
    try {
        Write-StackText $temp $ConfigText
        $output = (& $PhpExecutable '-n' '-c' $temp '-m' 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        $hasStartupFailure = $output -match '(?im)PHP (Warning|Fatal|Parse|Startup)|Failed loading|Unable to load|cannot load'
        if ($exitCode -ne 0 -or $output -notmatch '(?m)^\s*\[PHP Modules\]\s*$' -or $hasStartupFailure) {
            throw "PHP could not load the proposed php.ini. Check extension dependencies. Output: $($output.Trim())"
        }
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Set-StackPHPConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PhpPath,
        [string[]]$Extensions = @('mysqli', 'pdo_mysql', 'mbstring', 'curl', 'gd', 'zip')
    )

    Invoke-StackSafe -Name 'Configuring php.ini for FastCGI' -Work {
        $php = Get-StackPHPExecutable -PhpPath $PhpPath
        $null = Assert-StackPHPVersion -PhpExecutable $php
        $builtInModules = @(Get-StackPHPModules -PhpExecutable $php)
        $phpHome = Split-Path -Path $php -Parent
        $ini = Get-StackLeaf -Path (Join-Path $phpHome 'php.ini') -ExpectedName 'php.ini'

        if (-not (Test-StackFile $ini)) {
            $template = Join-Path $phpHome 'php.ini-development'
            if (-not (Test-StackFile $template)) { $template = Join-Path $phpHome 'php.ini-production' }
            if (-not (Test-StackFile $template)) { throw "No php.ini, php.ini-development, or php.ini-production found in $phpHome." }
            $null = Backup-StackFile $template
            Copy-Item -LiteralPath $template -Destination $ini -Force -ErrorAction Stop
            Write-StackEvent "Created php.ini from: $template"
        }
        $null = Backup-StackFile $ini
        $text = Get-Content -LiteralPath $ini -Raw -ErrorAction Stop
        $extDir = Join-Path $phpHome 'ext'
        $extDirForward = $extDir -replace '\\', '/'

        $settings = [ordered]@{
            'cgi.force_redirect' = '0'
            'cgi.fix_pathinfo' = '1'
            'fastcgi.impersonate' = '1'
            'cgi.rfc2616_headers' = '1'
            'extension_dir' = "`"$extDirForward`""
            'date.timezone' = '"UTC"'
            'memory_limit' = '256M'
            'max_execution_time' = '300'
            'post_max_size' = '64M'
            'upload_max_filesize' = '64M'
        }
        foreach ($entry in $settings.GetEnumerator()) {
            $text = Set-StackIniDirective -Text $text -Name $entry.Key -Value $entry.Value
        }

        if (Test-Path -LiteralPath $extDir -PathType Container) {
            foreach ($extension in ($Extensions | Select-Object -Unique)) {
                $clean = $extension.Trim().ToLowerInvariant() -replace '^php_', '' -replace '\.dll$', ''
                if ([string]::IsNullOrWhiteSpace($clean) -or $clean -notmatch '^[a-z0-9_]+$') {
                    Write-StackEvent -Level WARNING -Message "Ignored invalid extension name: $extension"
                    continue
                }

                $text = Remove-StackExtensionDirectives -Text $text -ExtensionName $clean
                if ($builtInModules -contains $clean) {
                    Write-StackEvent "Extension is built into PHP; removed redundant directive: $clean"
                    continue
                }

                $dll = Resolve-StackPHPExtensionFile -ExtensionDirectory $extDir -ExtensionName $clean
                if (-not $dll) {
                    Write-StackEvent "Optional extension not present; skipped: $clean"
                    continue
                }

                $extensionPath = $dll.FullName -replace '\\', '/'
                $text = Add-StackExtensionDirective -Text $text -ExtensionPath $extensionPath
                Write-StackEvent "Enabled extension when available: $($dll.Name)"
            }
        }
        else {
            Write-StackEvent -Level WARNING -Message "PHP extension directory not found: $extDir"
        }

        Test-StackPHPStartup -PhpExecutable $php -ConfigText $text -WorkingDirectory $phpHome
        $existing = Get-Content -LiteralPath $ini -Raw -ErrorAction Stop
        if ($existing -ne $text) { Write-StackText $ini $text }
        Write-StackEvent -Level SUCCESS -Message "FastCGI php.ini validated and saved: $ini"
    }
}

function Set-StackEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PhpPath,
        [Parameter(Mandatory)][string]$MariaDBPath
    )

    Invoke-StackSafe -Name 'Setting machine environment variables' -Work {
        $php = Get-StackPHPExecutable -PhpPath $PhpPath
        $maria = Get-StackMariaPaths -MariaDBPath $MariaDBPath
        if (-not (Test-StackFile $maria.Mysql)) { throw "MariaDB client not found: $($maria.Mysql)" }

        [Environment]::SetEnvironmentVariable('PHPRC', $PhpPath, 'Machine')
        Write-StackEvent "Machine PHPRC set to: $PhpPath"

        $currentPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $entries = @($currentPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $phpHome = Split-Path -Path $php -Parent
        $wanted = @($phpHome, (Split-Path -Path $maria.Mysql -Parent))
        $added = @()

        foreach ($entry in $wanted) {
            if (-not ($entries | Where-Object { $_.TrimEnd([char]'\') -ieq $entry.TrimEnd([char]'\') })) {
                $entries += $entry
                $added += $entry
            }
        }

        if ($added.Count -gt 0) {
            [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'Machine')
            foreach ($entry in $added) { Write-StackEvent "Added to machine PATH: $entry" }
        }
        else {
            Write-StackEvent 'PHP and MariaDB client directories are already in the machine PATH.'
        }
        Write-StackEvent -Level SUCCESS -Message 'Environment changes apply to newly started programs; restart the utility if needed.'
    }
}

function Install-StackApacheService {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApachePath)

    Invoke-StackSafe -Name 'Installing Apache Windows service' -Work {
        $httpd = Join-Path $ApachePath 'bin\httpd.exe'
        $httpd = Get-StackLeaf -Path $httpd -ExpectedName 'httpd.exe'
        $httpdConf = Get-StackLeaf -Path (Join-Path $ApachePath 'conf\httpd.conf') -ExpectedName 'httpd.conf'
        if (-not (Test-StackFile $httpd)) { throw "Apache httpd.exe not found: $httpd" }
        if (-not (Test-StackFile $httpdConf)) { throw "httpd.conf not found: $httpdConf" }

        $existing = Resolve-StackService -Candidates @('Apache24', 'httpd') -Wildcards @('Apache24*', 'httpd*')
        if ($existing) {
            Write-StackEvent "Apache service is already installed: $($existing.Name) ($($existing.Status))"
            return
        }

        $output = (& $httpd '-k' 'install' '-n' 'Apache24' '-f' $httpdConf 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "httpd service installation failed: $output" }
        $service = Resolve-StackService -Candidates @('Apache24')
        if (-not $service) { throw 'httpd reported success, but the Apache24 service was not found.' }
        Set-Service -Name $service.Name -StartupType Automatic -ErrorAction Stop
        Write-StackEvent -Level SUCCESS -Message "Installed Apache service: $($service.Name) (Automatic startup)."
    }
}

function Set-StackMariaConfiguration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MariaDBPath)

    Invoke-StackSafe -Name 'Creating MariaDB my.ini' -Work {
        $maria = Get-StackMariaPaths -MariaDBPath $MariaDBPath
        if (-not (Test-StackFile $maria.Mysqld)) { throw "MariaDB server executable not found: $($maria.Mysqld)" }
        if (-not (Test-Path -LiteralPath $maria.DataDir -PathType Container)) {
            New-Item -ItemType Directory -Path $maria.DataDir -Force -ErrorAction Stop | Out-Null
            Write-StackEvent "Created data directory: $($maria.DataDir)"
        }

        $config = Join-Path $MariaDBPath 'my.ini'
        foreach ($candidate in $maria.ConfigCandidates) {
            if ($candidate -eq $config) { continue }
            if (Test-StackFile $candidate) { $null = Backup-StackFile $candidate }
        }
        $null = Backup-StackFile $config
        $base = $MariaDBPath -replace '\\', '/'
        $data = $maria.DataDir -replace '\\', '/'
        $temp = (($env:SystemRoot -replace '\\', '/') + '/TEMP')

        $text = @"
; MariaDB configuration generated by Apache PHP FCGID Configuration Utility.
; MariaDB listens on the local machine only. Use a dedicated application account;
; do not expose root or port 3306 to the Internet.
[client]
port = 3306
default-character-set = utf8mb4

[mysqld]
basedir = "$base"
datadir = "$data"
port = 3306
bind-address = 127.0.0.1
tmpdir = "$temp"
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
innodb_log_buffer_size = 64M
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1
innodb_read_io_threads = 4
innodb_write_io_threads = 4

max_connections = 200
max_connect_errors = 100000
connect_timeout = 10
wait_timeout = 28800
interactive_timeout = 28800

log_error = "$data/error.log"
slow_query_log = 1
slow_query_log_file = "$data/slow.log"
long_query_time = 2
log_queries_not_using_indexes = 1
log_bin = "$data/binlog"
binlog_format = ROW
expire_logs_days = 7
max_binlog_size = 100M

local_infile = 0
sql_mode = "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION"
table_open_cache = 2000
thread_cache_size = 50
sort_buffer_size = 4M
read_buffer_size = 2M
read_rnd_buffer_size = 8M
join_buffer_size = 4M
"@
        Write-StackText $config $text
        Write-StackEvent -Level SUCCESS -Message "Created: $config"
        Write-StackEvent 'MariaDB is bound to 127.0.0.1. The firewall button permits LocalSubnet only.'
    }
}

function Initialize-StackMariaDBData {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MariaDBPath)

    Invoke-StackSafe -Name 'Initializing MariaDB data directory' -Work {
        $maria = Get-StackMariaPaths -MariaDBPath $MariaDBPath
        if (-not (Test-StackFile $maria.Mysqld)) { throw "MariaDB server executable not found: $($maria.Mysqld)" }
        if (-not (Test-StackFile $maria.Config)) { throw "Create my.ini first. Expected a configuration in $MariaDBPath." }
        if (Test-Path -LiteralPath (Join-Path $maria.DataDir 'mysql') -PathType Container) {
            Write-StackEvent 'MariaDB data directory is already initialized. Nothing was changed.'
            return
        }

        New-Item -ItemType Directory -Path $maria.DataDir -Force -ErrorAction Stop | Out-Null
        $defaults = $maria.Config -replace '\\', '/'
        Write-StackEvent 'Creating a temporary passwordless local root account. Set a password immediately after the first start.'
        $output = (& $maria.Mysqld "--defaults-file=$defaults" '--initialize-insecure' 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "MariaDB data initialization failed: $output" }
        if (-not (Test-Path -LiteralPath (Join-Path $maria.DataDir 'mysql') -PathType Container)) {
            throw "MariaDB initialization returned success but no data directory was created at $($maria.DataDir)."
        }
        Write-StackEvent -Level SUCCESS -Message 'MariaDB data directory initialized.'
    }
}

function Install-StackMariaService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MariaDBPath,
        [string]$ServiceName = 'MariaDB'
    )

    Invoke-StackSafe -Name 'Installing MariaDB Windows service' -Work {
        $maria = Get-StackMariaPaths -MariaDBPath $MariaDBPath
        if (-not (Test-StackFile $maria.Mysqld)) { throw "MariaDB server executable not found: $($maria.Mysqld)" }
        if (-not (Test-StackFile $maria.Config)) { throw "Create my.ini first. Expected a configuration in $MariaDBPath." }
        $mysqld = Get-StackLeaf -Path $maria.Mysqld -ExpectedName 'mysqld.exe'
        $existing = Resolve-StackService -Candidates @($ServiceName) -Wildcards @("$ServiceName*")
        if ($existing) {
            Write-StackEvent "MariaDB service is already installed: $($existing.Name) ($($existing.Status)). It was not replaced."
            return
        }

        $defaults = $maria.Config -replace '\\', '/'
        $output = (& $mysqld '--install' $ServiceName "--defaults-file=$defaults" 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "MariaDB service installation failed: $output" }
        $service = Resolve-StackService -Candidates @($ServiceName)
        if (-not $service) { throw "mysqld reported success, but service '$ServiceName' was not found." }
        Set-Service -Name $service.Name -StartupType Automatic -ErrorAction Stop
        Write-StackEvent -Level SUCCESS -Message "Installed MariaDB service: $($service.Name) (Automatic startup)."
    }
}

function ConvertFrom-StackSecureString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)

    $pointer = [IntPtr]::Zero
    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }
    }
}

function Get-StackMariaSQL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MariaDBPath,
        [Security.SecureString]$RootPassword
    )

    $maria = Get-StackMariaPaths -MariaDBPath $MariaDBPath
    if (-not (Test-StackFile $maria.Mysql)) { throw "MariaDB client not found: $($maria.Mysql)" }

    $extraArguments = @()
    $temporaryConfig = $null
    if ($null -ne $RootPassword) {
        $temporaryConfig = Join-Path ([IO.Path]::GetTempPath()) ('.stack-mysql-' + [guid]::NewGuid().ToString('N') + '.cnf')
        $plainPassword = ConvertFrom-StackSecureString $RootPassword
        if ($plainPassword -match "[`r`n`0]") { throw 'The MariaDB root password cannot contain a newline or null character.' }
        $optionPassword = $plainPassword.Replace('\', '\\').Replace('"', '\"')

        try {
            Write-StackText $temporaryConfig ("[client]`r`nuser=root`r`npassword=""$optionPassword""`r`nprotocol=TCP`r`nhost=127.0.0.1`r`nport=3306`r`n")
            $acl = New-Object System.Security.AccessControl.FileSecurity
            $acl.SetAccessRuleProtection($true, $false)
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $temporaryConfig -AclObject $acl -ErrorAction Stop
            $extraArguments = @("--defaults-extra-file=$temporaryConfig")
        }
        catch {
            Remove-Item -LiteralPath $temporaryConfig -Force -ErrorAction SilentlyContinue
            throw "Could not create a protected temporary MariaDB option file: $($_.Exception.Message)"
        }
    }

    @($maria.Mysql) + $extraArguments + @('-u', 'root', '--protocol=TCP', '--host=127.0.0.1', '--port=3306', '--batch', '--skip-column-names')
}

function Invoke-StackMariaSQL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MariaDBPath,
        [Parameter(Mandatory)][string]$Query,
        [Security.SecureString]$RootPassword
    )

    $arguments = @(Get-StackMariaSQL -MariaDBPath $MariaDBPath -RootPassword $RootPassword)
    $temporaryConfig = $arguments | Where-Object { $_ -like '--defaults-extra-file=*' } | Select-Object -First 1
    try {
        $output = (& $arguments[0] $arguments[1..($arguments.Count - 1)] '-e' $Query 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "MariaDB command failed: $output" }
        $output
    }
    finally {
        if ($temporaryConfig) {
            $temporaryPath = $temporaryConfig.Substring('--defaults-extra-file='.Length)
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Secure-StackMariaDB {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MariaDBPath,
        [Parameter(Mandatory)][Security.SecureString]$NewRootPassword
    )

    Invoke-StackSafe -Name 'Securing local MariaDB installation' -Work {
        $password = ConvertFrom-StackSecureString $NewRootPassword
        if ([string]::IsNullOrEmpty($password)) { throw 'The root password cannot be empty.' }
        if ($password -match "[`r`n`0]") { throw 'The MariaDB root password cannot contain a newline or null character.' }
        $sqlPassword = $password.Replace('\', '\\').Replace("'", "''")
        $query = "ALTER USER 'root'@'localhost' IDENTIFIED BY '$sqlPassword'; DELETE FROM mysql.user WHERE User = ''; DELETE FROM mysql.db WHERE Db = 'test' OR Db LIKE 'test\_%'; DROP DATABASE IF EXISTS test; FLUSH PRIVILEGES;"
        # The initial --initialize-insecure account has no password. This
        # action is intentionally for that first local setup pass.
        $null = Invoke-StackMariaSQL -MariaDBPath $MariaDBPath -Query $query
        Write-StackEvent -Level SUCCESS -Message 'Set the local root password, removed anonymous users, and removed the test database.'
        Write-StackEvent 'The new password was not logged. Use the connection test button to verify it.'
    }
}

function Test-StackMariaConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MariaDBPath,
        [Security.SecureString]$RootPassword
    )

    Invoke-StackSafe -Name 'Testing local MariaDB connection' -Work {
        $parameters = @{ MariaDBPath = $MariaDBPath; Query = 'SELECT VERSION();' }
        if ($null -ne $RootPassword) { $parameters['RootPassword'] = $RootPassword }
        $version = Invoke-StackMariaSQL @parameters
        if ([string]::IsNullOrWhiteSpace($version)) { throw 'MariaDB returned no version information.' }
        Write-StackEvent -Level SUCCESS -Message "Local MariaDB connection OK. Version: $version"
        Write-StackEvent 'The connection was restricted to 127.0.0.1 and the password was not logged.'
    }
}

function Add-StackFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][ValidateSet('Inbound', 'Outbound')][string]$Direction,
        [Parameter(Mandatory)][int]$Port,
        [switch]$LocalSubnetOnly
    )

    if (Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue) {
        Write-StackEvent "Firewall rule already exists: $DisplayName"
        return
    }

    $parameters = @{
        DisplayName = $DisplayName
        Direction = $Direction
        Action = 'Allow'
        Protocol = 'TCP'
        LocalPort = $Port
        Profile = 'Any'
        ErrorAction = 'Stop'
    }
    if ($LocalSubnetOnly) { $parameters['RemoteAddress'] = 'LocalSubnet' }
    New-NetFirewallRule @parameters | Out-Null
    $scope = if ($LocalSubnetOnly) { 'LocalSubnet only' } else { 'Any remote address' }
    Write-StackEvent -Level SUCCESS -Message "Created firewall rule '$DisplayName' (TCP $Port, $scope)."
}

function Set-StackFirewall {
    [CmdletBinding()]
    param()

    Invoke-StackSafe -Name 'Creating firewall rules' -Work {
        Add-StackFirewallRule -DisplayName 'Apache HTTP (TCP 80)' -Direction Inbound -Port 80
        Add-StackFirewallRule -DisplayName 'Apache HTTPS (TCP 443)' -Direction Inbound -Port 443
        Add-StackFirewallRule -DisplayName 'MariaDB LocalSubnet (TCP 3306)' -Direction Inbound -Port 3306 -LocalSubnetOnly
        Write-StackEvent -Level SUCCESS -Message 'Firewall configuration complete. MariaDB is not exposed to the Internet.'
    }
}

function Test-StackApacheConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApachePath,
        [Parameter(Mandatory)][string]$PhpPath
    )

    Invoke-StackSafe -Name 'Validating Apache configuration' -Work {
        $apache = Get-StackApacheFiles -ApachePath $ApachePath -DocumentRoot (Join-Path $ApachePath 'htdocs')
        $php = Get-StackPHPExecutable -PhpPath $PhpPath
        if (-not (Test-StackFile $apache.Httpd)) { throw "Apache executable not found: $($apache.Httpd)" }
        if (-not (Test-StackFile $apache.FcgidSo)) { throw "mod_fcgid module not found: $($apache.FcgidSo)" }
        $null = $php

        $output = (& $apache.Httpd '-t' '-f' $apache.HttpdConf 2>&1 | Out-String).Trim()
        Write-StackEvent "httpd -t: $output"
        if ($LASTEXITCODE -ne 0) { throw 'Apache reported a configuration error. Review the log before starting the service.' }
        Write-StackEvent -Level SUCCESS -Message 'Apache configuration syntax is valid.'
    }
}

function Start-StackServices {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ApachePath)

    Invoke-StackSafe -Name 'Starting installed services' -Work {
        $apache = Get-StackApacheFiles -ApachePath $ApachePath -DocumentRoot (Join-Path $ApachePath 'htdocs')
        $output = (& $apache.Httpd '-t' '-f' $apache.HttpdConf 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw "Apache configuration test failed: $output" }

        $started = 0
        foreach ($definition in @(
                @{ Name = 'MariaDB'; Candidates = @('MariaDB'); Wildcards = @('MariaDB*') },
                @{ Name = 'Apache24'; Candidates = @('Apache24', 'httpd'); Wildcards = @('Apache24*', 'httpd*') }
            )) {
            $service = Resolve-StackService -Candidates $definition.Candidates -Wildcards $definition.Wildcards
            if (-not $service) {
                Write-StackEvent -Level WARNING -Message "$($definition.Name) service is not installed. Skipping."
                continue
            }
            if ($service.Status -ne 'Running') {
                Start-Service -Name $service.Name -ErrorAction Stop
                $started++
            }
            Write-StackEvent -Level SUCCESS -Message "$($definition.Name) is running (service: $($service.Name))."
        }
        Write-StackEvent -Level SUCCESS -Message "Service startup complete. Started or confirmed $started service(s)."
    }
}

function New-StackPHPInfoTest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DocumentRoot)

    Invoke-StackSafe -Name 'Creating PHP test page' -Work {
        if (-not (Test-Path -LiteralPath $DocumentRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $DocumentRoot -Force -ErrorAction Stop | Out-Null
        }
        $testFile = Get-StackLeaf -Path (Join-Path $DocumentRoot 'phpinfo.php') -ExpectedName 'phpinfo.php'
        $null = Backup-StackFile $testFile
        Write-StackText $testFile "<?php phpinfo(); ?>`r`n"
        Write-StackEvent -Level SUCCESS -Message "Created test page: $testFile"
        Write-StackEvent -Level WARNING -Message 'Remove phpinfo.php before deploying a public site; it exposes server configuration.'
    }
}

function Restore-LatestStackBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-StackEvent "No live file to restore: $Path"
        return
    }

    $parent = Split-Path -Path $Path -Parent
    $leaf = Split-Path -Path $Path -Leaf
    $latest = Get-ChildItem -LiteralPath $parent -Filter "$leaf.bak-*" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) {
        Write-StackEvent "No backups found for: $Path"
        return
    }

    $null = Backup-StackFile $Path
    Copy-Item -LiteralPath $latest.FullName -Destination $Path -Force -ErrorAction Stop
    Write-StackEvent -Level SUCCESS -Message "Restored: $($latest.FullName) -> $Path"
}

function Restore-StackConfigs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApachePath,
        [Parameter(Mandatory)][string]$PhpPath,
        [Parameter(Mandatory)][string]$MariaDBPath
    )

    Invoke-StackSafe -Name 'Restoring latest configuration backups' -Work {
        $apache = Get-StackApacheFiles -ApachePath $ApachePath -DocumentRoot (Join-Path $ApachePath 'htdocs')
        $php = Get-StackPHPExecutable -PhpPath $PhpPath
        $maria = Get-StackMariaPaths -MariaDBPath $MariaDBPath
        Restore-LatestStackBackup -Path $apache.HttpdConf
        Restore-LatestStackBackup -Path $apache.FcgidConf
        Restore-LatestStackBackup -Path (Join-Path (Split-Path $php -Parent) 'php.ini')
        foreach ($candidate in $maria.ConfigCandidates) {
            if (Test-StackFile $candidate) { Restore-LatestStackBackup -Path $candidate }
        }
        Write-StackEvent -Level SUCCESS -Message 'Latest available backups processed. Live files were backed up again before restoration.'
    }
}

function Show-StackBackups {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApachePath,
        [Parameter(Mandatory)][string]$PhpPath,
        [Parameter(Mandatory)][string]$MariaDBPath
    )

    Invoke-StackSafe -Name 'Listing configuration backups' -Work {
        $apache = Get-StackApacheFiles -ApachePath $ApachePath -DocumentRoot (Join-Path $ApachePath 'htdocs')
        $maria = Get-StackMariaPaths -MariaDBPath $MariaDBPath
        $directories = @(
            (Split-Path $apache.HttpdConf -Parent),
            (Split-Path (Get-StackPHPExecutable -PhpPath $PhpPath) -Parent),
            $MariaDBPath,
            $maria.DataDir
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique

        $backups = foreach ($directory in $directories) {
            Get-ChildItem -LiteralPath $directory -Filter '*.bak-*' -File -ErrorAction SilentlyContinue
        }
        $backups = @($backups | Sort-Object LastWriteTime -Descending)
        if ($backups.Count -eq 0) {
            Write-StackEvent 'No configuration backups were found. Use "Back up all configs" first.'
            return
        }

        Write-StackEvent "Found $($backups.Count) backup file(s):"
        foreach ($backup in $backups) { Write-StackEvent "  $($backup.FullName)" }
        Write-StackEvent 'The "Restore latest backups" button restores the newest backup of each live config file.'
        Write-StackEvent "MariaDB data directory backups are stored as folders named 'data-backup-*' in $MariaDBPath."
    }
}

Export-ModuleMember -Function @(
    'Write-StackEvent',
    'Set-StackStatus',
    'Invoke-StackSafe',
    'Backup-StackFile',
    'Backup-StackConfigs',
    'Backup-StackMariaData',
    'Test-StackPrerequisites',
    'Set-StackHttpdConfiguration',
    'Set-StackFcgidConfiguration',
    'Set-StackPHPConfiguration',
    'Set-StackEnvironment',
    'Install-StackApacheService',
    'Set-StackMariaConfiguration',
    'Initialize-StackMariaData',
    'Install-StackMariaService',
    'Secure-StackMariaDB',
    'Test-StackMariaConnection',
    'Set-StackFirewall',
    'Test-StackApacheConfiguration',
    'Start-StackServices',
    'New-StackPHPInfoTest',
    'Restore-StackConfigs',
    'Show-StackBackups'
)
