[CmdletBinding(DefaultParameterSetName = "Notify")]
param(
    [Parameter(Position = 0, ParameterSetName = "Notify")]
    [string]$Payload,

    [Parameter(Mandatory = $true, ParameterSetName = "Serve")]
    [switch]$Serve,

    [Parameter(Mandatory = $true, ParameterSetName = "Serve")]
    [string]$NotificationData,

    [Parameter(Mandatory = $true, ParameterSetName = "Activate")]
    [string]$ActivationUri
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:QuestionPreviewLimit = 300
$script:AnswerPreviewLimit = 300
$script:SessionPreviewLimit = 40
$script:DirectoryPreviewLimit = 24
$script:TitlePreviewLimit = 72
$script:WatchSeconds = 120
$script:CodexIconSvgTemplate = @'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="{color}" fill-rule="evenodd">
  <title>Codex</title>
  <path clip-rule="evenodd" d="M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"/>
</svg>
'@

function Test-WindowsDarkTheme {
    try {
        $settings = Get-ItemProperty -LiteralPath `
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" `
            -Name "AppsUseLightTheme" -ErrorAction Stop
        return [int]$settings.AppsUseLightTheme -eq 0
    } catch {
        return $false
    }
}

function Get-NotificationIconUri {
    try {
        $darkTheme = Test-WindowsDarkTheme
        $theme = if ($darkTheme) { "dark" } else { "light" }
        $color = if ($darkTheme) { "#F7F7F8" } else { "#202123" }
        $iconDirectory = Join-Path $env:LOCALAPPDATA "CodexNotify"
        [void](New-Item -ItemType Directory -Path $iconDirectory -Force)
        $iconPath = Join-Path $iconDirectory "codex-$theme.svg"
        $content = $script:CodexIconSvgTemplate.Replace("{color}", $color) +
            [Environment]::NewLine
        $current = if (Test-Path -LiteralPath $iconPath) {
            [IO.File]::ReadAllText($iconPath, [Text.Encoding]::UTF8)
        } else {
            ""
        }
        if ($current -ne $content) {
            $encoding = New-Object Text.UTF8Encoding($false)
            [IO.File]::WriteAllText($iconPath, $content, $encoding)
        }
        return ([Uri]$iconPath).AbsoluteUri
    } catch {
        return ""
    }
}

function Convert-ToCompactText {
    param(
        [object]$Value,
        [int]$Limit
    )

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [string]) {
        $text = $Value
    } else {
        try {
            $text = $Value | ConvertTo-Json -Compress -Depth 20
        } catch {
            $text = [string]$Value
        }
    }

    $text = (($text -replace "\s+", " ").Trim())
    if ($text.Length -le $Limit) {
        return $text
    }

    return $text.Substring(0, [Math]::Max(0, $Limit - 3)).TrimEnd() + "..."
}

