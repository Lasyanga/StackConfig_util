#requires -Version 5.1
<#
.SYNOPSIS
    Apache, PHP 7.3 FastCGI, and MariaDB configuration utility.

.DESCRIPTION
    Provides a WPF/XAML interface for configuration only. It does not install
    Apache, PHP, mod_fcgid, or MariaDB. Each action runs outside the UI thread,
    backs up existing files before modifying them, and reports progress in the log.

    Intended paths: Apache = C:\Apache24, PHP 7.3 NTS = C:\Apache\php73,
    MariaDB = C:\MariaDB. The folders can be changed in the interface.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\StackConfig.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\StackConfig.ps1 -NoElevation
    Starts without automatically requesting elevation. Administrative rights are
    still required for service, firewall, and machine environment changes.
#>
[CmdletBinding()]
param(
    [switch]$NoElevation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Exit-StackWindow {
    try { exit }
    catch {
        try { [Environment]::Exit(0) }
        catch { }
    }
}

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
}
catch {
    [Console]::Error.WriteLine("Windows Presentation Framework could not be loaded: $($_.Exception.Message)")
    Exit-StackWindow
}

function Invoke-StackAdminRelaunch {
    [CmdletBinding()]
    param([string]$ScriptPath)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return }

    if (-not $ScriptPath -or -not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw 'Cannot request elevation because the script path is unavailable.'
    }

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile',
        '-STA',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $ScriptPath + '"'),
        '-NoElevation'
    )
    Start-Process -FilePath $powershellExe -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
    Exit-StackWindow
}

if (-not $NoElevation) {
    try { Invoke-StackAdminRelaunch -ScriptPath $PSCommandPath }
    catch {
        [System.Windows.MessageBox]::Show(
            "Administrator elevation was cancelled or failed.`n`n$($_.Exception.Message)",
            'Elevation required',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        Exit-StackWindow
    }
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    $scriptPath = $PSCommandPath
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $scriptPath + '"'), '-NoElevation'
    )
    Start-Process -FilePath $powershellExe -ArgumentList $arguments -ErrorAction Stop
    Exit-StackWindow
}

$modulePath = Join-Path $PSScriptRoot 'modules\StackConfig.psm1'
$xamlPath = Join-Path $PSScriptRoot 'StackConfig.xaml'
try {
    Import-Module $modulePath -Force -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $xamlPath -PathType Leaf)) { throw "XAML file not found: $xamlPath" }

    $xmlDocument = [xml](Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8)
    $xmlReader = New-Object System.Xml.XmlNodeReader($xmlDocument)
    try { $window = [Windows.Markup.XamlReader]::Load($xmlReader) }
    finally { $xmlReader.Close() }
}
catch {
    [System.Windows.MessageBox]::Show(
        "The utility could not start.`n`n$($_.Exception.Message)",
        'Startup error',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
    Exit-StackWindow
}

$controlNames = @(
    'txtApachePath', 'txtPhpPath', 'txtMariaDBPath', 'txtDocumentRoot', 'txtExtensions',
    'btnCheck', 'btnBackup', 'btnListBackups', 'btnRestore',
    'btnHttpd', 'btnFcgid', 'btnPhpIni',
    'btnMariaIni', 'btnMariaDataBackup', 'btnMariaInit', 'btnMariaService', 'btnMariaSecure', 'btnMariaTest',
    'btnEnvironment', 'btnApacheService', 'btnFirewall',
    'btnValidate', 'btnStart', 'btnPhpInfo',
    'btnLogPopout', 'btnLogSave', 'btnLogClear', 'btnClose', 'txtLog', 'txtStatus'
)

$UI = @{}
try {
    foreach ($name in $controlNames) {
        $control = $window.FindName($name)
        if ($null -eq $control) { throw "XAML control not found: $name" }
        $UI[$name] = $control
    }
}
catch {
    [System.Windows.MessageBox]::Show($_.Exception.Message, 'XAML control error', 'OK', 'Error') | Out-Null
    Exit-StackWindow
}

$Sync = [hashtable]::Synchronized(@{
    LogQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    Status = 'Ready - configuration only; no programs will be installed.'
})
$Script:UI = $UI
$Script:ModulePath = $modulePath
$Script:Sync = $Sync
$Script:Job = $null
$Script:LastStatus = ''
$Script:Busy = $false
$Script:LogWindow = $null
$Script:LogTextBox = $null
$Script:ActionButtons = @(
    $UI.Values | Where-Object {
        $_ -is [System.Windows.Controls.Button] -and
        $_.Name -notin @('btnLogPopout', 'btnLogSave', 'btnLogClear', 'btnClose')
    }
)

function Add-Log {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    $UI['txtLog'].AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
    $UI['txtLog'].ScrollToEnd()
}

function Close-StackLogWindow {
    [CmdletBinding()]
    param()

    if ($null -eq $Script:LogWindow) { return }
    try { $Script:LogWindow.Close() }
    catch { }
    $Script:LogWindow = $null
    $Script:LogTextBox = $null
}

function Set-Status {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)

    $UI['txtStatus'].Text = "Status: $Message"
}

