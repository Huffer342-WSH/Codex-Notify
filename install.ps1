[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "CodexNotify"),
    [string]$SourceUrl = "",
    [switch]$NoConfig,
    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$programName = "codex-notify.ps1"
$defaultSourceUrl = "https://raw.githubusercontent.com/Huffer342-WSH/" +
    "Codex-Notify/refs/heads/main/codex-notify.ps1"
$installPath = Join-Path $InstallDir $programName
$launcherName = "codex-notify-activate.vbs"
$launcherPath = Join-Path $InstallDir $launcherName
$codexDir = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $HOME ".codex"
} else {
    $env:CODEX_HOME
}
$configPath = Join-Path $codexDir "config.toml"
$backupPath = $configPath + ".codex-notify.bak"
$protocolPath = "HKCU:\Software\Classes\codex-notify"

function ConvertTo-JsonString {
    param([string]$Value)

    return ConvertTo-Json -InputObject $Value -Compress
}

function Get-NotifyConfiguration {
    param([string]$ScriptPath)

    $command = @(
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $ScriptPath
    )
    $items = foreach ($item in $command) {
        ConvertTo-JsonString $item
    }
    $jsonCommand = ConvertTo-Json -InputObject $command -Compress

    return [pscustomobject]@{
        Direct = "notify = [" + ($items -join ", ") + "]"
        Nested = ConvertTo-JsonString $jsonCommand
    }
}