function Get-EventValue {
    param(
        [object]$Event,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Event.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $value = [string]$property.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return ""
}

function Get-LastInputMessage {
    param([object]$Event)

    $property = $Event.PSObject.Properties["input-messages"]
    if ($null -eq $property -or $null -eq $property.Value) {
        return Get-EventValue $Event @(
            "last-user-message",
            "user-message",
            "prompt",
            "input"
        )
    }

    $messages = @($property.Value)
    for ($index = $messages.Count - 1; $index -ge 0; $index--) {
        $message = Convert-ToCompactText $messages[$index] $script:QuestionPreviewLimit
        if (-not [string]::IsNullOrWhiteSpace($message)) {
            return $message
        }
    }

    return ""
}

function Initialize-NativeSqlite {
    if ("CodexNotify.NativeSqlite" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexNotify
{
    public static class NativeSqlite
    {
        private const int SQLITE_OK = 0;
        private const int SQLITE_ROW = 100;
        private const int SQLITE_OPEN_READONLY = 1;
        private static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);
        public static string LastError = String.Empty;

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_open_v2(
            IntPtr filename, out IntPtr database, int flags, IntPtr vfs);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr database);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_prepare_v2(
            IntPtr database, IntPtr sql, int length, out IntPtr statement,
            IntPtr tail);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_bind_text(
            IntPtr statement, int index, IntPtr value, int length,
            IntPtr destructor);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text(
            IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(
            IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);

        private static IntPtr Utf8(string value, out int length)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(value ?? String.Empty);
            length = bytes.Length;
            IntPtr pointer = Marshal.AllocHGlobal(length + 1);
            Marshal.Copy(bytes, 0, pointer, length);
            Marshal.WriteByte(pointer, length, 0);
            return pointer;
        }

        private static string ColumnText(IntPtr statement, int column)
        {
            IntPtr pointer = sqlite3_column_text(statement, column);
            if (pointer == IntPtr.Zero)
                return String.Empty;

            int length = sqlite3_column_bytes(statement, column);
            if (length <= 0)
                return String.Empty;

            byte[] bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }

        public static string[] QueryFirst(
            string databasePath, string sql, string parameter, int columns)
        {
            IntPtr database = IntPtr.Zero;
            IntPtr statement = IntPtr.Zero;
            IntPtr filename = IntPtr.Zero;
            IntPtr query = IntPtr.Zero;
            IntPtr value = IntPtr.Zero;
            try
            {
                LastError = String.Empty;
                int filenameLength;
                filename = Utf8(databasePath, out filenameLength);
                int status = sqlite3_open_v2(filename, out database,
                        SQLITE_OPEN_READONLY, IntPtr.Zero);
                if (status != SQLITE_OK)
                {
                    LastError = "sqlite3_open_v2 returned " + status;
                    return null;
                }

                int queryLength;
                query = Utf8(sql, out queryLength);
                status = sqlite3_prepare_v2(database, query, queryLength,
                        out statement, IntPtr.Zero);
                if (status != SQLITE_OK)
                {
                    LastError = "sqlite3_prepare_v2 returned " + status;
                    return null;
                }

                if (!String.IsNullOrEmpty(parameter))
                {
                    int valueLength;
                    value = Utf8(parameter, out valueLength);
                    status = sqlite3_bind_text(statement, 1, value,
                            valueLength, SQLITE_TRANSIENT);
                    if (status != SQLITE_OK)
                    {
                        LastError = "sqlite3_bind_text returned " + status;
                        return null;
                    }
                }

                status = sqlite3_step(statement);
                if (status != SQLITE_ROW)
                {
                    LastError = "sqlite3_step returned " + status;
                    return null;
                }

                var result = new List<string>();
                for (int index = 0; index < columns; index++)
                    result.Add(ColumnText(statement, index));
                return result.ToArray();
            }
            finally
            {
                if (statement != IntPtr.Zero)
                    sqlite3_finalize(statement);
                if (database != IntPtr.Zero)
                    sqlite3_close(database);
                if (value != IntPtr.Zero)
                    Marshal.FreeHGlobal(value);
                if (query != IntPtr.Zero)
                    Marshal.FreeHGlobal(query);
                if (filename != IntPtr.Zero)
                    Marshal.FreeHGlobal(filename);
            }
        }
    }
}
'@
}

function Get-VSCodeSessionName {
    param([string]$ThreadId)

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return ""
    }

    $storageRoots = @(
        (Join-Path $env:APPDATA "Code\User\workspaceStorage"),
        (Join-Path $env:APPDATA "Code - Insiders\User\workspaceStorage"),
        (Join-Path $env:APPDATA "VSCodium\User\workspaceStorage"),
        (Join-Path $env:APPDATA "Cursor\User\workspaceStorage"),
        (Join-Path $env:APPDATA "Windsurf\User\workspaceStorage")
    )

    $databases = foreach ($root in $storageRoots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Filter "state.vscdb" -File -Recurse `
                -ErrorAction SilentlyContinue
        }
    }

    foreach ($database in @($databases | Sort-Object LastWriteTimeUtc -Descending)) {
        try {
            $row = [CodexNotify.NativeSqlite]::QueryFirst(
                $database.FullName,
                "SELECT value FROM ItemTable WHERE key = 'agentSessions.model.cache'",
                $null,
                1
            )
            if ($null -eq $row -or [string]::IsNullOrWhiteSpace($row[0])) {
                continue
            }

            $sessions = $row[0] | ConvertFrom-Json
            foreach ($session in $sessions) {
                $resource = [string]$session.resource
                if ($resource.EndsWith("/$ThreadId", [StringComparison]::OrdinalIgnoreCase)) {
                    $label = Convert-ToCompactText $session.label $script:SessionPreviewLimit
                    if (-not [string]::IsNullOrWhiteSpace($label)) {
                        return $label
                    }
                }
            }
        } catch {
            continue
        }
    }

    return ""
}

function Get-CodexSessionName {
    param([string]$ThreadId)

    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return ""
    }

    $codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        Join-Path $HOME ".codex"
    } else {
        $env:CODEX_HOME
    }

    $databases = Get-ChildItem -LiteralPath $codexHome -Filter "state_*.sqlite" `
        -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending
    foreach ($database in @($databases)) {
        try {
            $row = [CodexNotify.NativeSqlite]::QueryFirst(
                $database.FullName,
                "SELECT name, title FROM threads WHERE id = ?",
                $ThreadId,
                2
            )
            if ($null -eq $row) {
                continue
            }

            foreach ($value in $row) {
                $name = Convert-ToCompactText $value $script:SessionPreviewLimit
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    return $name
                }
            }
        } catch {
            continue
        }
    }

    return ""
}

