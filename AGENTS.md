# AGENTS.md — PowerShell + XAML (WPF) Utilities

## Project Overview
PowerShell scripts with WPF/XAML UI for custom utilities. Scripts are interpreted; no build step required.

## Prerequisites
- **PowerShell 5.1+** (Windows) or **PowerShell 7+** (cross-platform)
- **.NET Framework 4.7.2+** / **.NET 6+** for WPF support
- Windows OS (WPF requires Windows)

## Running Scripts
```powershell
# Run a script directly
.\script-name.ps1

# Run with bypass execution policy (if needed)
powershell -ExecutionPolicy Bypass -File .\script-name.ps1
```

## Project Structure (suggested)
```
/src
  /scripts        # Main .ps1 entry points
  /xaml           # .xaml UI definitions
  /modules        # Reusable PowerShell modules (.psm1)
  /lib            # Shared helper functions
```

## XAML Loading Pattern
```powershell
Add-Type -AssemblyName PresentationFramework
[xml]$xaml = Get-Content '.\ui\main-window.xaml'
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
```

## Common Dependencies
- `PresentationFramework`, `PresentationCore`, `WindowsBase`, `System.Xaml`
- Load via `Add-Type -AssemblyName <name>`

## Testing
- No formal test framework standard; use `Pester` if unit testing is needed
- Manual UI testing: run script and verify visual behavior

## Conventions
- **PascalCase** for XAML element names (`x:Name="MyButton"`)
- **Verb-Noun** for PowerShell functions (`Get-Config`, `Show-MainWindow`)
- Keep XAML in separate `.xaml` files (not inline strings) for maintainability
- Use `param()` blocks for script parameters

## Gotchas
- WPF requires STA thread: `powershell -sta -File script.ps1` if threading issues arise
- Execution policy may block scripts; use `-ExecutionPolicy Bypass` or `Set-ExecutionPolicy`
- XAML parse errors often show generic messages; validate XAML in Visual Studio/Blend first
- DPI scaling issues on high-DPI displays; set `[System.Windows.Application]::Current.DpiAwareness` if needed