function Set-Busy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][bool]$Value)

    $Script:Busy = $Value
    if ($Value) {
        [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
    }
    else {
        [System.Windows.Input.Mouse]::OverrideCursor = $null
    }

    foreach ($button in $Script:ActionButtons) {
        $button.IsEnabled = -not $Value
    }
}

function Confirm-StackAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message
    )

    [System.Windows.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    ) -eq [System.Windows.MessageBoxResult]::Yes
}

function Read-StackPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [switch]$Confirm,
        [switch]$AllowEmpty
    )

    $dialog = New-Object System.Windows.Window
    $dialog.Title = $Title
    $dialog.Width = 430
    $dialog.Height = 245
    $dialog.ResizeMode = 'NoResize'
    $dialog.WindowStartupLocation = 'CenterOwner'
    $dialog.ShowInTaskbar = $false
    $dialog.Owner = $window

    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = '18'

    $prompt = New-Object System.Windows.Controls.TextBlock
    $prompt.Text = $Message
    $prompt.Foreground = '#C7C7E2'
    $prompt.TextWrapping = 'Wrap'
    $prompt.Margin = '0,0,0,10'
    $panel.Children.Add($prompt) | Out-Null

    $passwordLabel = New-Object System.Windows.Controls.TextBlock
    $passwordLabel.Text = if ($Confirm) { 'New password' } else { 'Password' }
    $passwordLabel.Foreground = '#A7A7D0'
    $passwordLabel.Margin = '0,0,0,4'
    $panel.Children.Add($passwordLabel) | Out-Null

    $passwordBox = New-Object System.Windows.Controls.PasswordBox
    $passwordBox.MinWidth = 360
    $passwordBox.Margin = '0,0,0,8'
    $panel.Children.Add($passwordBox) | Out-Null

    $confirmBox = $null
    if ($Confirm) {
        $confirmLabel = New-Object System.Windows.Controls.TextBlock
        $confirmLabel.Text = 'Confirm new password'
        $confirmLabel.Foreground = '#A7A7D0'
        $confirmLabel.Margin = '0,0,0,4'
        $panel.Children.Add($confirmLabel) | Out-Null

        $confirmBox = New-Object System.Windows.Controls.PasswordBox
        $confirmBox.MinWidth = 360
        $confirmBox.Margin = '0,0,0,8'
        $panel.Children.Add($confirmBox) | Out-Null
    }

    $error = New-Object System.Windows.Controls.TextBlock
    $error.Foreground = '#FF8585'
    $error.FontSize = 11
    $error.Margin = '0,0,0,8'
    $error.TextWrapping = 'Wrap'
    $panel.Children.Add($error) | Out-Null

    $buttonPanel = New-Object System.Windows.Controls.StackPanel
    $buttonPanel.Orientation = 'Horizontal'
    $buttonPanel.HorizontalAlignment = 'Right'

    $state = @{ Accepted = $false }
    $okButton = New-Object System.Windows.Controls.Button
    $okButton.Content = 'OK'
    $okButton.Width = 78
    $okButton.Height = 32
    $okButton.Margin = '0,0,8,0'
    $okButton.Add_Click({
            if (-not $AllowEmpty -and [string]::IsNullOrEmpty($passwordBox.Password)) {
                $error.Text = 'Enter a password.'
                return
            }
            if ($Confirm -and $passwordBox.Password -cne $confirmBox.Password) {
                $error.Text = 'The passwords do not match.'
                return
            }
            $state.Accepted = $true
            $dialog.Close()
        }.GetNewClosure())

    $cancelButton = New-Object System.Windows.Controls.Button
    $cancelButton.Content = 'CANCEL'
    $cancelButton.Width = 78
    $cancelButton.Height = 32
    $cancelButton.Add_Click({ $dialog.Close() }.GetNewClosure())

    $buttonPanel.Children.Add($okButton) | Out-Null
    $buttonPanel.Children.Add($cancelButton) | Out-Null
    $panel.Children.Add($buttonPanel) | Out-Null
    $dialog.Content = $panel
    $dialog.ShowDialog() | Out-Null

    if (-not $state.Accepted) { return $null }
    $securePassword = $passwordBox.SecurePassword
    $securePassword.MakeReadOnly()
    $securePassword
}