function Get-SessionName {
    param(
        [object]$Event,
        [string]$ThreadId
    )

    $payloadName = Get-EventValue $Event @(
        "conversation-title",
        "conversation-name",
        "session-title",
        "session-name",
        "thread-title",
        "title"
    )
    if (-not [string]::IsNullOrWhiteSpace($payloadName)) {
        return Convert-ToCompactText $payloadName $script:SessionPreviewLimit
    }

    try {
        Initialize-NativeSqlite
        $name = Get-VSCodeSessionName $ThreadId
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name
        }

        $name = Get-CodexSessionName $ThreadId
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            return $name
        }
    } catch {
        # A title lookup failure must not prevent the base notification.
    }

    return "Unnamed session"
}

function Get-SourceContext {
    param([string]$Cwd)

    $knownNames = @(
        "Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf",
        "Codex", "WindowsTerminal", "wezterm-gui", "alacritty", "kitty",
        "ConEmu64", "mintty", "Tabby"
    )
    $vscodeProcessId = 0
    if ([int]::TryParse($env:VSCODE_PID, [ref]$vscodeProcessId) -and
        $vscodeProcessId -gt 0) {
        try {
            $vscodeProcess = Get-Process -Id $vscodeProcessId -ErrorAction Stop
            return [pscustomobject]@{
                WindowHandle = $vscodeProcess.MainWindowHandle.ToInt64()
                ProcessId = $vscodeProcess.Id
                ProcessName = $vscodeProcess.ProcessName
                ExecutablePath = $vscodeProcess.Path
            }
        } catch {
            # Continue with parent-chain and process-name detection.
        }
    }

    $chainNames = New-Object System.Collections.Generic.List[string]
    $chainIds = New-Object System.Collections.Generic.List[int]
    $currentId = $PID
    $processTable = @{}
    try {
        foreach ($processInfo in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
            $processTable[[int]$processInfo.ProcessId] = $processInfo
        }
    } catch {
        # Candidate window matching below still works without a process tree.
    }

    for ($depth = 0; $depth -lt 20 -and $currentId -gt 0; $depth++) {
        $processInfo = $processTable[$currentId]
        if ($null -eq $processInfo) {
            break
        }
        $parentId = [int]$processInfo.ParentProcessId

        if ($parentId -le 0 -or $chainIds.Contains($parentId)) {
            break
        }

        $chainIds.Add($parentId)
        try {
            $process = Get-Process -Id $parentId -ErrorAction Stop
            $chainNames.Add($process.ProcessName)
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                return [pscustomobject]@{
                    WindowHandle = $process.MainWindowHandle.ToInt64()
                    ProcessId = $process.Id
                    ProcessName = $process.ProcessName
                    ExecutablePath = $process.Path
                }
            }
        } catch {
            # The process can exit while its parent chain is being inspected.
        }

        $currentId = $parentId
    }

    $candidateNames = @($chainNames | Where-Object { $knownNames -contains $_ })
    if ($candidateNames.Count -eq 0) {
        $candidateNames = $knownNames
    }

    $directory = ""
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
        $directory = Split-Path -Leaf $Cwd.TrimEnd([char[]]"\/")
    }

    $allCandidates = foreach ($name in @($candidateNames | Select-Object -Unique)) {
        Get-Process -Name $name -ErrorAction SilentlyContinue
    }
    $candidates = @($allCandidates | Where-Object {
        $_.MainWindowHandle -ne [IntPtr]::Zero
    })
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        $matching = @($candidates | Where-Object {
            $_.MainWindowTitle.IndexOf(
                $directory,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        })
        if ($matching.Count -gt 0) {
            $candidates = $matching
        }
    }

    $candidate = @($candidates | Select-Object -First 1)[0]
    if ($null -ne $candidate) {
        return [pscustomobject]@{
            WindowHandle = $candidate.MainWindowHandle.ToInt64()
            ProcessId = $candidate.Id
            ProcessName = $candidate.ProcessName
            ExecutablePath = $candidate.Path
        }
    }

    $fallback = @($allCandidates | Select-Object -First 1)[0]
    if ($null -ne $fallback) {
        return [pscustomobject]@{
            WindowHandle = 0
            ProcessId = $fallback.Id
            ProcessName = $fallback.ProcessName
            ExecutablePath = $fallback.Path
        }
    }

    return [pscustomobject]@{
        WindowHandle = 0
        ProcessId = 0
        ProcessName = ""
        ExecutablePath = ""
    }
}

