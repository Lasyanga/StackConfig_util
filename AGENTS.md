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

## Release Process

### How a change reaches users

Two independent tracks, and they can drift apart:

| Track | Source | Updated by |
|---|---|---|
| `install.ps1` bootstrap | `raw.githubusercontent.com/.../main/install.ps1` | any push to `main` |
| `StackConfig.zip` payload | `releases/latest/download/StackConfig.zip` | publishing a **GitHub Release** |
| Zip contents | the **tagged** commit | `.github/workflows/release.yml` |

Consequences:

- Pushing to `main` alone changes nothing for users. **The tag is the release switch.**
- `install.ps1` checks a required-files list (`install.ps1`, `StackConfig.xaml`, `modules/StackConfig.psm1`) against the *released* zip. Adding a runtime file to `main` before releasing it makes every `irm | iex` install fail with "The downloaded package is incomplete" until a release ships.
- The workflow only fires on `tags: v*`, and the tag must match `^v\d+\.\d+\.\d+$` or the build fails.

### Command sequence

```powershell
# 0. Preflight: tree must be clean, main in sync with origin
git status --short --branch
git tag -l --sort=-v:refname

# 1. Land the change on main (before tagging, so the commit is reachable)
git add -A
git commit -m "Describe the change"
git push origin main

# 2. Review exactly what is about to ship
git log --oneline -3
git diff v1.0.1..HEAD --stat

# 3. Annotated tag, version per semver (v1.0.2)
$version = 'v1.0.2'
git tag -a $version -m "$version - Short description"
git tag -l -n1

# 4. Push the tag -- this is the step that triggers the release
git push origin $version
```

### Verify the artifact, not just the commit

A green build does not prove the zip is correct. Always download and inspect what users will get:

```powershell
$headers = @{ 'User-Agent' = 'opencode'; 'Accept' = 'application/vnd.github+json' }

# Confirm `latest` points at the new version
$rel = Invoke-RestMethod 'https://api.github.com/repos/Lasyanga/StackConfig_util/releases/latest' -Headers $headers
Write-Host "latest = $($rel.tag_name)"

# Download and inspect the real payload
$tmp = Join-Path $env:TEMP ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/Lasyanga/StackConfig_util/releases/download/$version/StackConfig.zip" -OutFile "$tmp\StackConfig.zip"
Expand-Archive "$tmp\StackConfig.zip" "$tmp\pkg" -Force

# All three runtime files present?
Get-ChildItem "$tmp\pkg" -Recurse -File | ForEach-Object { $_.FullName.Replace("$tmp\pkg\", '') }

# Does it actually contain the change? Grep for it.
Select-String "$tmp\pkg\StackConfig.ps1", "$tmp\pkg\StackConfig.xaml" -Pattern 'the thing you changed'
Remove-Item $tmp -Recurse -Force
```

Then smoke test the real user path, which is the only test that exercises both tracks together:

```powershell
irm https://raw.githubusercontent.com/Lasyanga/StackConfig_util/main/install.ps1 | iex
```

### Release gotchas

- **Publish order beats semver.** `releases/latest` is chosen by release *creation date*, not version number. Publishing v1.0.3 and then v1.0.2 as a new release silently downgrades every user with no error. Always publish in increasing order; never re-publish an old tag.
- **Drafts and prereleases are invisible to `latest`.** Tagging `v1.1.0-rc1` is a safe way to stage an unverified build; `irm | iex` keeps serving the previous stable release.
- **Rollback order matters.** Delete the release *first* so `latest` falls back to the previous working build, then delete the tag:

```powershell
gh release delete v1.0.2 --yes   # latest falls back to v1.0.1
git push origin --delete v1.0.2
git tag -d v1.0.2
```

  Deleting only the tag leaves an orphaned release attached to a nonexistent tag. If the build failed and never published, only the tag deletion is needed.
- `gh` is not required locally; the workflow uses its own `GITHUB_TOKEN` on the runner. Tagging is enough to trigger a release, and the REST API works for verification.