function Get-StackSettings {
    [CmdletBinding()]
    param()

    $paths = @{
        ApachePath = ([string]$UI['txtApachePath'].Text).Trim()
        PhpPath = ([string]$UI['txtPhpPath'].Text).Trim()
        MariaDBPath = ([string]$UI['txtMariaDBPath'].Text).Trim()
        DocumentRoot = ([string]$UI['txtDocumentRoot'].Text).Trim()
    }
    foreach ($key in @($paths.Keys)) {
        $value = [string]$paths[$key]
        if ([string]::IsNullOrWhiteSpace($value)) { throw "$key is required." }
        if ($value -match '["\r\n]') { throw "$key cannot contain quotes or line breaks." }
        if ($value.Length -gt 3) { $paths[$key] = $value.TrimEnd([char[]]@('\', '/')) }
    }
    [pscustomobject]$paths
}

function Get-StackExtensions {
    [CmdletBinding()]
    param()

    @(
        ([string]$UI['txtExtensions'].Text) -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Start-StackWork {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Work,
        [hashtable]$Arguments = @{},
        [System.Windows.Controls.Button]$SourceButton = $null
    )

    if ($null -ne $Script:Job) {
        Add-Log 'Another configuration task is still running or finishing. Wait for it to finish.'
        return
    }

    Add-Log "Started: $Name"
    Set-Status "$Name..."
    Set-Busy $true
    if ($null -ne $SourceButton) { $SourceButton.IsEnabled = $false }

    $pipeline = [PowerShell]::Create()
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.Open()
    $pipeline.Runspace = $runspace

    $bootstrapArguments = @{
        ModulePath = $Script:ModulePath
        Sync = $Script:Sync
        WorkText = $Work.ToString()
    }
    foreach ($argument in $Arguments.GetEnumerator()) {
        $bootstrapArguments[$argument.Key] = $argument.Value
    }

    $null = $pipeline.AddScript({
            param(
                $ModulePath,
                $Sync,
                $WorkText,
                $ApachePath,
                $PhpPath,
                $MariaDBPath,
                $DocumentRoot,
                $Extensions,
                $RootPassword,
                $NewRootPassword
            )
            Import-Module -Name $ModulePath -Force -ErrorAction Stop
            $workScript = [scriptblock]::Create($WorkText)
            $workArguments = @{}
            if ($null -ne $workScript.Ast.ParamBlock) {
                foreach ($parameter in $workScript.Ast.ParamBlock.Parameters) {
                    $parameterName = $parameter.Name.VariablePath.UserPath
                    $workArguments[$parameterName] = (Get-Variable -Name $parameterName -ValueOnly)
                }
            }
            & $workScript @workArguments
        }).AddParameters($bootstrapArguments)

    try {
        $handle = $pipeline.BeginInvoke()
        $Script:Job = [pscustomobject]@{
            Name = $Name
            Pipeline = $pipeline
            Runspace = $runspace
            Handle = $handle
            Button = $SourceButton
            StartedAt = Get-Date
        }
    }
    catch {
        try { $runspace.Dispose() } catch { }
        try { $pipeline.Dispose() } catch { }
        Add-Log "Could not start '$Name': $($_.Exception.Message)"
        Set-Status 'Task could not start. See log.'
        Set-Busy $false
    }
}

# Each task receives values by name. The UI is never accessed by a worker.
$UI['btnCheck'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Prerequisite check' -SourceButton $UI['btnCheck'] -Arguments @{
                ApachePath = $settings.ApachePath; PhpPath = $settings.PhpPath; MariaDBPath = $settings.MariaDBPath
            } -Work {
                param($ApachePath, $PhpPath, $MariaDBPath)
                Test-StackPrerequisites -ApachePath $ApachePath -PhpPath $PhpPath -MariaDBPath $MariaDBPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnBackup'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Back up configuration files' -SourceButton $UI['btnBackup'] -Arguments @{
                ApachePath = $settings.ApachePath; PhpPath = $settings.PhpPath; MariaDBPath = $settings.MariaDBPath
            } -Work {
                param($ApachePath, $PhpPath, $MariaDBPath)
                Backup-StackConfigs -ApachePath $ApachePath -PhpPath $PhpPath -MariaDBPath $MariaDBPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnListBackups'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'List configuration backups' -SourceButton $UI['btnListBackups'] -Arguments @{
                ApachePath = $settings.ApachePath; PhpPath = $settings.PhpPath; MariaDBPath = $settings.MariaDBPath
            } -Work {
                param($ApachePath, $PhpPath, $MariaDBPath)
                Show-StackBackups -ApachePath $ApachePath -PhpPath $PhpPath -MariaDBPath $MariaDBPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnRestore'].Add_Click({
        try {
            if (-not (Confirm-StackAction 'Restore configuration backups' 'Restore the newest backup of each existing Apache, PHP, and MariaDB configuration file? The current files will be backed up again first.')) {
                Add-Log 'Restore cancelled.'
                return
            }
            $settings = Get-StackSettings
            Start-StackWork -Name 'Restore latest backups' -SourceButton $UI['btnRestore'] -Arguments @{
                ApachePath = $settings.ApachePath; PhpPath = $settings.PhpPath; MariaDBPath = $settings.MariaDBPath
            } -Work {
                param($ApachePath, $PhpPath, $MariaDBPath)
                Restore-StackConfigs -ApachePath $ApachePath -PhpPath $PhpPath -MariaDBPath $MariaDBPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnHttpd'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Update httpd.conf' -SourceButton $UI['btnHttpd'] -Arguments @{
                ApachePath = $settings.ApachePath; PhpPath = $settings.PhpPath; DocumentRoot = $settings.DocumentRoot
            } -Work {
                param($ApachePath, $PhpPath, $DocumentRoot)
                Set-StackHttpdConfiguration -ApachePath $ApachePath -PhpPath $PhpPath -DocumentRoot $DocumentRoot
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnFcgid'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Create mod_fcgid configuration' -SourceButton $UI['btnFcgid'] -Arguments @{
                ApachePath = $settings.ApachePath; PhpPath = $settings.PhpPath; DocumentRoot = $settings.DocumentRoot
            } -Work {
                param($ApachePath, $PhpPath, $DocumentRoot)
                Set-StackFcgidConfiguration -ApachePath $ApachePath -PhpPath $PhpPath -DocumentRoot $DocumentRoot
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnPhpIni'].Add_Click({
        try {
            $settings = Get-StackSettings
            $extensions = @(Get-StackExtensions)
            Start-StackWork -Name 'Configure php.ini' -SourceButton $UI['btnPhpIni'] -Arguments @{
                PhpPath = $settings.PhpPath; Extensions = $extensions
            } -Work {
                param($PhpPath, $Extensions)
                Set-StackPHPConfiguration -PhpPath $PhpPath -Extensions $Extensions
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnMariaIni'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Create MariaDB my.ini' -SourceButton $UI['btnMariaIni'] -Arguments @{
                MariaDBPath = $settings.MariaDBPath
            } -Work {
                param($MariaDBPath)
                Set-StackMariaConfiguration -MariaDBPath $MariaDBPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnMariaDataBackup'].Add_Click({
        try {
            if (-not (Confirm-StackAction 'Back up MariaDB data directory' 'Copy the entire MariaDB data folder to a new timestamped folder inside the MariaDB folder? A running MariaDB service is stopped and restarted automatically, and the copy can take a long time for a large database.')) {
                Add-Log 'MariaDB data backup cancelled.'
                return
            }
            $settings = Get-StackSettings
            Start-StackWork -Name 'Back up MariaDB data directory' -SourceButton $UI['btnMariaDataBackup'] -Arguments @{
                MariaDBPath = $settings.MariaDBPath
            } -Work {
                param($MariaDBPath)
                Backup-StackMariaData -MariaDBPath $MariaDBPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnMariaInit'].Add_Click({
        try {
            if (-not (Confirm-StackAction 'Initialize MariaDB' 'Initialize an empty MariaDB data directory? This is skipped if the data directory is already initialized. A temporary passwordless local root account will be created.')) {
                Add-Log 'MariaDB initialization cancelled.'
                return
            }
            $settings = Get-StackSettings
            Start-StackWork -Name 'Initialize MariaDB data directory' -SourceButton $UI['btnMariaInit'] -Arguments @{
                MariaDBPath = $settings.MariaDBPath
            } -Work {
                param($MariaDBPath)
                Initialize-StackMariaDBData -MariaDBPath $MariaDBPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnMariaService'].Add_Click({
        try {
            if (-not (Confirm-StackAction 'Install MariaDB service' 'Install MariaDB as an automatically starting Windows service? Existing services are never replaced.')) {
                Add-Log 'MariaDB service installation cancelled.'
                return
            }
            $settings = Get-StackSettings
            Start-StackWork -Name 'Install MariaDB service' -SourceButton $UI['btnMariaService'] -Arguments @{
                MariaDBPath = $settings.MariaDBPath
            } -Work {
                param($MariaDBPath)
                Install-StackMariaService -MariaDBPath $MariaDBPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnMariaSecure'].Add_Click({
        try {
            if (-not (Confirm-StackAction 'Secure local MariaDB' 'Set a new password for the temporary local root account, remove anonymous users, and remove the test database? Use this once after the data directory has been initialized.')) {
                Add-Log 'MariaDB security action cancelled.'
                return
            }
            $newRootPassword = Read-StackPassword -Title 'Set MariaDB root password' -Message 'Enter a new password for root@localhost. The initial --initialize-insecure account has no password. The value is not logged.' -Confirm
            if ($null -eq $newRootPassword) {
                Add-Log 'MariaDB security action cancelled.'
                return
            }
            $settings = Get-StackSettings
            Start-StackWork -Name 'Secure local MariaDB' -SourceButton $UI['btnMariaSecure'] -Arguments @{
                MariaDBPath = $settings.MariaDBPath; NewRootPassword = $newRootPassword
            } -Work {
                param($MariaDBPath, $NewRootPassword)
                Secure-StackMariaDB -MariaDBPath $MariaDBPath -NewRootPassword $NewRootPassword
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnMariaTest'].Add_Click({
        try {
            $currentPassword = Read-StackPassword -Title 'Test MariaDB connection' -Message 'Enter the current local root password. Leave it empty if the account still uses the temporary passwordless initialization.' -AllowEmpty
            if ($null -eq $currentPassword) {
                Add-Log 'MariaDB connection test cancelled.'
                return
            }
            $settings = Get-StackSettings
            Start-StackWork -Name 'Test local MariaDB connection' -SourceButton $UI['btnMariaTest'] -Arguments @{
                MariaDBPath = $settings.MariaDBPath; RootPassword = $currentPassword
            } -Work {
                param($MariaDBPath, $RootPassword)
                Test-StackMariaConnection -MariaDBPath $MariaDBPath -RootPassword $RootPassword
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnEnvironment'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Set machine environment variables' -SourceButton $UI['btnEnvironment'] -Arguments @{
                PhpPath = $settings.PhpPath; MariaDBPath = $settings.MariaDBPath
            } -Work {
                param($PhpPath, $MariaDBPath)
                Set-StackEnvironment -PhpPath $PhpPath -MariaDBPath $MariaDBPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnApacheService'].Add_Click({
        try {
            if (-not (Confirm-StackAction 'Install Apache service' 'Install Apache as an automatically starting Windows service? Existing Apache/httpd services are never replaced.')) {
                Add-Log 'Apache service installation cancelled.'
                return
            }
            $settings = Get-StackSettings
            Start-StackWork -Name 'Install Apache service' -SourceButton $UI['btnApacheService'] -Arguments @{
                ApachePath = $settings.ApachePath
            } -Work {
                param($ApachePath)
                Install-StackApacheService -ApachePath $ApachePath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnFirewall'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Create firewall rules' -SourceButton $UI['btnFirewall'] -Arguments @{
                ApachePath = $settings.ApachePath
            } -Work {
                param($ApachePath)
                Set-StackFirewall
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnValidate'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Validate Apache configuration' -SourceButton $UI['btnValidate'] -Arguments @{
                ApachePath = $settings.ApachePath; PhpPath = $settings.PhpPath
            } -Work {
                param($ApachePath, $PhpPath)
                Test-StackApacheConfiguration -ApachePath $ApachePath -PhpPath $PhpPath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnStart'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Start installed services' -SourceButton $UI['btnStart'] -Arguments @{
                ApachePath = $settings.ApachePath
            } -Work {
                param($ApachePath)
                Start-StackServices -ApachePath $ApachePath
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnPhpInfo'].Add_Click({
        try {
            $settings = Get-StackSettings
            Start-StackWork -Name 'Create phpinfo test page' -SourceButton $UI['btnPhpInfo'] -Arguments @{
                DocumentRoot = $settings.DocumentRoot
            } -Work {
                param($DocumentRoot)
                New-StackPHPInfoTest -DocumentRoot $DocumentRoot
            }
        }
        catch { Add-Log "ERROR: $($_.Exception.Message)"; Set-Status 'Invalid input. See log.' }
    })

$UI['btnLogClear'].Add_Click({
        $UI['txtLog'].Clear()
        $line = ''
        while ($Sync.LogQueue.TryDequeue([ref]$line)) { }
        Add-Log 'Log cleared.'
    })

$UI['btnLogSave'].Add_Click({
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Title = 'Save activity log'
        $dialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
        $dialog.DefaultExt = 'txt'
        $dialog.FileName = "StackConfig_Log_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
        if ($dialog.ShowDialog() -eq $true) {
            try {
                $pending = $Sync.LogQueue.ToArray()
                $content = $UI['txtLog'].Text
                if ($pending.Count -gt 0) { $content += [Environment]::NewLine + ($pending -join [Environment]::NewLine) }
                [System.IO.File]::WriteAllText($dialog.FileName, $content, (New-Object System.Text.UTF8Encoding($false)))
                Add-Log "Log saved: $($dialog.FileName)"
            }
            catch { Add-Log "ERROR saving log: $($_.Exception.Message)" }
        }
    })

$UI['btnLogPopout'].Add_Click({
        try {
            # never stack popouts: close a previous one first
            if ($null -ne $Script:LogWindow) {
                $Script:LogWindow.Close()
                $Script:LogWindow = $null
                $Script:LogTextBox = $null
            }

            $popup = New-Object System.Windows.Window
            $popup.Title = 'Apache / PHP / MariaDB Configuration Utility - Activity Log'
            $popup.Width = 920
            $popup.Height = 620
            $popup.Background = '#1A1A2E'
            $popup.WindowStartupLocation = 'CenterOwner'
            $popup.Owner = $window
            $popup.ShowInTaskbar = $false

            $text = New-Object System.Windows.Controls.TextBox
            $text.Background = '#0F0F1E'
            $text.Foreground = '#99DD99'
            $text.FontFamily = 'Consolas'
            $text.FontSize = 12
            $text.IsReadOnly = $true
            $text.VerticalScrollBarVisibility = 'Auto'
            $text.HorizontalScrollBarVisibility = 'Auto'
            $text.TextWrapping = 'NoWrap'
            $text.Padding = 10
            # the timer keeps this text box in sync, so start from the main log only
            $text.Text = $UI['txtLog'].Text

            $close = New-Object System.Windows.Controls.Button
            $close.Content = 'CLOSE'
            $close.Height = 34
            $close.Margin = '0,8,0,0'
            $close.Background = '#3D0000'
            $close.Foreground = '#FF8585'
            # call a function instead of closing over $popup: a script block that
            # references $popup only works while this handler is still on the stack
            $close.Add_Click({ Close-StackLogWindow })

            $popupGrid = New-Object System.Windows.Controls.Grid
            $row0 = New-Object System.Windows.Controls.RowDefinition
            $row0.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            $row1 = New-Object System.Windows.Controls.RowDefinition
            $row1.Height = [System.Windows.GridLength]::Auto
            $popupGrid.RowDefinitions.Add($row0) | Out-Null
            $popupGrid.RowDefinitions.Add($row1) | Out-Null
            [System.Windows.Controls.Grid]::SetRow($text, 0)
            [System.Windows.Controls.Grid]::SetRow($close, 1)
            $popupGrid.Children.Add($text) | Out-Null
            $popupGrid.Children.Add($close) | Out-Null
            $popup.Content = $popupGrid

            # non-modal: the utility stays usable while the log is open
            $popup.Add_Closed({
                    $Script:LogWindow = $null
                    $Script:LogTextBox = $null
                })
            $Script:LogWindow = $popup
            $Script:LogTextBox = $text
            $popup.Show()
            $popup.Activate() | Out-Null
        }
        catch {
            $Script:LogWindow = $null
            $Script:LogTextBox = $null
            Add-Log "ERROR: popout log window failed: $($_.Exception.Message)"
            Set-Status 'Popout log failed. See log.'
        }
    })

$UI['btnClose'].Add_Click({ $window.Close() })

$dispatcherTimer = New-Object System.Windows.Threading.DispatcherTimer
$dispatcherTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$dispatcherTimer.Add_Tick({
        $line = ''
        $batch = New-Object System.Text.StringBuilder
        while ($Sync.LogQueue.TryDequeue([ref]$line)) {
            [void]$batch.AppendLine($line)
        }
        if ($batch.Length -gt 0) {
            $UI['txtLog'].AppendText($batch.ToString())
            $UI['txtLog'].ScrollToEnd()
            if ($null -ne $Script:LogTextBox -and $null -ne $Script:LogWindow -and $Script:LogWindow.IsVisible) {
                $Script:LogTextBox.AppendText($batch.ToString())
                $Script:LogTextBox.ScrollToEnd()
            }
        }

        if ($Sync.Status -ne $Script:LastStatus) {
            $Script:LastStatus = $Sync.Status
            Set-Status $Sync.Status
        }

        if ($null -ne $Script:Job) {
            $job = $Script:Job
            $finished = $false
            try { $finished = $job.Handle.AsyncWaitHandle.WaitOne(0) }
            catch { $finished = $true }

            if (-not $finished -and ((Get-Date) - $job.StartedAt).TotalMinutes -gt 10) {
                try { $job.Pipeline.Stop() } catch { }
                Add-Log "ERROR: Task '$($job.Name)' exceeded 10 minutes and was stopped."
                $finished = $true
            }

            if ($finished) {
                try { [void]$job.Pipeline.EndInvoke($job.Handle) }
                catch { Add-Log "ERROR: $($_.Exception.Message)" }

                if ($job.Pipeline.HadErrors) {
                    foreach ($errorRecord in $job.Pipeline.Streams.Error) {
                        Add-Log "ERROR: $($errorRecord.ToString())"
                    }
                }

                try { $job.Pipeline.Dispose() } catch { }
                try { $job.Runspace.Dispose() } catch { }
                $Script:Job = $null
                Set-Busy $false
            }
        }
    })

$window.Add_Closing({
        param($sender, $eventArgs)
        if ($null -ne $Script:Job -and -not $Script:Job.Handle.AsyncWaitHandle.WaitOne(0)) {
            $answer = [System.Windows.MessageBox]::Show(
                'A configuration task is still running. Close the window and stop waiting for it? A file operation already in progress may still have completed.',
                'Task still running',
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
                $eventArgs.Cancel = $true
            }
        }
    })

$window.Add_Closed({
        $dispatcherTimer.Stop()
        Close-StackLogWindow
        if ($null -ne $Script:Job) {
            try { $Script:Job.Pipeline.Stop() } catch { }
            try { $Script:Job.Pipeline.Dispose() } catch { }
            try { $Script:Job.Runspace.Dispose() } catch { }
            $Script:Job = $null
        }
        [System.Windows.Input.Mouse]::OverrideCursor = $null
    })

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
# Pin the real main window. A window opened with ShowDialog() does not claim
# Application.MainWindow, so the first popout would take that role instead and
# closing it would shut the whole application down, leaving this window on screen
# but unable to open any further window.
$app.MainWindow = $window
$dispatcherTimer.Start()
Add-Log 'Configuration utility started as Administrator. No programs will be installed.'
Add-Log 'Recommended order: check files, back up, configure Apache/PHP, configure MariaDB, validate, then start services.'
$window.ShowDialog() | Out-Null
$app.Shutdown()
