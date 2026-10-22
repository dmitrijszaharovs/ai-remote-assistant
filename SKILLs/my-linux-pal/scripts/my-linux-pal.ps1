#Requires -Version 5.1
<#
.SYNOPSIS
    Helper wrapper for a remote Linux server (Windows version).
.DESCRIPTION
    Uses the built-in Windows OpenSSH client (ssh.exe / scp.exe).
    Connection details and the sudo password are taken from a local JSON config,
    so no secrets appear in the command line or in the process list.

    The remote command is sent as base64 and decoded on the server. This keeps
    stdin free for the sudo password and avoids all quoting problems between
    PowerShell, ssh and the remote bash.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Action = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'

# Native commands get UTF-8 on stdin (important for the sudo password).
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

$script:ConfigPath = if ($env:MY_LINUX_PAL_CONFIG) {
    $env:MY_LINUX_PAL_CONFIG
} else {
    Join-Path $env:USERPROFILE '.config\my-linux-pal\config.json'
}

function Show-Usage {
    @'
Usage:
  my-linux-pal.ps1 info                      Show basic server status
  my-linux-pal.ps1 check                     Test SSH connection and sudo access
  my-linux-pal.ps1 run   "<command>"         Run a command as the normal user
  my-linux-pal.ps1 sudo  "<command>"         Run a command as root
  my-linux-pal.ps1 put   <local> <remote>    Upload a file
  my-linux-pal.ps1 get   <remote> <local>    Download a file

Configuration file (JSON):
  %USERPROFILE%\.config\my-linux-pal\config.json
  { "host": "...", "user": "...", "port": 22, "key": "...", "sudoPass": "" }
'@
}

function Get-MyLinuxPalConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Config file not found: $($script:ConfigPath)"
    }

    $cfg = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if (-not $cfg.host) { throw "'host' is not set in $($script:ConfigPath)" }
    if (-not $cfg.user) { throw "'user' is not set in $($script:ConfigPath)" }

    # Expand %USERPROFILE% and similar variables in the key path.
    $keyPath = [Environment]::ExpandEnvironmentVariables([string]$cfg.key)
    if (-not (Test-Path -LiteralPath $keyPath)) { throw "SSH key not found: $keyPath" }

    [pscustomobject]@{
        Host     = [string]$cfg.host
        User     = [string]$cfg.user
        Port     = if ($cfg.port) { [string]$cfg.port } else { '22' }
        Key      = $keyPath
        SudoPass = [string]$cfg.sudoPass
    }
}

function Get-SshExe {
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $fallback = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }

    throw 'ssh.exe not found. Install the "OpenSSH Client" optional feature in Windows.'
}

function Get-ScpExe {
    $cmd = Get-Command scp.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $fallback = Join-Path $env:SystemRoot 'System32\OpenSSH\scp.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }

    throw 'scp.exe not found. Install the "OpenSSH Client" optional feature in Windows.'
}

function Get-SshArgs {
    param([pscustomobject]$Config)

    @(
        '-i', $Config.Key,
        '-p', $Config.Port,
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'StrictHostKeyChecking=accept-new',
        "$($Config.User)@$($Config.Host)"
    )
}

function Invoke-Remote {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$AsRoot
    )

    $cfg = Get-MyLinuxPalConfig
    $ssh = Get-SshExe

    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))

    # Single-quoted: '$$' must stay literal, it is the remote shell PID.
    $tmp = '/tmp/.my_linux_pal_cmd_$$.sh'

    $usePassword = $false
    if ($AsRoot) {
        if ($cfg.SudoPass) {
            $runner = "sudo -S -p '' bash -l $tmp"
            $usePassword = $true
        } else {
            $runner = "sudo -n bash -l $tmp"
        }
    } else {
        $runner = "bash -l $tmp"
    }

    $remote = "umask 077; echo $b64 | base64 -d > $tmp; $runner; rc=`$?; rm -f $tmp; exit `$rc"
    $sshArgs = (Get-SshArgs -Config $cfg) + @($remote)

    if ($usePassword) {
        # Password goes through stdin only.
        $cfg.SudoPass | & $ssh @sshArgs
    } else {
        & $ssh @sshArgs
    }

    return $LASTEXITCODE
}

function Invoke-Put {
    param([string]$LocalPath, [string]$RemotePath)

    $cfg = Get-MyLinuxPalConfig
    $scp = Get-ScpExe

    $scpArgs = @(
        '-i', $cfg.Key,
        '-P', $cfg.Port,
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        $LocalPath,
        "$($cfg.User)@$($cfg.Host):$RemotePath"
    )

    & $scp @scpArgs
    return $LASTEXITCODE
}

function Invoke-Get {
    param([string]$RemotePath, [string]$LocalPath)

    $cfg = Get-MyLinuxPalConfig
    $scp = Get-ScpExe

    $scpArgs = @(
        '-i', $cfg.Key,
        '-P', $cfg.Port,
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=accept-new',
        "$($cfg.User)@$($cfg.Host):$RemotePath",
        $LocalPath
    )

    & $scp @scpArgs
    return $LASTEXITCODE
}

$InfoScript = @'
echo "=== Host ==="
hostname
uname -a
echo
echo "=== Uptime / load ==="
uptime
echo
echo "=== Memory ==="
free -h
echo
echo "=== Disk ==="
df -h -x tmpfs -x devtmpfs
echo
echo "=== Top processes by memory ==="
ps -eo pid,comm,%cpu,%mem --sort=-%mem | head -n 8
'@

# ---------------------------------------------------------------- main

$exitCode = 0

switch ($Action.ToLower()) {

    'info' {
        $exitCode = Invoke-Remote -Command $InfoScript
    }

    'check' {
        Write-Host 'Checking SSH connection...'
        $exitCode = Invoke-Remote -Command 'echo "SSH OK: $(whoami)@$(hostname)"'
        if ($exitCode -eq 0) {
            Write-Host 'Checking sudo access...'
            $exitCode = Invoke-Remote -Command 'echo "SUDO OK: $(whoami)"' -AsRoot
        }
    }

    'run' {
        if (-not $Rest) { throw 'Usage: my-linux-pal.ps1 run "<command>"' }
        $exitCode = Invoke-Remote -Command ($Rest -join ' ')
    }

    'sudo' {
        if (-not $Rest) { throw 'Usage: my-linux-pal.ps1 sudo "<command>"' }
        $exitCode = Invoke-Remote -Command ($Rest -join ' ') -AsRoot
    }

    'put' {
        if ($Rest.Count -ne 2) { throw 'Usage: my-linux-pal.ps1 put <local> <remote>' }
        $exitCode = Invoke-Put -LocalPath $Rest[0] -RemotePath $Rest[1]
    }

    'get' {
        if ($Rest.Count -ne 2) { throw 'Usage: my-linux-pal.ps1 get <remote> <local>' }
        $exitCode = Invoke-Get -RemotePath $Rest[0] -LocalPath $Rest[1]
    }

    default {
        Show-Usage
    }
}

exit $exitCode