function Set-Utf8Text {
    param(
        [string]$Path,
        [string]$Text
    )

    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Write-NotificationDurationWarning {
    $accessibilityPath = "HKCU:\Control Panel\Accessibility"
    $settings = Get-ItemProperty -LiteralPath $accessibilityPath `
        -Name "MessageDuration" -ErrorAction SilentlyContinue
    $duration = if ($null -eq $settings) { $null } else { $settings.MessageDuration }
    if ($null -ne $duration -and [int]$duration -lt 30) {
        Write-Warning (
            "Windows currently dismisses notification banners after $duration seconds. " +
            "To keep Codex notifications visible longer, open Settings > Accessibility > " +
            "Visual effects > Dismiss notifications after this amount of time. " +
            "This global setting is not changed by the installer."
        )
    }
}

function Get-ActivationProtocolCommand {
    return '"wscript.exe" "' + $launcherPath.Replace('"', '\"') + '" "%1"'
}

function Install-ActivationLauncher {
    $content = @'
Option Explicit

Dim fileSystem, shell, scriptPath, activationUri, command
Set fileSystem = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptPath = fileSystem.BuildPath(fileSystem.GetParentFolderName(WScript.ScriptFullName), "codex-notify.ps1")
activationUri = WScript.Arguments(0)
command = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """ -ActivationUri """ & activationUri & """"

shell.Run command, 0, False
'@
    Set-Utf8Text $launcherPath ($content + [Environment]::NewLine)
}

function Update-ActivationProtocol {
    param([ValidateSet("Install", "Uninstall")][string]$Mode)

    $commandPath = Join-Path $protocolPath "shell\open\command"
    $expectedCommand = Get-ActivationProtocolCommand
    if ($Mode -eq "Uninstall") {
        if (-not (Test-Path -LiteralPath $commandPath)) {
            return $false
        }
        $currentCommand = (Get-Item -LiteralPath $commandPath).GetValue("")
        if ($currentCommand -ne $expectedCommand) {
            return $false
        }
        Remove-Item -LiteralPath $protocolPath -Recurse -Force
        return $true
    }

    if (Test-Path -LiteralPath $protocolPath) {
        $description = (Get-Item -LiteralPath $protocolPath).GetValue("")
        if ($description -and $description -ne "URL:Codex Notify") {
            throw "The codex-notify URL protocol is already owned by another application."
        }
    }

    [void](New-Item -Path $commandPath -Force)
    Set-Item -LiteralPath $protocolPath -Value "URL:Codex Notify"
    New-ItemProperty -LiteralPath $protocolPath -Name "URL Protocol" -Value "" `
        -PropertyType String -Force > $null
    Set-Item -LiteralPath $commandPath -Value $expectedCommand
    return $true
}

function Update-CodexConfig {
    param([ValidateSet("Install", "Uninstall")][string]$Mode)

    [void](New-Item -ItemType Directory -Path $codexDir -Force)
    $text = if (Test-Path -LiteralPath $configPath) {
        [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8)
    } else {
        ""
    }

    if (Test-Path -LiteralPath $configPath) {
        Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
    }

    $configuration = Get-NotifyConfiguration $installPath
    $firstTable = [regex]::Match($text, '(?m)^\s*\[')
    $topLength = if ($firstTable.Success) { $firstTable.Index } else { $text.Length }
    $top = $text.Substring(0, $topLength)
    $rest = $text.Substring($topLength)
    $notifyMatch = [regex]::Match($top, '(?m)^notify\s*=.*(?:\r?\n|$)')

    if ($notifyMatch.Success) {
        $lineWithEnding = $notifyMatch.Value
        $ending = if ($lineWithEnding.EndsWith("`r`n")) {
            "`r`n"
        } elseif ($lineWithEnding.EndsWith("`n")) {
            "`n"
        } else {
            ""
        }
        $line = $lineWithEnding.TrimEnd("`r", "`n")
        if (-not $line.TrimEnd().EndsWith("]")) {
            throw "Multi-line top-level notify configuration is not supported."
        }

        $nestedPattern = `
            '(?<remove>\s*,\s*"--previous-notify"\s*,\s*(?<value>"(?:\\.|[^"\\])*"))'
        $nestedMatch = [regex]::Match($line, $nestedPattern)

        if ($Mode -eq "Install") {
            if ($nestedMatch.Success) {
                $value = $nestedMatch.Groups["value"]
                $line = $line.Substring(0, $value.Index) +
                    $configuration.Nested +
                    $line.Substring($value.Index + $value.Length)
            } else {
                $line = $configuration.Direct
            }
        } else {
            if ($line -eq $configuration.Direct) {
                $line = ""
            } elseif ($nestedMatch.Success -and
                $nestedMatch.Groups["value"].Value -eq $configuration.Nested) {
                $remove = $nestedMatch.Groups["remove"]
                $line = $line.Remove($remove.Index, $remove.Length)
            } else {
                return $false
            }
        }

        $replacement = if ([string]::IsNullOrEmpty($line)) { "" } else { $line + $ending }
        $top = $top.Substring(0, $notifyMatch.Index) + $replacement +
            $top.Substring($notifyMatch.Index + $notifyMatch.Length)
    } elseif ($Mode -eq "Install") {
        $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        if ($top.Length -gt 0 -and -not $top.EndsWith($newline)) {
            $top += $newline
        }
        if ($top.Length -gt 0 -and -not [string]::IsNullOrWhiteSpace($top)) {
            $top += $newline
        }
        $top += $configuration.Direct + $newline
        if ($rest.Length -gt 0) {
            $top += $newline
        }
    } else {
        return $false
    }

    Set-Utf8Text $configPath ($top + $rest)
    return $true
}

if ($Uninstall) {
    $configChanged = $false
    $protocolChanged = $false
    if (-not $NoConfig) {
        $configChanged = Update-CodexConfig "Uninstall"
        $protocolChanged = Update-ActivationProtocol "Uninstall"
    }
    if (Test-Path -LiteralPath $installPath) {
        Remove-Item -LiteralPath $installPath -Force
    }
    if (Test-Path -LiteralPath $launcherPath) {
        Remove-Item -LiteralPath $launcherPath -Force
    }

    Write-Host "Removed $programName from $installPath"
    if ($configChanged) {
        Write-Host "Removed its Codex notify configuration from $configPath"
    }
    if ($protocolChanged) {
        Write-Host "Removed the codex-notify activation protocol."
    }
    Write-Host "Restart Codex to apply the change."
    exit 0
}

[void](New-Item -ItemType Directory -Path $InstallDir -Force)
$temporaryPath = $installPath + ".tmp." + $PID
try {
    if (-not [string]::IsNullOrWhiteSpace($SourceUrl)) {
        if ($SourceUrl -notmatch '^https?://') {
            throw "SourceUrl must use http:// or https://."
        }
        Invoke-WebRequest -Uri $SourceUrl -OutFile $temporaryPath -UseBasicParsing
    } else {
        $localSource = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
            ""
        } else {
            Join-Path $PSScriptRoot $programName
        }
        if (-not [string]::IsNullOrWhiteSpace($localSource) -and
            (Test-Path -LiteralPath $localSource)) {
            Copy-Item -LiteralPath $localSource -Destination $temporaryPath -Force
        } else {
            Invoke-WebRequest -Uri $defaultSourceUrl -OutFile $temporaryPath `
                -UseBasicParsing
        }
    }

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $temporaryPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        $messages = ($parseErrors | ForEach-Object { $_.Message }) -join "; "
        throw "Downloaded notification script is invalid: $messages"
    }

    Move-Item -LiteralPath $temporaryPath -Destination $installPath -Force
    Install-ActivationLauncher
} finally {
    if (Test-Path -LiteralPath $temporaryPath) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

if (-not $NoConfig) {
    [void](Update-CodexConfig "Install")
    [void](Update-ActivationProtocol "Install")
}

Write-Host "Installed $programName to $installPath"
if (-not $NoConfig) {
    Write-Host "Configured Codex notify in $configPath"
    Write-Host "Registered the codex-notify activation protocol for notification clicks."
    if (Test-Path -LiteralPath $backupPath) {
        Write-Host "Backup: $backupPath"
    }
}
Write-NotificationDurationWarning
Write-Host "Restart Codex to apply the change."
