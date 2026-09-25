# Apache / PHP 7.3 / MariaDB Configuration Utility

A click-driven Windows PowerShell 5.1 + WPF/XAML utility for post-installation configuration.

## Install and run

The repository must be public. From Windows PowerShell or PowerShell 7:

```powershell
irm https://raw.githubusercontent.com/Lasyanga/StackConfig_util/main/install.ps1 | iex
```

`irm ... | iex` downloads and immediately runs `install.ps1`. The installer downloads
the latest `StackConfig.zip` from the GitHub releases of this repository, extracts it,
checks that every runtime file is present, and starts `StackConfig.ps1` in Windows
PowerShell 5.1 as Administrator. Accept the Windows UAC prompt when it appears.

A Bitly short link can replace the raw GitHub URL, for example:

```powershell
irm https://bit.ly/your-short-code | iex
```

Only use a shortened link that you created and trust, because `iex` runs whatever the
link returns.

To review the bootstrap script before running it:

```powershell
$installer = Join-Path $env:TEMP 'StackConfig-install.ps1'
irm https://raw.githubusercontent.com/Lasyanga/StackConfig_util/main/install.ps1 -OutFile $installer
notepad $installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
Remove-Item $installer
```

The utility is Windows-only. It asks for elevation, so service, firewall, and machine
environment actions work as intended.

## Run from a local clone

```powershell
powershell -ExecutionPolicy Bypass -File .\StackConfig.ps1
```

The utility requests elevation automatically. To inspect the UI without elevation, use:

```powershell
powershell -ExecutionPolicy Bypass -File .\StackConfig.ps1 -NoElevation
```

Administrative rights are still required for Windows services, firewall rules, machine environment variables, and some protected paths.

## Default paths

- Apache: `C:\Apache24`
- PHP 7.3: `C:\Apache\php73` (the selected NTS or TS build is detected and reported)
- MariaDB: `C:\MariaDB`
- Apache document root: `C:\Apache24\htdocs`

All paths can be changed in the window.

## Recommended button order

1. **Check installed files**
2. **Back up all configuration files** (includes `my.ini` / `my.cnf` found in the MariaDB folder, `data`, and `bin`)
3. **Back up MariaDB data directory** (skip if the data directory is empty or not initialized yet)
4. **Update httpd.conf**
5. **Create mod_fcgid configuration**
6. **Configure php.ini for PHP 7.3 FastCGI**
7. **Create MariaDB my.ini**
8. **Initialize MariaDB data directory**
9. **Install MariaDB Windows service**
10. **Install Apache Windows service**
11. **Create firewall rules**
12. **Validate Apache configuration (`httpd -t`)**
13. **Start installed services**
14. **Set root password and clean up MariaDB**
15. **Test local MariaDB connection**
16. **Create `phpinfo.php` test page** (remove it before deployment)

The MariaDB security action is intended for the first local setup pass after `--initialize-insecure`. It prompts for a new masked password, uses a short-lived protected option file for connection tests, removes anonymous users and the test database, and never writes the password to the activity log.

## Safety behavior

- Existing configuration files are backed up as `filename.bak-yyyyMMdd-HHmmss-<id>` before modification.
- MariaDB configuration is looked up in `my.ini`, `my.cnf`, `data\my.ini`, `data\my.cnf`, `bin\my.ini`, and `bin\my.cnf`. Every existing copy is backed up before a new `my.ini` is written, and the restore button restores all of them.
- **Back up MariaDB data directory** copies the whole `data` folder to `C:\MariaDB\data-backup-yyyyMMdd-HHmmss-<id>`. A running MariaDB service is stopped and restarted automatically; if `mysqld` runs without a service the action refuses to copy and asks you to stop it first. A `data-backup-info.txt` file records the source path and the service state. This is a raw file copy, not a logical dump.
- The restore button restores the newest backup of each live configuration file and backs up the current file first.
- Apache, PHP, mod_fcgid, and MariaDB binaries are not installed by this utility.
- PHP configuration requires PHP 7.3. The utility reports whether the selected build is NTS or Thread Safe (TS) and allows the selected build to continue. It validates the proposed `php.ini` with a supported `php-cgi -m` command, removes conflicting extension directives, recognizes built-in extensions such as ZIP, and supports the PHP 7.3 `php_gd2.dll` GD file.
- MariaDB is configured to bind to `127.0.0.1`; its firewall rule is limited to `LocalSubnet`.
- The utility disables action buttons while background work is running and logs failures instead of silently continuing.

## Activity log popout

**Popout log** opens the activity log in a separate window. That window is not modal, so the utility stays usable while it is open, and it keeps scrolling live as new lines are written. Pressing **Popout log** again while it is open closes the old window and opens a fresh one, so popouts never stack up. The window also closes automatically when the main window is closed.