function Start-NotificationServer {
    param([object]$Data)

    $json = $Data | ConvertTo-Json -Compress -Depth 5
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $executable = (Get-Process -Id $PID -ErrorAction Stop).Path
    $scriptPath = $PSCommandPath.Replace('"', '\"')

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass ' +
        '-File "' + $scriptPath + '" -Serve -NotificationData ' + $encoded
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -ne $process) {
        $process.StandardInput.Close()
        $process.Dispose()
    }
}

function Initialize-WindowActivator {
    if ("CodexNotify.WindowActivator" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexNotify
{
    public static class WindowActivator
    {
        [DllImport("user32.dll")]
        private static extern bool IsWindow(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool IsIconic(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool ShowWindowAsync(IntPtr window, int command);

        [DllImport("user32.dll")]
        private static extern bool SetForegroundWindow(IntPtr window);

        [DllImport("user32.dll")]
        private static extern bool BringWindowToTop(IntPtr window);

        public static bool Activate(long handle)
        {
            IntPtr window = new IntPtr(handle);
            if (window == IntPtr.Zero || !IsWindow(window))
                return false;

            if (IsIconic(window))
                ShowWindowAsync(window, 9);
            else
                ShowWindowAsync(window, 5);

            BringWindowToTop(window);
            return SetForegroundWindow(window);
        }
    }
}
'@
}

function Resolve-WindowHandle {
    param([object]$Data)

    $handle = [long]$Data.WindowHandle
    if ($handle -ne 0) {
        return $handle
    }

    $processId = [int]$Data.ProcessId
    if ($processId -gt 0) {
        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                return $process.MainWindowHandle.ToInt64()
            }
        } catch {
            # Continue with process-name and title matching.
        }
    }

    $processName = [string]$Data.ProcessName
    if ([string]::IsNullOrWhiteSpace($processName)) {
        return 0
    }

    $candidates = @(Get-Process -Name $processName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    $directory = [string]$Data.Directory
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        $matching = @($candidates | Where-Object {
            $_.MainWindowTitle.IndexOf(
                $directory,
                [StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        })
        if ($matching.Count -gt 0) {
            $candidates = $matching
        }
    }

    $candidate = @($candidates | Select-Object -First 1)[0]
    if ($null -eq $candidate) {
        return 0
    }
    return $candidate.MainWindowHandle.ToInt64()
}

function Activate-SourceWindow {
    param([object]$Data)

    $handle = Resolve-WindowHandle $Data
    if ($handle -ne 0) {
        if ([CodexNotify.WindowActivator]::Activate($handle)) {
            return
        }
    }

    $processName = [string]$Data.ProcessName
    $executablePath = [string]$Data.IconPath
    $editorNames = @("Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf")
    if ($editorNames -contains $processName -and
        -not [string]::IsNullOrWhiteSpace($executablePath) -and
        (Test-Path -LiteralPath $executablePath)) {
        try {
            Start-Process -FilePath $executablePath -ArgumentList "--reuse-window" `
                -WindowStyle Hidden
        } catch {
            # Window activation is best effort and must not break notification cleanup.
        }
    }
}

function Get-WindowsPowerShellAppId {
    try {
        $application = Get-StartApps -ErrorAction Stop | Where-Object {
            $_.Name -eq "Windows PowerShell" -and
            $_.AppID -like '*\WindowsPowerShell\v1.0\powershell.exe'
        } | Select-Object -First 1
        if ($null -ne $application -and
            -not [string]::IsNullOrWhiteSpace([string]$application.AppID)) {
            return [string]$application.AppID
        }
    } catch {
        # The StartApps cmdlet is unavailable on some older Windows builds.
    }

    return '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
}

function Get-SourceProtocolUri {
    param([object]$Data)

    if (-not (Test-Path -LiteralPath "Registry::HKEY_CLASSES_ROOT\codex-notify")) {
        return ""
    }

    $activationData = [ordered]@{
        WindowHandle = [long]$Data.WindowHandle
        ProcessId = [int]$Data.ProcessId
        ProcessName = [string]$Data.ProcessName
        IconPath = [string]$Data.IconPath
        Directory = [string]$Data.Directory
    }
    $json = $activationData | ConvertTo-Json -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $encoded = $encoded.TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "codex-notify://activate/$encoded"
}

function Get-ActivationData {
    param([string]$Uri)

    $prefix = "codex-notify://activate/"
    if ([string]::IsNullOrWhiteSpace($Uri) -or
        -not $Uri.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Invalid Codex Notify activation URI."
    }

    $encoded = $Uri.Substring($prefix.Length).Replace('-', '+').Replace('_', '/')
    switch ($encoded.Length % 4) {
        2 { $encoded += "==" }
        3 { $encoded += "=" }
        1 { throw "Invalid Codex Notify activation payload." }
    }
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
    return $json | ConvertFrom-Json
}

function Show-WinRTNotification {
    param([object]$Data)

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > $null

        $title = [Security.SecurityElement]::Escape([string]$Data.Title)
        $body = [Security.SecurityElement]::Escape([string]$Data.Body)
        $protocolUri = Get-SourceProtocolUri $Data
        $activation = ""
        if (-not [string]::IsNullOrWhiteSpace($protocolUri)) {
            $escapedUri = [Security.SecurityElement]::Escape($protocolUri)
            $activation = ' activationType="protocol" launch="' + $escapedUri + '"'
        }
        $logo = ""
        $iconUri = Get-NotificationIconUri
        if (-not [string]::IsNullOrWhiteSpace($iconUri)) {
            $escapedIconUri = [Security.SecurityElement]::Escape($iconUri)
            $logo = '<image placement="appLogoOverride" src="' +
                $escapedIconUri + '" alt="Codex"/>'
        }
        $xmlText = '<toast duration="long"' + $activation +
            '><visual><binding template="ToastGeneric">' +
            $logo + '<text>' + $title + '</text><text>' + $body +
            '</text></binding></visual></toast>'
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($xmlText)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)

        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(
            (Get-WindowsPowerShellAppId)
        )
        if (-not [string]::IsNullOrWhiteSpace($protocolUri)) {
            $notifier.Show($toast)
            return $true
        }

        $script:notificationClicked = $false
        $activatedHandler = {
            param($sender, $arguments)
            $script:notificationClicked = $true
        }
        $activatedToken = $toast.add_Activated($activatedHandler)
        try {
            $notifier.Show($toast)
            $stopwatch = [Diagnostics.Stopwatch]::StartNew()
            while ($stopwatch.Elapsed.TotalSeconds -lt $script:WatchSeconds) {
                [Windows.Forms.Application]::DoEvents()
                if ($script:notificationClicked) {
                    Activate-SourceWindow $Data
                    break
                }
                Start-Sleep -Milliseconds 50
            }
        } finally {
            $toast.remove_Activated($activatedToken)
        }
        return $true
    } catch {
        return $false
    }
}

function Show-NotifyIconNotification {
    param([object]$Data)

    $notifyIcon = New-Object Windows.Forms.NotifyIcon
    $ownedIcon = $null
    try {
        $iconPath = [string]$Data.IconPath
        if (-not [string]::IsNullOrWhiteSpace($iconPath) -and
            (Test-Path -LiteralPath $iconPath)) {
            try {
                $ownedIcon = [Drawing.Icon]::ExtractAssociatedIcon($iconPath)
            } catch {
                $ownedIcon = $null
            }
        }
        if ($null -ne $ownedIcon) {
            $notifyIcon.Icon = $ownedIcon
        } else {
            $notifyIcon.Icon = [Drawing.SystemIcons]::Information
        }

        $notifyIcon.Text = "Codex Notify"
        $notifyIcon.BalloonTipTitle = [string]$Data.Title
        $notifyIcon.BalloonTipText = [string]$Data.Body
        $notifyIcon.BalloonTipIcon = [Windows.Forms.ToolTipIcon]::None
        $notifyIcon.Visible = $true

        $clicked = $false
        $notifyIcon.add_BalloonTipClicked({
            $script:notificationClicked = $true
        })
        $script:notificationClicked = $false
        $notifyIcon.ShowBalloonTip(30000)

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        while ($stopwatch.Elapsed.TotalSeconds -lt $script:WatchSeconds) {
            [Windows.Forms.Application]::DoEvents()
            if ($script:notificationClicked) {
                $clicked = $true
                break
            }
            Start-Sleep -Milliseconds 50
        }

        if ($clicked) {
            Activate-SourceWindow $Data
        }
    } finally {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
        if ($null -ne $ownedIcon) {
            $ownedIcon.Dispose()
        }
    }
}

function Show-DesktopNotification {
    param([object]$Data)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Initialize-WindowActivator

    if ([string]::IsNullOrWhiteSpace((Get-SourceProtocolUri $Data)) -or
        -not (Show-WinRTNotification $Data)) {
        Show-NotifyIconNotification $Data
    }
}

if ($PSCmdlet.ParameterSetName -eq "Activate") {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Initialize-WindowActivator
        $activationData = Get-ActivationData $ActivationUri
        Activate-SourceWindow $activationData
        exit 0
    } catch {
        exit 1
    }
}

if ($Serve) {
    try {
        $json = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($NotificationData)
        )
        $data = $json | ConvertFrom-Json
        Show-DesktopNotification $data
        exit 0
    } catch {
        exit 1
    }
}

if ([string]::IsNullOrWhiteSpace($Payload)) {
    exit 2
}

try {
    $event = $Payload | ConvertFrom-Json
} catch {
    exit 0
}

if ($event.type -ne "agent-turn-complete") {
    exit 0
}

$answer = Get-EventValue $event @("last-assistant-message")
if ([string]::IsNullOrWhiteSpace($answer)) {
    exit 0
}

$threadId = Get-EventValue $event @("thread-id")
$cwd = Get-EventValue $event @("cwd")
$sessionName = Get-SessionName $event $threadId
$question = Convert-ToCompactText (Get-LastInputMessage $event) `
    $script:QuestionPreviewLimit
$answerPreview = Convert-ToCompactText $answer $script:AnswerPreviewLimit

$directory = "Unknown folder"
if (-not [string]::IsNullOrWhiteSpace($cwd)) {
    $directory = Split-Path -Leaf $cwd.TrimEnd([char[]]"\/")
}
$directory = Convert-ToCompactText $directory $script:DirectoryPreviewLimit
$title = Convert-ToCompactText "[$sessionName] @ $directory" `
    $script:TitlePreviewLimit
$bodyParts = @($question, $answerPreview) | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
}
$body = $bodyParts -join [Environment]::NewLine

$source = Get-SourceContext $cwd
$data = [ordered]@{
    Title = $title
    Body = $body
    WindowHandle = $source.WindowHandle
    ProcessId = $source.ProcessId
    ProcessName = $source.ProcessName
    IconPath = $source.ExecutablePath
    Directory = $directory
}

$notificationPayload = [pscustomobject]$data
try {
    $protocolUri = Get-SourceProtocolUri $notificationPayload
    if (-not [string]::IsNullOrWhiteSpace($protocolUri) -and
        (Show-WinRTNotification $notificationPayload)) {
        exit 0
    }
    Start-NotificationServer $data
} catch {
    Show-DesktopNotification $notificationPayload
}

exit 0
