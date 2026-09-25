#requires -version 5.1
<#
 KiRo PC Diagnostic & Repair v4.2 GUI
 Windows 10/11

 PRINCIP:
 1) PRVO SKENIRA I DIJAGNOSTIKUJE
 2) PRIKAZUJE STA JE PRONADJENO
 3) TEK ONDA NUDI POPRAVKU / CISCENJE

 Bez agresivnog registry cleanera.
 Ne brise nasumicno "sumnjive" fajlove.
 Malware/Trojan sken radi bez Microsoft Defender-a i nista ne brise bez tvog izbora.
#>

param(
    [ValidateSet('','Scan','Menu','WindowsRepair','Performance','Display','Malware','ToggleDefender','Indicators')]
    [string]$Action = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
# Naslov konzole odmah kaze koji je modul otvoren (da se ne pomesa sa glavnim GUI-em).
try {
    $wTitle = if ($Action) { "KiRo v4.2 - ALATI: $Action" } else { "KiRo PC Diagnostic & Repair v4.2" }
    $Host.UI.RawUI.WindowTitle = $wTitle
} catch {}

function Ensure-Admin {
    if ($script:KiRoLibraryMode) { return }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList @(
                "-NoLogo","-NoProfile","-ExecutionPolicy","Bypass",
                "-File","`"$PSCommandPath`""
            )
        } catch {}
        exit
    }
}
Ensure-Admin

$LogRoot = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "KiRo_PC_Diagnostic_Logs"
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null
$script:SettingsFile = Join-Path $LogRoot "KiRo_v4_settings.json"
$script:Settings = [ordered]@{ DefenderChecksEnabled = $false }
function Save-KiRoSettings {
    try { $script:Settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8 } catch {}
}
function Load-KiRoSettings {
    try {
        if (Test-Path -LiteralPath $script:SettingsFile) {
            $loaded = Get-Content -LiteralPath $script:SettingsFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $loaded.DefenderChecksEnabled) { $script:Settings.DefenderChecksEnabled = [bool]$loaded.DefenderChecksEnabled }
        } else { Save-KiRoSettings }
    } catch { Save-KiRoSettings }
}
function Toggle-DefenderChecks {
    $script:Settings.DefenderChecksEnabled = -not [bool]$script:Settings.DefenderChecksEnabled
    Save-KiRoSettings
    $state = if ($script:Settings.DefenderChecksEnabled) { 'UKLJUCENE' } else { 'ISKLJUCENE' }
    Write-Host "Defender provere su sada: $state" -ForegroundColor Cyan
    Start-Sleep -Seconds 1
}
Load-KiRoSettings
$script:USOStaleMarker = Join-Path $LogRoot 'USO_UxBroker_stale.json'
$Stamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogFile = Join-Path $LogRoot "KiRo_Diagnostic_$Stamp.txt"

if (-not $script:KiRoNoTranscript) { try { Start-Transcript -Path $LogFile -Force | Out-Null } catch {} }

$script:Findings = New-Object System.Collections.ArrayList
# Oznaka da li Add-Finding trenutno dodaje nalaze iz plugin skena (v4.2).
# Koristi se da se plugin nalazi oznace sa Source='Plugin' i tako SAČUVAJU
# kad god se glavni sken zavrsi (Complete-KiRoJob inace zameni $script:Findings).
$script:_KiRoInPluginScan = $false
$script:ScanDetails = [ordered]@{}
$RepairBackupRoot = Join-Path $LogRoot "Repair_Backup_$Stamp"
New-Item -ItemType Directory -Force -Path $RepairBackupRoot | Out-Null
$script:RepairBackupLog = Join-Path $RepairBackupRoot "startup_repair_backup.jsonl"

# ================================================================ PLUGIN SISTEM (v4.2)
# Svaki .ps1 fajl u folderu 'Plugins' je jedan modul (plugin).
# Plugin se prijavljuje preko Register-KiRoPlugin i moze da:
#   - radi SKEN (ScanScript) koji dodaje nalaze preko Add-Finding
#   - opciono nudi POPRAVKU (RepairScript)
# Loader ih automatski otkriva na startu - ne diramo ostatak koda.
$script:Plugins = New-Object System.Collections.ArrayList
$script:PluginsLoaded = $false
# Oznaka build-a - GUI je prikazuje u PLUGINI prozoru da korisnik moze da potvrdi
# da li pokrece novu verziju (zastareli izvaceni paket cesto pravi "nicta se ne desi").
$script:KiRoBuild = 'v4.2 (2026-09-25-pluginfix)'
# Putanja na kojoj su trazeni pluginovi - GUI je prikazuje radi dijagnostike.
$script:PluginsDir = ''

function Register-KiRoPlugin {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Author = '',
        [string]$Description = '',
        [scriptblock]$ScanScript = $null,
        [scriptblock]$RepairScript = $null,
        [string]$Version = '1.0'
    )
    if (-not $Name) { return }
    # Ako vec postoji (re-load), zameni ga.
    for ($i = 0; $i -lt $script:Plugins.Count; $i++) {
        if ($script:Plugins[$i].Name -eq $Name) { [void]$script:Plugins.RemoveAt($i); break }
    }
    [void]$script:Plugins.Add([pscustomobject]@{
        Name = $Name
        Author = $Author
        Description = $Description
        Version = $Version
        ScanScript = $ScanScript
        RepairScript = $RepairScript
        HasRepair = ($null -ne $RepairScript)
        Loaded = $true
    })
}

function Load-KiRoPlugins {
    $pluginDir = Join-Path $PSScriptRoot 'Plugins'
    $script:PluginsDir = $pluginDir
    $script:Plugins.Clear()
    if (-not (Test-Path -LiteralPath $pluginDir)) {
        $script:PluginsLoaded = $false
        return
    }
    foreach ($pf in @(Get-ChildItem -LiteralPath $pluginDir -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
        try {
            . $pf.FullName
        } catch {
            Write-Host ('[PLUGIN] Greska pri ucitavanju ' + $pf.Name + ': ' + $_.Exception.Message) -ForegroundColor Red
        }
    }
    $script:PluginsLoaded = $true
}

function Invoke-KiRoPluginScans {
    # Nalaz po pluginu se DODAJE u $script:Findings (bez brisanja prethodnih plugin
    # nalaza). Time korisnik uvek vidi rast tabele kad klikne "POKRENI SVE PLUGINE",
    # i nema rizika od "Dodato nalaza: -2" ako novi sken iz nekog razloga ne doda
    # nista. Source='Plugin' tag (setovan u Add-Finding preko _KiRoInPluginScan)
    # se i dalje koristi da Complete-KiRoJob sacuva plugin nalaze kroz glavni sken.
    $ran = 0
    $logp = $null
    try {
        $lg = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'KiRo_PC_Diagnostic_Logs'
        New-Item -ItemType Directory -Force -Path $lg | Out-Null
        $logp = Join-Path $lg 'KiRo_plugin.log'
        Add-Content -LiteralPath $logp -Value ((Get-Date).ToString('s') + '  Invoke-KiRoPluginScans start: plugins=' + $script:Plugins.Count) -Encoding UTF8
    } catch {}
    $script:_KiRoInPluginScan = $true
    foreach ($p in @($script:Plugins)) {
        if ($p.ScanScript) {
            try {
                if ($logp) { Add-Content -LiteralPath $logp -Value ((Get-Date).ToString('s') + '  run: ' + $p.Name) -Encoding UTF8 }
                & $p.ScanScript
                if ($logp) { Add-Content -LiteralPath $logp -Value ((Get-Date).ToString('s') + '  ok: ' + $p.Name + ' findingsNow=' + $script:Findings.Count) -Encoding UTF8 }
            } catch {
                Add-Finding 'UPOZORENJE' 'Plugin' ('Plugin ''' + $p.Name + ''' nije uspeo u skeniranju: ' + $_.Exception.Message) 'Proveri plugin kod.' '' $false
                if ($logp) { Add-Content -LiteralPath $logp -Value ((Get-Date).ToString('s') + '  ERR: ' + $p.Name + ': ' + $_.Exception.Message) -Encoding UTF8 }
            }
            $ran++
        }
    }
    $script:_KiRoInPluginScan = $false
    return $ran
}

# Ucitaj pluginove odmah pri startu (radi i u GUI/library rezimu i standalone).
Load-KiRoPlugins

function Write-Header {
    try { Clear-Host } catch {}
    Write-Host ""
    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host "            KiRo PC DIAGNOSTIC & REPAIR  v4.2 GUI" -ForegroundColor Cyan
    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host "     PRVO SKENIRA  ->  PRIKAZE PROBLEME  ->  TI BIRAS POPRAVKU" -ForegroundColor DarkCyan
    Write-Host ""
}

function Pause-KiRo {
    Write-Host ""
    Read-Host "Pritisni ENTER za nastavak"
}

function Add-Finding {
    param(
        [string]$Severity,
        [string]$Category,
        [string]$Problem,
        [string]$Recommendation,
        [string]$FixAction = "",
        [bool]$SafeAutoFix = $false,
        [object]$Data = $null
    )
    $id = $script:Findings.Count + 1
    $src = if ($script:_KiRoInPluginScan) { 'Plugin' } else { 'Scan' }
    [void]$script:Findings.Add([pscustomobject]@{
        ID = $id
        Severity = $Severity
        Category = $Category
        Problem = $Problem
        Recommendation = $Recommendation
        FixAction = $FixAction
        SafeAutoFix = $SafeAutoFix
        Data = $Data
        Source = $src
    })
}

function Save-RepairBackupRecord {
    param([Parameter(Mandatory=$true)][object]$Record)
    try {
        $Record | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $script:RepairBackupLog -Encoding UTF8
    } catch {}
}

function Test-KiRoTarget {
    param([string]$PathOrCommand)
    if ([string]::IsNullOrWhiteSpace($PathOrCommand)) { return $false }
    try {
        if ([IO.Path]::IsPathRooted($PathOrCommand) -or $PathOrCommand -match '[\\/]') {
            return [System.IO.File]::Exists($PathOrCommand)
        }
        return [bool](Get-Command $PathOrCommand -ErrorAction SilentlyContinue | Select-Object -First 1)
    } catch { return $false }
}

function Get-LaunchReferenceStatus {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) { return $null }

    $expanded = [Environment]::ExpandEnvironmentVariables($Command.Trim())
    $target = $null

    # Prvi program u komandnoj liniji.
    $m = [regex]::Match($expanded, '(?i)^\s*"?(.+?\.(?:exe|com|bat|cmd|ps1|vbs|js))"?(?:\s|$)')
    if ($m.Success) {
        $target = $m.Groups[1].Value.Trim().Trim('"')
    } else {
        $first = ($expanded -split '\s+', 2)[0].Trim().Trim('"')
        if ($first) { $target = $first }
    }

    if ([string]::IsNullOrWhiteSpace($target)) { return $null }
    $target = [Environment]::ExpandEnvironmentVariables($target)

    $exists = Test-KiRoTarget $target

    # Ako je prvi program samo launcher, proveri i ugnjezdene apsolutne putanje.
    if ($exists) {
        $leaf = [IO.Path]::GetFileName($target).ToLowerInvariant()
        $wrappers = @('cmd.exe','powershell.exe','pwsh.exe','wscript.exe','cscript.exe','mshta.exe','explorer.exe','rundll32.exe')
        if ($wrappers -contains $leaf) {
            $pathMatches = [regex]::Matches($expanded, '(?i)(?:"([A-Z]:\\[^"\r\n]+?\.(?:exe|com|bat|cmd|ps1|vbs|js))"|([A-Z]:\\[^\r\n]*?\.(?:exe|com|bat|cmd|ps1|vbs|js)))')
            foreach ($pm in $pathMatches) {
                $candidate = if ($pm.Groups[1].Success) { $pm.Groups[1].Value } else { $pm.Groups[2].Value }
                $candidate = $candidate.Trim().Trim('"')
                if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                if ($candidate -ieq $target) { continue }
                if (-not (Test-KiRoTarget $candidate)) {
                    return [pscustomobject]@{ Command=$Command; ExpandedCommand=$expanded; Target=$candidate; Exists=$false; Wrapper=$target }
                }
            }
        }
    }

    [pscustomobject]@{ Command=$Command; ExpandedCommand=$expanded; Target=$target; Exists=[bool]$exists; Wrapper=$null }
}

function Scan-OrphanAutoStartEntries {
    $found = 0
    $regLocations = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Label = 'HKCU Run'; Values = $null },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Label = 'HKCU RunOnce'; Values = $null },
        @{ Path = 'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Label = 'HKCU 32-bit Run'; Values = $null },
        @{ Path = 'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Label = 'HKCU 32-bit RunOnce'; Values = $null },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Label = 'HKLM Run'; Values = $null },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Label = 'HKLM RunOnce'; Values = $null },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Label = 'HKLM 32-bit Run'; Values = $null },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Label = 'HKLM 32-bit RunOnce'; Values = $null },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'; Label = 'HKCU Policies Run'; Values = $null },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'; Label = 'HKLM Policies Run'; Values = $null },
        @{ Path = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows'; Label = 'HKCU Legacy Windows load/run'; Values = @('load','run') }
    )

    foreach ($loc in $regLocations) {
        if (-not (Test-Path -LiteralPath $loc.Path)) { continue }
        try {
            $key = Get-Item -LiteralPath $loc.Path -ErrorAction Stop
            $names = @($key.GetValueNames())
            if ($loc.Values) { $names = @($names | Where-Object { $loc.Values -contains $_ }) }
            foreach ($name in $names) {
                try {
                    $cmd = [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
                    $status = Get-LaunchReferenceStatus $cmd
                    if ($status -and -not $status.Exists) {
                        $kind = $key.GetValueKind($name).ToString()
                        $data = [pscustomobject]@{ Type='RegistryStartup'; RegistryPath=$loc.Path; LocationLabel=$loc.Label; Name=$name; Command=$cmd; ValueKind=$kind; Target=$status.Target; Wrapper=$status.Wrapper }
                        $extra = if ($status.Wrapper) { " (preko $($status.Wrapper))" } else { '' }
                        Add-Finding 'UPOZORENJE' 'Startup' "Autostart '$name' ($($loc.Label)) pokusava da pokrene fajl koji vise ne postoji$extra`: $($status.Target)" 'Ukloni samo pokvarenu autostart referencu. Pre uklanjanja se pravi backup zapisa.' 'ORPHAN_STARTUP_REG' $true $data
                        $found++
                    }
                } catch {}
            }
        } catch {}
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $startupFolders = @([Environment]::GetFolderPath('Startup'),[Environment]::GetFolderPath('CommonStartup')) | Where-Object { $_ } | Select-Object -Unique
        foreach ($folder in $startupFolders) {
            if (-not (Test-Path -LiteralPath $folder)) { continue }
            foreach ($lnk in @(Get-ChildItem -LiteralPath $folder -Filter *.lnk -File -ErrorAction SilentlyContinue)) {
                try {
                    $sc = $shell.CreateShortcut($lnk.FullName)
                    $target = [Environment]::ExpandEnvironmentVariables([string]$sc.TargetPath)
                    if ($target -and -not (Test-Path -LiteralPath $target -PathType Leaf)) {
                        $data = [pscustomobject]@{Type='StartupShortcut';ShortcutPath=$lnk.FullName;Target=$target}
                        Add-Finding 'UPOZORENJE' 'Startup' "Startup precica '$($lnk.Name)' pokazuje na fajl koji vise ne postoji: $target" 'Premesti pokvarenu precicu u KiRo backup folder, umesto trajnog brisanja.' 'ORPHAN_STARTUP_LNK' $true $data
                        $found++
                    }
                } catch {}
            }
        }
    } catch {}
    return $found
}

function Scan-OrphanScheduledTasks {
    $found = 0
    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    } catch {}

    $nonMicrosoftCount = @($tasks | Where-Object { $_.TaskPath -notlike '\Microsoft\*' }).Count

    foreach ($task in $tasks) {
        # Iskljucen zadatak ne moze da pravi popup pri startu, zato ga samo preskacemo.
        if ([string]$task.State -eq 'Disabled') { continue }

        foreach ($action in @($task.Actions)) {
            $execute = [string]$action.Execute
            if ([string]::IsNullOrWhiteSpace($execute)) { continue }
            Test-KiRoSuspiciousLaunch -Command $execute -Arguments ([string]$action.Arguments) -Source "Zakazani zadatak '$($task.TaskPath)$($task.TaskName)'"
            $status = Get-LaunchReferenceStatus $execute
            if ($status -and -not $status.Exists) {
                $isMicrosoftPath = ([string]$task.TaskPath -like '\Microsoft\*')
                $data = [pscustomobject]@{
                    Type = 'ScheduledTask'
                    TaskName = $task.TaskName
                    TaskPath = $task.TaskPath
                    Execute = $execute
                    Target = $status.Target
                    State = [string]$task.State
                    MicrosoftPath = $isMicrosoftPath
                }

                if ($isMicrosoftPath) {
                    $winRoot = [IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\')
                    $targetFull = $null
                    try { $targetFull = [IO.Path]::GetFullPath([string]$status.Target) } catch {}
                    if ($targetFull -and $targetFull.StartsWith($winRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $isUso = ([string]$task.TaskPath -ieq '\Microsoft\Windows\UpdateOrchestrator\') -and ([string]$task.TaskName -ieq 'USO_UxBroker') -and ([IO.Path]::GetFileName([string]$status.Target) -ieq 'MusNotification.exe')
                        $wasHandled = $isUso -and (Test-Path -LiteralPath $script:USOStaleMarker -PathType Leaf)
                        if ($wasHandled) {
                            Add-Finding 'INFO' 'Zakazani zadatak' "Windows protected/stale task '$($task.TaskPath)$($task.TaskName)' i dalje pokazuje na nepostojeci MusNotification.exe." 'Bezbedna popravka je vec pokusana. Windows component store je zdrav, a task je zasticen. KiRo ga nece stalno popravljati iznova; sacekaj Windows Update osvezavanje ili uradi rucnu proveru.' '' $false $data
                        } else {
                            Add-Finding 'UPOZORENJE' 'Zakazani zadatak' "Microsoft Task Scheduler zadatak '$($task.TaskPath)$($task.TaskName)' pokazuje na Windows fajl koji ne postoji: $($status.Target)" 'KiRo ce jednom pokusati bezbednu popravku i napraviti XML backup. Ne menja ownership/ACL Windows taskova.' 'MICROSOFT_TASK_REPAIR' $true $data
                        }
                    } else {
                        Add-Finding 'UPOZORENJE' 'Zakazani zadatak' "Microsoft Task Scheduler zadatak '$($task.TaskPath)$($task.TaskName)' pokazuje na fajl koji ne postoji: $($status.Target)" 'Ciljni fajl nije prepoznat kao Windows sistemski fajl; zadatak se ne menja automatski.' '' $false $data
                    }
                } else {
                    Add-Finding 'UPOZORENJE' 'Zakazani zadatak' "Zadatak '$($task.TaskPath)$($task.TaskName)' pokusava da pokrene fajl koji vise ne postoji: $($status.Target)" 'Iskljuci samo ovaj pokvareni zadatak. XML kopija zadatka se cuva u backup folderu.' 'ORPHAN_TASK' $true $data
                }
                $found++
                break
            }
        }
    }
    return [pscustomobject]@{ Count = $found; Tasks = $nonMicrosoftCount; AllTasks = $tasks.Count }
}

function Scan-OrphanAutoServices {
    $found = 0
    try {
        $services = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' OR StartMode='Manual'" -Property Name,DisplayName,PathName,StartMode,State -ErrorAction SilentlyContinue | Where-Object { $_.PathName })
        foreach ($svc in $services) {
            $status = Get-LaunchReferenceStatus ([string]$svc.PathName)
            if ($status -and -not $status.Exists) {
                $isWindowsTarget = $false
                try {
                    $wr = [IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\')
                    $tf = [IO.Path]::GetFullPath([string]$status.Target)
                    $isWindowsTarget = $tf.StartsWith($wr,[System.StringComparison]::OrdinalIgnoreCase)
                } catch {}
                $data = [pscustomobject]@{Type='OrphanService';Name=$svc.Name;DisplayName=$svc.DisplayName;PathName=$svc.PathName;Target=$status.Target;StartMode=$svc.StartMode;State=$svc.State;IsWindowsTarget=$isWindowsTarget}
                if ($isWindowsTarget) {
                    Add-Finding 'UPOZORENJE' 'Servis' "Windows servis '$($svc.Name)' pokazuje na fajl koji ne postoji: $($status.Target)" 'Ne gasi se automatski. Pokreni dubinsku Windows popravku ako je sistemski fajl.' '' $false $data
                } else {
                    Add-Finding 'UPOZORENJE' 'Servis' "Servis '$($svc.Name)' pokazuje na fajl koji ne postoji: $($status.Target)" 'KiRo moze da ISKLJUCI ovaj orphan servis (ne brise ga) i sacuva registry backup.' 'ORPHAN_SERVICE_DISABLE' $true $data
                }
                $found++
            }
        }
    } catch {}
    return $found
}


function Get-SystemMemorySnapshot {
    try {
        $os = $script:KiRoOsCache
        if (-not $os) { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop }
        $totalMB = [math]::Round([double]$os.TotalVisibleMemorySize / 1024, 0)
        $freeMB = [math]::Round([double]$os.FreePhysicalMemory / 1024, 0)
        $usedMB = [math]::Max(0, $totalMB - $freeMB)
        $usedPct = if ($totalMB -gt 0) { [math]::Round(($usedMB / $totalMB) * 100, 1) } else { 0 }
        [pscustomobject]@{ TotalMB=$totalMB; FreeMB=$freeMB; UsedMB=$usedMB; UsedPct=$usedPct }
    } catch { $null }
}

function Get-UserBackgroundProcesses {
    $result = New-Object System.Collections.ArrayList
    $currentSession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $ignore = @(
        'System','Idle','Registry','Memory Compression','Secure System','csrss','wininit','winlogon','services','lsass','smss',
        'svchost','dwm','explorer','sihost','ctfmon','fontdrvhost','audiodg','spoolsv','SearchHost','SearchApp',
        'StartMenuExperienceHost','ShellExperienceHost','RuntimeBroker','ApplicationFrameHost','TextInputHost','SecurityHealthSystray',
        'powershell','powershell_ise','pwsh','cmd','conhost','WindowsTerminal','OpenConsole'
    )
    $winRoot = $null
    try { $winRoot = [IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\') } catch { $winRoot = $env:WINDIR }

    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Id -eq $PID -or $p.Id -le 4) { continue }
            if ($p.SessionId -ne $currentSession) { continue }
            if ($ignore -contains $p.ProcessName) { continue }
            if ($p.MainWindowHandle -ne 0) { continue }

            $path = $null
            try { $path = [string]$p.Path } catch {}
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            $full = $null
            try { $full = [IO.Path]::GetFullPath($path) } catch { $full = $path }
            if ($winRoot -and $full.StartsWith($winRoot, [System.StringComparison]::OrdinalIgnoreCase)) { continue }

            [void]$result.Add([pscustomobject]@{
                PID = $p.Id
                Name = $p.ProcessName
                RAM_MB = [math]::Round($p.WorkingSet64 / 1MB, 1)
                CPU_s = if ($null -ne $p.CPU) { [math]::Round([double]$p.CPU,1) } else { 0 }
                Path = $full
            })
        } catch {}
    }
    @($result | Sort-Object RAM_MB -Descending)
}

function Get-StartupItemsForManagement {
    $items = New-Object System.Collections.ArrayList
    $regLocations = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Label = 'HKCU Run' },
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Label = 'HKCU RunOnce' },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Label = 'HKLM Run' },
        @{ Path = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Label = 'HKLM RunOnce' },
        @{ Path = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Label = 'HKLM 32-bit Run' }
    )
    foreach ($loc in $regLocations) {
        if (-not (Test-Path -LiteralPath $loc.Path)) { continue }
        try {
            $key = Get-Item -LiteralPath $loc.Path -ErrorAction Stop
            foreach ($name in @($key.GetValueNames())) {
                $cmd = [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
                $status = Get-LaunchReferenceStatus $cmd
                [void]$items.Add([pscustomobject]@{
                    Type='Registry'; Name=$name; Source=$loc.Label; Command=$cmd;
                    Target=if ($status) { $status.Target } else { '' };
                    RegistryPath=$loc.Path; ShortcutPath=''
                })
            }
        } catch {}
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) | Where-Object { $_ } | Select-Object -Unique) {
            if (-not (Test-Path -LiteralPath $folder)) { continue }
            foreach ($lnk in @(Get-ChildItem -LiteralPath $folder -Filter *.lnk -File -ErrorAction SilentlyContinue)) {
                try {
                    $sc = $shell.CreateShortcut($lnk.FullName)
                    [void]$items.Add([pscustomobject]@{
                        Type='Shortcut'; Name=$lnk.BaseName; Source='Startup folder'; Command=$lnk.FullName;
                        Target=[Environment]::ExpandEnvironmentVariables([string]$sc.TargetPath);
                        RegistryPath=''; ShortcutPath=$lnk.FullName
                    })
                } catch {}
            }
        }
    } catch {}

    $i = 1
    foreach ($x in $items) { Add-Member -InputObject $x -NotePropertyName ID -NotePropertyValue $i -Force; $i++ }
    @($items)
}

function Backup-AndDisableStartupItem {
    param([Parameter(Mandatory=$true)][object]$Item)
    if ($Item.Type -eq 'Registry') {
        $key = Get-Item -LiteralPath $Item.RegistryPath -ErrorAction Stop
        $current = [string]$key.GetValue($Item.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ([string]::IsNullOrWhiteSpace($current)) { return $false }

        $regDir = Join-Path $RepairBackupRoot 'Disabled_Startup_Registry'
        New-Item -ItemType Directory -Force -Path $regDir | Out-Null
        $native = [string]$Item.RegistryPath
        $native = $native -replace '^HKCU:', 'HKEY_CURRENT_USER'
        $native = $native -replace '^HKLM:', 'HKEY_LOCAL_MACHINE'
        $safeName = (($Item.Source + '_' + $Item.Name) -replace '[\\/:*?"<>|]', '_')
        $backup = Join-Path $regDir ("{0}_{1}.reg" -f $safeName, (Get-Date -Format 'yyyyMMdd_HHmmssfff'))
        try { & reg.exe export $native $backup /y 2>$null | Out-Null } catch {}
        Save-RepairBackupRecord ([pscustomobject]@{Time=(Get-Date).ToString('o');Type='DisabledStartupRegistry';RegistryPath=$Item.RegistryPath;Name=$Item.Name;Command=$current;Backup=$backup})
        Remove-ItemProperty -LiteralPath $Item.RegistryPath -Name $Item.Name -Force -ErrorAction Stop
        return $true
    }
    elseif ($Item.Type -eq 'Shortcut') {
        if (-not (Test-Path -LiteralPath $Item.ShortcutPath -PathType Leaf)) { return $false }
        $dir = Join-Path $RepairBackupRoot 'Disabled_Startup_Shortcuts'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $dest = Join-Path $dir ((Get-Date -Format 'yyyyMMdd_HHmmssfff') + '_' + [IO.Path]::GetFileName($Item.ShortcutPath))
        Move-Item -LiteralPath $Item.ShortcutPath -Destination $dest -Force -ErrorAction Stop
        Save-RepairBackupRecord ([pscustomobject]@{Time=(Get-Date).ToString('o');Type='DisabledStartupShortcut';Original=$Item.ShortcutPath;Backup=$dest;Target=$Item.Target})
        return $true
    }
    return $false
}

function Disable-MatchingStartupReferences {
    param([Parameter(Mandatory=$true)][string]$ExecutablePath)
    $targetNorm = $null
    try { $targetNorm = [IO.Path]::GetFullPath($ExecutablePath).Trim() } catch { $targetNorm = $ExecutablePath.Trim() }
    $count = 0
    foreach ($item in @(Get-StartupItemsForManagement)) {
        $itemTarget = [string]$item.Target
        if ([string]::IsNullOrWhiteSpace($itemTarget)) { continue }
        try { $itemTarget = [IO.Path]::GetFullPath($itemTarget).Trim() } catch {}
        if ($itemTarget.Equals($targetNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
            try { if (Backup-AndDisableStartupItem $item) { $count++ } } catch {}
        }
    }
    return $count
}

function Manage-StartupPrograms {
    while ($true) {
        Write-Header
        Write-Host 'STARTUP PROGRAMI - ukljuceni autostart unosi' -ForegroundColor Cyan
        Write-Host 'Nista se ne gasi bez tvog izbora. Pre izmene se pravi backup.' -ForegroundColor Yellow
        Write-Host ''
        $items = @(Get-StartupItemsForManagement)
        if ($items.Count -eq 0) {
            Write-Host 'Nema pronadjenih startup programa u Run/RunOnce i Startup folderima.' -ForegroundColor Green
            Pause-KiRo
            return
        }
        $items | Select-Object ID,Type,Name,Source,Target | Format-Table -Wrap -AutoSize
        Write-Host ''
        $raw = Read-Host 'Upisi brojeve koje hoces da ISKLJUCIS iz startup-a (npr. 1,3) ili 0 za nazad'
        if ($raw.Trim() -eq '0') { return }
        $ids = $raw -split '[,; ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Select-Object -Unique
        if (-not $ids) { continue }
        $confirm = Read-Host 'Upisi DA da potvrdim iskljucivanje iz startup-a'
        if ($confirm.ToUpper() -ne 'DA') { continue }
        foreach ($id in $ids) {
            $it = $items | Where-Object ID -eq $id | Select-Object -First 1
            if (-not $it) { continue }
            try {
                if (Backup-AndDisableStartupItem $it) { Write-Host "Iskljucen startup: $($it.Name)" -ForegroundColor Green }
                else { Write-Host "Nije promenjen: $($it.Name)" -ForegroundColor Yellow }
            } catch { Write-Host "Greska za $($it.Name): $($_.Exception.Message)" -ForegroundColor Red }
        }
        Pause-KiRo
    }
}

function Manage-BackgroundProcesses {
    while ($true) {
        Write-Header
        $mem = Get-SystemMemorySnapshot
        if ($mem) { Write-Host "RAM: $($mem.UsedPct)% koristi se | $($mem.UsedMB) MB / $($mem.TotalMB) MB | slobodno $($mem.FreeMB) MB" -ForegroundColor Cyan }
        Write-Host ''
        Write-Host 'POZADINSKI KORISNICKI PROCESI (bez Windows sistemskih procesa)' -ForegroundColor Cyan
        Write-Host 'Program ne koristi lazni RAM cleaner; RAM oslobadja zaustavljanjem samo procesa koje TI izaberes.' -ForegroundColor Yellow
        Write-Host ''
        $procs = @(Get-UserBackgroundProcesses | Select-Object -First 40)
        if ($procs.Count -eq 0) {
            Write-Host 'Nema vidljivih trecih-party pozadinskih procesa za ovu sesiju.' -ForegroundColor Green
            Pause-KiRo
            return
        }
        $i=1
        $rows = foreach ($p in $procs) { [pscustomobject]@{ID=$i;PID=$p.PID;Program=$p.Name;RAM_MB=$p.RAM_MB;CPU_s=$p.CPU_s;Path=$p.Path}; $i++ }
        $rows | Format-Table -Wrap -AutoSize
        Write-Host ''
        $raw = Read-Host 'Upisi procese koje hoces da ZAUSTAVIS (npr. 1,2) ili 0 za nazad'
        if ($raw.Trim() -eq '0') { return }
        $ids = $raw -split '[,; ]+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Select-Object -Unique
        if (-not $ids) { continue }
        $alsoStartup = Read-Host 'Da li da istom programu, ako ga nadjem, iskljucim i automatsko pokretanje? (DA/NE)'
        $confirm = Read-Host 'Upisi DA da potvrdim zaustavljanje izabranih procesa'
        if ($confirm.ToUpper() -ne 'DA') { continue }
        foreach ($id in $ids) {
            $r = $rows | Where-Object ID -eq $id | Select-Object -First 1
            if (-not $r) { continue }
            try {
                $live = Get-Process -Id $r.PID -ErrorAction Stop
                Stop-Process -Id $r.PID -Force -ErrorAction Stop
                Write-Host "Zaustavljen: $($r.Program) (PID $($r.PID), RAM $($r.RAM_MB) MB)" -ForegroundColor Green
                if ($alsoStartup.ToUpper() -eq 'DA' -and $r.Path) {
                    $n = Disable-MatchingStartupReferences -ExecutablePath $r.Path
                    if ($n -gt 0) { Write-Host "  Iskljuceno startup referenci: $n" -ForegroundColor Green }
                }
            } catch { Write-Host "Nije moguce zaustaviti $($r.Program): $($_.Exception.Message)" -ForegroundColor Red }
        }
        Start-Sleep -Seconds 1
        $after = Get-SystemMemorySnapshot
        if ($after) { Write-Host "RAM posle: $($after.UsedPct)% | slobodno $($after.FreeMB) MB" -ForegroundColor Cyan }
        Pause-KiRo
    }
}

function Performance-OptimizationMenu {
    while ($true) {
        Write-Header
        $mem = Get-SystemMemorySnapshot
        if ($mem) { Write-Host "RAM trenutno: $($mem.UsedPct)% | slobodno $($mem.FreeMB) MB od $($mem.TotalMB) MB" -ForegroundColor Cyan }
        Write-Host ''
        Write-Host '[1] Startup programi - pregled i iskljucivanje odabranih' -ForegroundColor White
        Write-Host '[2] Pozadinski procesi - zaustavi odabrane i oslobodi RAM' -ForegroundColor White
        Write-Host '[3] Otvori Windows Task Manager' -ForegroundColor White
        Write-Host '[0] Nazad' -ForegroundColor DarkGray
        $c = Read-Host 'Izaberi opciju'
        switch ($c) {
            '1' { Manage-StartupPrograms }
            '2' { Manage-BackgroundProcesses }
            '3' { try { Start-Process taskmgr.exe } catch {} }
            '0' { return }
            default { Write-Host 'Nepoznata opcija.' -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

function Initialize-KiRoDisplayApi {
    if ('KiRoDisplayV26' -as [type]) { return $true }
    $cs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class KiRoDisplayModeV26 {
    public int Width;
    public int Height;
    public int BitsPerPixel;
    public int RefreshHz;
}

public class KiRoDisplaySetResultV26 {
    public int TestCode;
    public int ApplyCode;
    public int LastError;
}

public static class KiRoDisplayV26 {
    public const int ENUM_CURRENT_SETTINGS = -1;
    public const int DM_BITSPERPEL = 0x00040000;
    public const int DM_PELSWIDTH = 0x00080000;
    public const int DM_PELSHEIGHT = 0x00100000;
    public const int DM_DISPLAYFREQUENCY = 0x00400000;
    public const uint CDS_UPDATEREGISTRY = 0x00000001;
    public const uint CDS_TEST = 0x00000002;
    public const int DISP_CHANGE_SUCCESSFUL = 0;

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="EnumDisplaySettingsW", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="ChangeDisplaySettingsW", SetLastError=true)]
    static extern int ChangeDisplaySettings(ref DEVMODE devMode, uint flags);

    static DEVMODE NewDevMode() {
        DEVMODE dm = new DEVMODE();
        dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        return dm;
    }

    public static KiRoDisplayModeV26 GetCurrentMode(out int lastError) {
        lastError = 0;
        DEVMODE dm = NewDevMode();
        if (!EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref dm)) {
            lastError = Marshal.GetLastWin32Error();
            return null;
        }
        return new KiRoDisplayModeV26 {
            Width = dm.dmPelsWidth,
            Height = dm.dmPelsHeight,
            BitsPerPixel = dm.dmBitsPerPel,
            RefreshHz = dm.dmDisplayFrequency
        };
    }

    public static KiRoDisplayModeV26[] GetModesForResolution(int width, int height, out int lastError) {
        lastError = 0;
        List<KiRoDisplayModeV26> list = new List<KiRoDisplayModeV26>();
        for (int i = 0; i < 4096; i++) {
            DEVMODE dm = NewDevMode();
            if (!EnumDisplaySettings(null, i, ref dm)) {
                if (i == 0) lastError = Marshal.GetLastWin32Error();
                break;
            }
            if (dm.dmPelsWidth != width || dm.dmPelsHeight != height) continue;
            if (dm.dmDisplayFrequency <= 1 || dm.dmDisplayFrequency > 1000) continue;
            if (dm.dmBitsPerPel > 0 && dm.dmBitsPerPel < 24) continue;
            list.Add(new KiRoDisplayModeV26 {
                Width = dm.dmPelsWidth,
                Height = dm.dmPelsHeight,
                BitsPerPixel = dm.dmBitsPerPel,
                RefreshHz = dm.dmDisplayFrequency
            });
        }
        return list.ToArray();
    }

    // Ne zavisi od EnumDisplaySettings: koristi poznatu trenutnu rezoluciju i menja samo Hz
    // uz eksplicitno zadrzavanje iste sirine/visine/bit-depth vrednosti.
    public static KiRoDisplaySetResultV26 TestAndSetRefresh(int width, int height, int bpp, int hz) {
        KiRoDisplaySetResultV26 r = new KiRoDisplaySetResultV26();
        DEVMODE dm = NewDevMode();
        dm.dmPelsWidth = width;
        dm.dmPelsHeight = height;
        dm.dmBitsPerPel = bpp > 0 ? bpp : 32;
        dm.dmDisplayFrequency = hz;
        dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL | DM_DISPLAYFREQUENCY;

        r.TestCode = ChangeDisplaySettings(ref dm, CDS_TEST);
        r.LastError = Marshal.GetLastWin32Error();
        if (r.TestCode != DISP_CHANGE_SUCCESSFUL) {
            r.ApplyCode = 99999;
            return r;
        }
        r.ApplyCode = ChangeDisplaySettings(ref dm, CDS_UPDATEREGISTRY);
        r.LastError = Marshal.GetLastWin32Error();
        return r;
    }
}
'@
    try {
        Add-Type -TypeDefinition $cs -ErrorAction Stop
        return $true
    } catch {
        $script:DisplayApiInitError = $_.Exception.Message
        return $false
    }
}

function Get-KiRoCurrentDisplayFallback {
    $w = 0; $h = 0; $bpp = 32; $hz = 0; $src = @()

    try {
        $vc = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Where-Object {
            $_.CurrentHorizontalResolution -gt 0 -and $_.CurrentVerticalResolution -gt 0
        } | Select-Object -First 1)
        if ($vc.Count -gt 0) {
            $v = $vc[0]
            $w = [int]$v.CurrentHorizontalResolution
            $h = [int]$v.CurrentVerticalResolution
            if ($v.CurrentBitsPerPixel -gt 0) { $bpp = [int]$v.CurrentBitsPerPixel }
            if ($v.CurrentRefreshRate -gt 1 -and $v.CurrentRefreshRate -lt 1000) { $hz = [int]$v.CurrentRefreshRate }
            $src += 'Win32_VideoController'
        }
    } catch {}

    if ($w -le 0 -or $h -le 0) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
            $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $w = [int]$bounds.Width
            $h = [int]$bounds.Height
            $src += 'System.Windows.Forms.Screen'
        } catch {}
    }

    if ($w -le 0 -or $h -le 0) { return $null }
    [pscustomobject]@{ Width=$w; Height=$h; BitsPerPixel=$bpp; RefreshHz=$hz; Source=($src -join '+') }
}

function Get-KiRoSupportedHzFromWmi {
    param([int]$Width,[int]$Height)
    $hz = New-Object System.Collections.ArrayList
    try {
        $sets = @(Get-CimInstance -Namespace 'root\wmi' -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop)
        foreach ($s in $sets) {
            foreach ($m in @($s.MonitorSourceModes)) {
                if (-not $m) { continue }
                $mw = [int]$m.HorizontalActivePixels
                $mh = [int]$m.VerticalActivePixels
                if ($mw -ne $Width -or $mh -ne $Height) { continue }
                $num = [double]$m.VerticalRefreshRateNumerator
                $den = [double]$m.VerticalRefreshRateDenominator
                if ($den -le 0) { continue }
                $v = [int][math]::Round($num / $den)
                if ($v -gt 1 -and $v -lt 1000 -and ($hz -notcontains $v)) { [void]$hz.Add($v) }
            }
        }
    } catch {}
    @($hz | Sort-Object -Unique)
}

function Get-DisplayInventory {
    if (-not (Initialize-KiRoDisplayApi)) { return @() }

    $cur = $null
    $enumErr = 0
    try { $cur = [KiRoDisplayV26]::GetCurrentMode([ref]$enumErr) } catch {}

    if ($cur) {
        $w=[int]$cur.Width; $h=[int]$cur.Height; $bpp=[int]$cur.BitsPerPixel; $currentHz=[int]$cur.RefreshHz
        $nativeModes = @()
        $modeErr = 0
        try { $nativeModes = @([KiRoDisplayV26]::GetModesForResolution($w,$h,[ref]$modeErr)) } catch {}
        $availableHz = @($nativeModes | ForEach-Object { [int]$_.RefreshHz } | Where-Object { $_ -gt 1 -and $_ -lt 1000 } | Sort-Object -Unique)
        $source = 'Win32 EnumDisplaySettings (C# wrapper)'
    } else {
        $fb = Get-KiRoCurrentDisplayFallback
        if (-not $fb) { return @() }
        $w=[int]$fb.Width; $h=[int]$fb.Height; $bpp=[int]$fb.BitsPerPixel; $currentHz=[int]$fb.RefreshHz
        $availableHz = @(Get-KiRoSupportedHzFromWmi -Width $w -Height $h)
        $source = 'WMI/EDID fallback'
    }

    if ($availableHz.Count -eq 0) {
        $availableHz = @(Get-KiRoSupportedHzFromWmi -Width $w -Height $h)
        if ($availableHz.Count -gt 0) { $source += ' + WMI/EDID modes' }
    }
    if ($currentHz -gt 1 -and $availableHz -notcontains $currentHz) { $availableHz = @($availableHz + $currentHz | Sort-Object -Unique) }

    $max = 0
    if ($availableHz.Count -gt 0) { $max = [int]($availableHz | Measure-Object -Maximum).Maximum }
    elseif ($currentHz -gt 1) { $max = $currentHz }

    @([pscustomobject]@{
        DeviceName = 'PRIMARY'
        Description = 'Primarni ekran'
        CurrentWidth = $w
        CurrentHeight = $h
        CurrentHz = $currentHz
        CurrentBpp = $(if ($bpp -gt 0) {$bpp} else {32})
        AvailableHz = $availableHz
        MaxHzCurrentResolution = $max
        Source = $source
        EnumLastError = $enumErr
    })
}

function Set-KiRoDisplayHz {
    param(
        [Parameter(Mandatory=$true)][object]$Display,
        [Parameter(Mandatory=$true)][int]$TargetHz
    )

    if ($TargetHz -le 1) { return $false }
    if (-not (Initialize-KiRoDisplayApi)) { return $false }

    try {
        $r = [KiRoDisplayV26]::TestAndSetRefresh(
            [int]$Display.CurrentWidth,
            [int]$Display.CurrentHeight,
            [int]$Display.CurrentBpp,
            [int]$TargetHz
        )
    } catch {
        Write-Host "Promena Hz nije uspela: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    if ([int]$r.TestCode -ne 0) {
        Write-Host "Windows/driver nije prihvatio TEST za $TargetHz Hz (kod $($r.TestCode), Win32 $($r.LastError))." -ForegroundColor Red
        return $false
    }
    if ([int]$r.ApplyCode -ne 0) {
        Write-Host "Windows nije primenio $TargetHz Hz (kod $($r.ApplyCode), Win32 $($r.LastError))." -ForegroundColor Red
        return $false
    }

    Start-Sleep -Milliseconds 1200
    $after = @(Get-DisplayInventory | Select-Object -First 1)
    if ($after.Count -gt 0 -and [int]$after[0].CurrentHz -gt 1) {
        Write-Host "Primarni ekran: sada prijavljuje $($after[0].CurrentWidth)x$($after[0].CurrentHeight) @ $($after[0].CurrentHz) Hz." -ForegroundColor Green
        if ([int]$after[0].CurrentHz -eq $TargetHz) { return $true }
        Write-Host "Windows je prihvatio zahtev za $TargetHz Hz, ali trenutno prijavljuje $($after[0].CurrentHz) Hz." -ForegroundColor Yellow
        return $true
    }

    Write-Host "Windows je prihvatio $TargetHz Hz. Rezolucija nije trazena da se menja." -ForegroundColor Green
    return $true
}

function Set-MaxDisplayHzCurrentResolution {
    $inv = @(Get-DisplayInventory)
    if ($inv.Count -eq 0) { Write-Host 'Nisam uspeo da procitam podatke primarnog ekrana.' -ForegroundColor Red; return }
    $d = $inv[0]
    $target = [int]$d.MaxHzCurrentResolution
    if ($target -le 1) { Write-Host 'Nema pouzdano prijavljene Hz vrednosti za automatsko podesavanje.' -ForegroundColor Yellow; return }

    $backup = Join-Path $RepairBackupRoot ("display_hz_before_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try { $d | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backup -Encoding UTF8 } catch {}

    if ([int]$d.CurrentHz -eq $target) {
        Write-Host "Primarni ekran je vec na najvecoj prijavljenoj vrednosti: $target Hz." -ForegroundColor Green
        return
    }
    [void](Set-KiRoDisplayHz -Display $d -TargetHz $target)
}

function Display-OptimizationMenu {
    while ($true) {
        Write-Header
        Write-Host 'EKRAN - FPS / Hz PODESAVANJE' -ForegroundColor Cyan
        Write-Host 'Rezolucija se NE menja. KiRo podesava samo osvezavanje ekrana (Hz).' -ForegroundColor Green
        Write-Host 'Hz monitora odredjuje koliko frejmova ekran moze da prikaze; stvarni FPS igre zavisi i od GPU-a i same igre.' -ForegroundColor Yellow
        Write-Host ''

        $inv = @(Get-DisplayInventory)
        if ($inv.Count -eq 0) {
            Write-Host 'Nisam uspeo da procitam ni osnovne podatke primarnog ekrana.' -ForegroundColor Red
            if ($script:DisplayApiInitError) { Write-Host "Display API: $script:DisplayApiInitError" -ForegroundColor DarkYellow }
            Write-Host ''
            Write-Host '[1] Otvori Windows Advanced display settings' -ForegroundColor White
            Write-Host '[0] Nazad' -ForegroundColor DarkGray
            $fc = Read-Host 'Izaberi opciju'
            if ($fc -eq '1') { try { Start-Process 'ms-settings:display-advanced' } catch {} }
            if ($fc -eq '0') { return }
            continue
        }

        $d = $inv[0]
        $hzList = if (@($d.AvailableHz).Count -gt 0) { (@($d.AvailableHz) -join ', ') + ' Hz' } else { 'nije moguce pouzdano procitati' }
        $curHzTxt = if ([int]$d.CurrentHz -gt 1) { "$($d.CurrentHz) Hz" } else { 'nije prijavljeno' }
        Write-Host "Primarni ekran: $($d.CurrentWidth)x$($d.CurrentHeight) @ $curHzTxt" -ForegroundColor White
        Write-Host "Dostupne Hz vrednosti za TRENUTNU rezoluciju: $hzList" -ForegroundColor Cyan
        Write-Host "Metoda citanja: $($d.Source)" -ForegroundColor DarkGray
        if ($d.EnumLastError -gt 0) { Write-Host "Win32 EnumDisplaySettings kod: $($d.EnumLastError) (koriscen je fallback)." -ForegroundColor DarkGray }
        Write-Host ''

        if (@($d.AvailableHz).Count -gt 0) {
            Write-Host '[1] Postavi najveci prijavljeni Hz za trenutnu rezoluciju' -ForegroundColor Green
            Write-Host '[2] Izaberi Hz rucno' -ForegroundColor White
        } else {
            Write-Host '[1] Automatsko podesavanje nije dostupno jer Windows/monitor nije prijavio listu Hz vrednosti.' -ForegroundColor DarkGray
            Write-Host '[2] Rucno podesavanje nije dostupno bez pouzdane liste podrzanih Hz vrednosti.' -ForegroundColor DarkGray
        }
        Write-Host '[3] Otvori Windows Advanced display settings' -ForegroundColor White
        Write-Host '[0] Nazad' -ForegroundColor DarkGray
        $c = Read-Host 'Izaberi opciju'

        switch ($c) {
            '1' {
                if (@($d.AvailableHz).Count -eq 0) { Write-Host 'Nema pouzdane liste Hz vrednosti.' -ForegroundColor Yellow; Pause-KiRo; continue }
                $target = [int]$d.MaxHzCurrentResolution
                Write-Host "KiRo ce zadrzati $($d.CurrentWidth)x$($d.CurrentHeight) i pokusati $target Hz." -ForegroundColor Yellow
                $yes = Read-Host 'Upisi DA za primenu'
                if ($yes.ToUpper() -eq 'DA') { Set-MaxDisplayHzCurrentResolution; Pause-KiRo }
            }
            '2' {
                $allowed = @($d.AvailableHz)
                if ($allowed.Count -eq 0) { Write-Host 'Nema pouzdane liste Hz vrednosti.' -ForegroundColor Yellow; Pause-KiRo; continue }
                Write-Host "Dostupno: $($allowed -join ', ') Hz" -ForegroundColor Cyan
                $hzRaw = Read-Host 'Upisi zeljeni Hz'
                if ($hzRaw -notmatch '^\d+$') { Write-Host 'Neispravna Hz vrednost.' -ForegroundColor Red; Start-Sleep 1; continue }
                $target = [int]$hzRaw
                if ($allowed -notcontains $target) { Write-Host 'Ta Hz vrednost nije prijavljena kao podrzana za trenutnu rezoluciju.' -ForegroundColor Red; Pause-KiRo; continue }
                $yes = Read-Host "Upisi DA za $target Hz"
                if ($yes.ToUpper() -eq 'DA') { [void](Set-KiRoDisplayHz -Display $d -TargetHz $target); Pause-KiRo }
            }
            '3' { try { Start-Process 'ms-settings:display-advanced' } catch {} }
            '0' { return }
            default { Write-Host 'Nepoznata opcija.' -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

function Scan-PerformanceAndBackground {
    $mem = Get-SystemMemorySnapshot
    if ($mem) {
        $script:ScanDetails['RAM koristi se'] = "$($mem.UsedPct)% ($($mem.UsedMB) MB / $($mem.TotalMB) MB)"
        $script:ScanDetails['RAM slobodno'] = "$($mem.FreeMB) MB"
        if ($mem.UsedPct -ge 90) {
            Add-Finding 'UPOZORENJE' 'RAM/Procesi' "RAM je opterecen $($mem.UsedPct)% (slobodno $($mem.FreeMB) MB)." 'Koristi opciju [8] i zaustavi samo pozadinske programe koje prepoznajes i ne koristis.' '' $false
        } elseif ($mem.UsedPct -ge 80) {
            Add-Finding 'INFO' 'RAM/Procesi' "RAM koristi $($mem.UsedPct)% (slobodno $($mem.FreeMB) MB)." 'Po potrebi koristi opciju [8] za pregled pozadinskih procesa.' '' $false
        }
    }
    $bg = @(Get-UserBackgroundProcesses)
    $bgSum = 0
    if ($bg.Count -gt 0) { $bgSum = [math]::Round((($bg | Measure-Object RAM_MB -Sum).Sum),1) }
    $script:ScanDetails['Pozadinski korisnicki procesi'] = $bg.Count
    $script:ScanDetails['RAM pozadinskih procesa'] = "$bgSum MB"
    $top = @($bg | Where-Object { $_.RAM_MB -ge 500 } | Select-Object -First 5)
    if ($top.Count -gt 0) {
        $names = ($top | ForEach-Object { "$($_.Name)=$($_.RAM_MB)MB" }) -join ', '
        Add-Finding 'INFO' 'Performanse' "Pozadinski procesi sa vecim RAM opterecenjem: $names" 'Opcija [8] prikazuje procese bez prozora i omogucava da zaustavis samo one koje izaberes.' '' $false
    }
}

function Scan-DisplayPerformance {
    try {
        $inv = @(Get-DisplayInventory)
        $script:ScanDetails['Aktivni ekrani'] = $inv.Count
        $i=1
        foreach ($d in $inv) {
            $script:ScanDetails["Ekran $i"] = "$($d.CurrentWidth)x$($d.CurrentHeight) @ $($d.CurrentHz) Hz | max Hz za ovu rezoluciju: $($d.MaxHzCurrentResolution)"
            if ($d.CurrentHz -lt $d.MaxHzCurrentResolution) {
                Add-Finding 'INFO' 'Ekran' "Ekran '$($d.Description)' radi na $($d.CurrentHz) Hz, a za trenutnu rezoluciju $($d.CurrentWidth)x$($d.CurrentHeight) dostupno je $($d.MaxHzCurrentResolution) Hz." 'Koristi opciju [9] ako zelis da podesis najveci Hz. Rezolucija se ne menja.' '' $false
            }
            $i++
        }
    } catch {}
}

function Get-KiRoDirSizeBytes {
    # Brza rekurzivna suma velicina bez Get-ChildItem objekata (radi i bez prava na pojedine foldere).
    param([string]$Path)
    $total = [long]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = [string]$stack.Pop()
        $di = $null
        try { $di = New-Object System.IO.DirectoryInfo $dir } catch { continue }
        $subs = $null
        try { $subs = @($di.EnumerateDirectories()) } catch { $subs = $null }
        if ($subs) { foreach ($s in $subs) { $stack.Push($s.FullName) } }
        $files = $null
        try { $files = @($di.EnumerateFiles()) } catch { $files = $null }
        if ($files) { foreach ($f in $files) { try { $total += $f.Length } catch {} } }
    }
    return $total
}

function Get-TempSizeMB {
    $sum = [long]0
    $targets = @($env:TEMP, (Join-Path $env:WINDIR "Temp")) | Select-Object -Unique
    foreach ($p in $targets) {
        if (Test-Path -LiteralPath $p) {
            try { $sum += Get-KiRoDirSizeBytes $p } catch {}
        }
    }
    [math]::Round($sum / 1MB, 1)
}

function Get-SystemDriveInfo {
    try {
        $letter = $env:SystemDrive.TrimEnd(":")
        # Direktan CIM upit na Storage provider - bez spore Storage PowerShell module.
        $v = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_Volume -Filter "DriveLetter='$letter'" -ErrorAction Stop)
        if ($v.Count -eq 0) { return $null }
        $v = $v[0]
        if ($null -eq $v.Size -or $null -eq $v.SizeRemaining) { return $null }
        $pct = if ($v.Size -gt 0) { [math]::Round(($v.SizeRemaining / $v.Size) * 100, 1) } else { 0 }
        $health = switch ([int]$v.HealthStatus) {
            1 { 'Warning' }
            2 { 'Unhealthy' }
            default { 'Healthy' }
        }
        [pscustomobject]@{
            Drive = "$letter`:"
            FreeGB = [math]::Round($v.SizeRemaining / 1GB, 2)
            TotalGB = [math]::Round($v.Size / 1GB, 2)
            FreePct = $pct
            Health = $health
        }
    } catch {
        $null
    }
}

function Defender-Available {
    [bool](Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)
}

function Test-PendingReboot {
    $pending = $false
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    foreach ($k in $keys) {
        if (Test-Path $k) { $pending = $true }
    }
    try {
        $p = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($p.PendingFileRenameOperations) { $pending = $true }
    } catch {}
    return $pending
}

function Show-ScanProgress([string]$Text) {
    Write-Host ""
    Write-Host ">>> $Text" -ForegroundColor Yellow
}


# ============================================================================
#  MALWARE / TELEGRAM INDIKATORI
#  Ovaj modul SAMO prikazuje i preporucuje. Nista ne brise i nista ne menja.
# ============================================================================

$script:KiRoMalwareCategories = @('Malware','Telegram','Zastita')
$script:KiRoOsCache = $null
$script:KiRoSignatureCache = @{}
$script:KiRoSignatureBudget = 8
$script:KiRoMalwareSeen = @{}
$script:KiRoUserWritableRoots = $null

$script:KiRoRunLocations = @(
    @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Label='HKCU Run' },
    @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Label='HKCU RunOnce' },
    @{ Path='HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Label='HKCU 32-bit Run' },
    @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'; Label='HKCU Policies Run' },
    @{ Path='HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Label='HKLM Run' },
    @{ Path='HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Label='HKLM RunOnce' },
    @{ Path='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Label='HKLM 32-bit Run' },
    @{ Path='HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Label='HKLM 32-bit RunOnce' },
    @{ Path='HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'; Label='HKLM Policies Run' }
)

function Get-KiRoUserWritableRoots {
    if ($script:KiRoUserWritableRoots) { return $script:KiRoUserWritableRoots }
    $list = New-Object System.Collections.ArrayList
    $cand = @(
        $env:APPDATA, $env:LOCALAPPDATA, $env:TEMP, $env:ProgramData, $env:PUBLIC,
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'AppData\LocalLow')
    )
    foreach ($p in $cand) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try { [void]$list.Add(([IO.Path]::GetFullPath($p)).TrimEnd('\')) } catch {}
    }
    $script:KiRoUserWritableRoots = @($list | Select-Object -Unique)
    return $script:KiRoUserWritableRoots
}

function Test-KiRoUserWritablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $full = $null
    try { $full = [IO.Path]::GetFullPath($Path) } catch { return $false }
    foreach ($r in (Get-KiRoUserWritableRoots)) {
        if ($full.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-KiRoCommandIndicators {
    param([string]$Command)
    $hits = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Command)) { return @() }
    $c = $Command
    if ($c -match '(?i)-enc(odedcommand)?\s+[A-Za-z0-9+/=]{30,}') {
        [void]$hits.Add([pscustomobject]@{ Text='PowerShell komanda kodirana u Base64'; High=$true }) }
    if ($c -match '(?i)frombase64string|downloadstring|downloadfile|downloaddata|invoke-expression|invoke-webrequest|net\.webclient|start-bitstransfer|\biex\b') {
        [void]$hits.Add([pscustomobject]@{ Text='preuzimanje ili izvrsavanje koda sa interneta'; High=$true }) }
    if ($c -match '(?i)-windowstyle\s+hidden|-w\s+hidden|\s-nop\b|\s-noprofile\b|\s-noni\b|\s-noninteractive\b|\s-bypass\b') {
        [void]$hits.Add([pscustomobject]@{ Text='skriveno pokretanje PowerShell-a'; High=$true }) }
    if ($c -match '(?i)\bmshta(\.exe)?\b|\bwscript(\.exe)?\b|\bcscript(\.exe)?\b|\brundll32(\.exe)?\b|\bregsvr32(\.exe)?\b') {
        # rundll32/regsvr32 preko sistemskog fajla je normalan Windows obrazac - ne prijavljuj.
        $systemLolbin = ($c -match '(?i)(%windir%|%systemroot%|\\windows\\(system32|syswow64|winsxs)\\|\bsystem32\\)') -and
                        ($c -notmatch '(?i)http|javascript:|scrobj|\.sct|\.hta')
        if (-not $systemLolbin) {
            [void]$hits.Add([pscustomobject]@{ Text='lolbin pokretac (mshta/wscript/rundll32/regsvr32)'; High=$true })
        } }
    if ($c -match '(?i)\.(jpg|jpeg|png|gif|bmp|pdf|doc|docx|xls|xlsx|txt|mp3|mp4|zip|rar|7z)\.(exe|scr|com|bat|cmd|pif|lnk|js|vbs)$') {
        [void]$hits.Add([pscustomobject]@{ Text='dvostruki nastavak (npr. slika.jpg.exe)'; High=$true }) }
    if ($c -match '(?i)\.(vbs|vbe|js|jse|wsf|wsh|hta|scr|pif|jar|ps1)(\s|"|''|$)') {
        [void]$hits.Add([pscustomobject]@{ Text='skript fajl u autostartu'; High=$false }) }
    if ($c -match '(?i)\\(temp|tmp|downloads?)\\[^\\"]+\.(exe|scr|bat|cmd|ps1|vbs|js)(\s|"|$)') {
        [void]$hits.Add([pscustomobject]@{ Text='pokretanje iz Temp ili Downloads foldera'; High=$false }) }
    return @($hits)
}

function Get-KiRoMasqueradeReason {
    param([string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { return $null }
    $leaf = $null
    try { $leaf = [IO.Path]::GetFileName($Target) } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($leaf)) { return $null }
    # Bez putanje ne mozemo tvrditi da imitira sistemski fajl.
    if (-not ([IO.Path]::IsPathRooted($Target) -or $Target -match '[\\/]')) { return $null }
    $sysNames = @('svchost.exe','lsass.exe','csrss.exe','winlogon.exe','services.exe','wininit.exe','smss.exe',
                  'spoolsv.exe','taskhostw.exe','dwm.exe','userinit.exe','conhost.exe','wuauclt.exe',
                  'rundll32.exe','regsvr32.exe','taskmgr.exe','msdtc.exe','lsaiso.exe','sihost.exe')
    if ($sysNames -notcontains $leaf.ToLowerInvariant()) { return $null }
    $full = $null
    try { $full = [IO.Path]::GetFullPath($Target) } catch { $full = $Target }
    $win = ([IO.Path]::GetFullPath($env:WINDIR)).TrimEnd('\')
    foreach ($ok in @("$win\System32", "$win\SysWOW64", "$win\WinSxS")) {
        if ($full.StartsWith($ok, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    }
    return "naziv '$leaf' imitira sistemski proces, a pokrece se iz $full"
}

function Get-KiRoSignatureStatus {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'Nepoznato' }
    if ($script:KiRoSignatureCache.ContainsKey($Path)) { return $script:KiRoSignatureCache[$Path] }
    $res = 'Nepoznato'
    try {
        if (-not [System.IO.File]::Exists($Path)) {
            $res = 'Fajl ne postoji'
        } elseif ($script:KiRoSignatureBudget -le 0) {
            $res = 'Nije provereno (limit provera dostignut)'
        } else {
            $script:KiRoSignatureBudget = $script:KiRoSignatureBudget - 1
            $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $res = [string]$sig.Status
        }
    } catch { $res = 'Nije moguce proveriti' }
    $script:KiRoSignatureCache[$Path] = $res
    return $res
}

function Test-KiRoSuspiciousLaunch {
    param(
        [string]$Command,
        [string]$Arguments = '',
        [string]$Source = 'Autostart'
    )
    if ([string]::IsNullOrWhiteSpace($Command)) { return }
    $fullCmd = ($Command + ' ' + $Arguments).Trim()
    $key = 'launch|' + $fullCmd.ToLowerInvariant()
    if ($script:KiRoMalwareSeen.ContainsKey($key)) { return }
    $script:KiRoMalwareSeen[$key] = $true

    $indicators = @(Get-KiRoCommandIndicators $fullCmd)
    $status = $null
    try { $status = Get-LaunchReferenceStatus $Command } catch {}
    $target = if ($status -and $status.Target) { [string]$status.Target } else { $Command }

    $masq = Get-KiRoMasqueradeReason $target
    $userPath = Test-KiRoUserWritablePath $target

    # Provera digitalnog potpisa je spora na velikim fajlovima (hash celog fajla),
    # zato se radi samo kada vec postoji razlog za sumnju ili je fajl mali.
    $targetExists = $false
    $fileSize = 0
    if ($userPath) {
        try {
            if ([System.IO.File]::Exists($target)) {
                $targetExists = $true
                $fileSize = (New-Object System.IO.FileInfo $target).Length
            }
        } catch {}
    }
    $smallUserFile = ($targetExists -and $fileSize -gt 0 -and $fileSize -lt 41943040)

    $sig = $null
    if ($masq -or $indicators.Count -gt 0 -or $smallUserFile) {
        $sig = Get-KiRoSignatureStatus $target
    }

    $high = @($indicators | Where-Object { $_.High })
    $reasons = New-Object System.Collections.ArrayList
    foreach ($i in $indicators) { [void]$reasons.Add($i.Text) }
    if ($masq) { [void]$reasons.Add($masq) }
    if ($smallUserFile -and $sig -and $sig -ne 'Valid') {
        [void]$reasons.Add("pokrece se iz korisnickog foldera, digitalni potpis: $sig")
    }

    if ($reasons.Count -eq 0) { return }

    if ($masq -or $high.Count -gt 0) { $sev = 'KRITICNO' }
    elseif ($indicators.Count -gt 0) { $sev = 'UPOZORENJE' }
    else { $sev = 'INFO' }
    $rec = switch ($sev) {
        'KRITICNO' { 'Ovo je jak indikator malware-a. Ne pokreci taj fajl. Proveri ga, pa ukloni autostart unos tek kada budes siguran.' }
        'UPOZORENJE' { 'Pregledaj ovaj autostart unos. Ako ga ne prepoznajes, ukloni ga i proveri fajl antivirusom.' }
        default { 'Samo informacija: program se pokrece iz korisnickog foldera i nije digitalno potpisan. Ako ga prepoznajes, mozes ga ignorisati.' }
    }
    $uniq = @($reasons | Select-Object -Unique)
    Add-Finding $sev 'Malware' "$Source pokrece: $fullCmd  |  Razlog: $($uniq -join '; ')" $rec '' $false
}

function Scan-MalwareIndicators {
    foreach ($loc in $script:KiRoRunLocations) {
        if (-not (Test-Path -LiteralPath $loc.Path)) { continue }
        try {
            $key = Get-Item -LiteralPath $loc.Path -ErrorAction Stop
            foreach ($name in @($key.GetValueNames())) {
                try {
                    $cmd = [string]$key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
                    Test-KiRoSuspiciousLaunch -Command $cmd -Source "Autostart '$name' ($($loc.Label))"
                } catch {}
            }
        } catch {}
    }

    try {
        $shell = New-Object -ComObject WScript.Shell
        $folders = @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup')) |
            Where-Object { $_ } | Select-Object -Unique
        foreach ($folder in $folders) {
            if (-not (Test-Path -LiteralPath $folder)) { continue }
            foreach ($lnk in @(Get-ChildItem -LiteralPath $folder -Filter *.lnk -File -ErrorAction SilentlyContinue)) {
                try {
                    $sc = $shell.CreateShortcut($lnk.FullName)
                    $tp = [Environment]::ExpandEnvironmentVariables([string]$sc.TargetPath)
                    if ($tp) { Test-KiRoSuspiciousLaunch -Command $tp -Arguments ([string]$sc.Arguments) -Source "Startup precica '$($lnk.Name)'" }
                } catch {}
            }
        }
    } catch {}

    try {
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            try {
                if ($p.Id -le 4) { continue }
                $path = [string]$p.Path
                if ([string]::IsNullOrWhiteSpace($path)) { continue }
                $reason = Get-KiRoMasqueradeReason $path
                if ($reason) {
                    $k = 'proc|' + $path.ToLowerInvariant()
                    if (-not $script:KiRoMalwareSeen.ContainsKey($k)) {
                        $script:KiRoMalwareSeen[$k] = $true
                        Add-Finding 'KRITICNO' 'Malware' "Aktivan proces imitira sistemski proces: $($p.ProcessName) (PID $($p.Id)) - $reason" 'Zatvori proces i proveri taj fajl pre brisanja. Ovo je cest obrazac malware-a.' '' $false
                    }
                }
            } catch {}
        }
    } catch {}
}

function Scan-TelegramIndicators {
    $allowed = @('telegram.exe','updater.exe','unins000.exe','unins000.dat','unins000.msg')
    $roots = New-Object System.Collections.ArrayList
    foreach ($p in @((Join-Path $env:APPDATA 'Telegram Desktop'), (Join-Path $env:LOCALAPPDATA 'Telegram Desktop'))) {
        if ($p -and (Test-Path -LiteralPath $p)) { [void]$roots.Add($p) }
    }

    foreach ($root in $roots) {
        $badExe = New-Object System.Collections.ArrayList
        $hiddenExe = New-Object System.Collections.ArrayList
        $scripts = New-Object System.Collections.ArrayList
        $lnks = New-Object System.Collections.ArrayList
        $dataFiles = New-Object System.Collections.ArrayList

        foreach ($it in @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
            if ($it.PSIsContainer) { continue }
            $n = [string]$it.Name
            $low = $n.ToLowerInvariant()
            $attr = [string]$it.Attributes
            $isHidden = ($attr -match 'Hidden') -or ($attr -match 'System')
            if ($low -match '\.(exe|scr|com|pif|msi|dll)$') {
                if ($allowed -notcontains $low) {
                    [void]$badExe.Add($n)
                    if ($isHidden) { [void]$hiddenExe.Add($n) }
                }
            } elseif ($low -match '\.(bat|cmd|ps1|vbs|vbe|js|jse|wsf|hta|jar|reg)$') {
                [void]$scripts.Add($n)
            } elseif ($low -match '\.lnk$') {
                [void]$lnks.Add($n)
            } elseif ($low -match '\.(txt|csv|json|zip|rar|7z|dat|log)$' -and
                      $low -match 'combolist|combo|combos|hits|dumps?|stealer|password|account|cookie|logs?\b|@[a-z0-9_]{4,}') {
                [void]$dataFiles.Add($n)
            }
        }

        if ($hiddenExe.Count -gt 0) {
            Add-Finding 'KRITICNO' 'Telegram' "U Telegram folderu je sakriven izvrsni fajl (Hidden/System): $($hiddenExe -join ', ')" 'Sakriven program u Telegram folderu je jak indikator malware-a. Ne pokreci ga; proveri ga pre uklanjanja.' '' $false
        }
        $extraExe = @($badExe | Where-Object { $hiddenExe -notcontains $_ })
        if ($extraExe.Count -gt 0) {
            Add-Finding 'UPOZORENJE' 'Telegram' "U Telegram folderu su izvrsni fajlovi koji ne pripadaju Telegramu: $($extraExe -join ', ')" 'Telegram folder treba da sadrzi samo Telegram.exe, Updater.exe i unins000. Ostalo proveri.' '' $false
        }
        if ($scripts.Count -gt 0) {
            Add-Finding 'UPOZORENJE' 'Telegram' "U Telegram folderu su skript fajlovi: $($scripts -join ', ')" 'Skripte u Telegram folderu su cest nacin sirenja preko Telegram poruka. Proveri ih pre pokretanja.' '' $false
        }
        if ($lnks.Count -gt 0) {
            Add-Finding 'UPOZORENJE' 'Telegram' "U Telegram folderu su precice (.lnk): $($lnks -join ', ')" 'Precica u Telegram folderu moze da pokrene program sa druge lokacije. Otvori svojstva i proveri cilj.' '' $false
        }
        if ($dataFiles.Count -gt 0) {
            Add-Finding 'UPOZORENJE' 'Telegram' "U Telegram folderu su fajlovi koji lice na izvestaje o ukradenim nalozima: $($dataFiles -join ', ')" 'Ako ih nisi sam stavio, verovatno su rezultat kradje podataka. Promeni lozinke i ukljuci dvofaktorsku zastitu.' '' $false
        }
    }

    try {
        foreach ($p in @(Get-Process -Name 'Telegram' -ErrorAction SilentlyContinue)) {
            try {
                $path = [string]$p.Path
                if ([string]::IsNullOrWhiteSpace($path)) { continue }
                if ($path -notmatch '(?i)\\Telegram Desktop\\') {
                    Add-Finding 'UPOZORENJE' 'Telegram' "Telegram proces se pokrece iz neocekivane lokacije: $path" 'Proveri da li je to pravi Telegram. Ako nije, program se mozda predstavlja kao Telegram.' '' $false
                }
            } catch {}
        }
    } catch {}

    try {
        $places = @(
            (Join-Path $env:USERPROFILE 'Downloads'),
            (Join-Path $env:USERPROFILE 'Desktop'),
            (Join-Path $env:USERPROFILE 'Documents'),
            $env:TEMP
        )
        foreach ($pl in $places) {
            if (-not $pl -or -not (Test-Path -LiteralPath $pl)) { continue }
            foreach ($it in @(Get-ChildItem -LiteralPath $pl -Force -ErrorAction SilentlyContinue)) {
                if ($it.Name -match '(?i)^tdata(\.zip|\.rar|\.7z|\.tar|\.gz)?$') {
                    Add-Finding 'KRITICNO' 'Telegram' "Pronadjena je kopija Telegram sesije (tdata) van Telegram foldera: $($it.FullName)" 'Kopija tdata foldera znaci da je neko mogao da preuzme Telegram nalog. Odjavi sve uredjaje u Telegramu i ukljuci dvofaktorsku zastitu.' '' $false
                }
            }
        }
    } catch {}

    try {
        $dirs = @(
            (Join-Path $env:USERPROFILE 'Downloads'),
            (Join-Path $env:USERPROFILE 'Desktop'),
            (Join-Path $env:USERPROFILE 'Documents')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique
        foreach ($d in $dirs) {
            $found = New-Object System.Collections.ArrayList
            foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue)) {
                if ($f.Name -match '(?i)\.(jpg|jpeg|png|gif|bmp|pdf|doc|docx|xls|xlsx|txt|mp3|mp4|zip|rar|7z|dok|slika|faktura|racun)\.(exe|scr|com|bat|cmd|pif|lnk|js|vbs)$') {
                    [void]$found.Add($f.Name)
                }
            }
            if ($found.Count -gt 0) {
                Add-Finding 'KRITICNO' 'Malware' "Fajlovi sa dvostrukim nastavkom u $d : $(($found | Select-Object -First 8) -join ', ')" 'Ovako izgledaju fajlovi koji se siju preko Telegrama i maila. NE otvaraj ih; obrisi ih ili proveri antivirusom.' '' $false
            }
        }
    } catch {}
}

function Scan-SystemTamperIndicators {
    try {
        $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
        foreach ($k in @(Get-ChildItem -LiteralPath $ifeo -ErrorAction SilentlyContinue)) {
            try {
                $dbg = (Get-ItemProperty -LiteralPath $k.PSPath -Name Debugger -ErrorAction Stop).Debugger
                if (-not [string]::IsNullOrWhiteSpace([string]$dbg)) {
                    Add-Finding 'KRITICNO' 'Malware' "Image File Execution Options za '$($k.PSChildName)' ima podesen Debugger: $dbg" 'Ovim se program presrece i umesto njega se pokrece drugi fajl. Ako ovo nisi sam podesio, ukloni unos.' '' $false
                }
            } catch {}
        }
    } catch {}

    foreach ($ap in @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Windows')) {
        try {
            $pp = Get-ItemProperty -LiteralPath $ap -ErrorAction Stop
            $dlls = [string]$pp.AppInit_DLLs
            if (-not [string]::IsNullOrWhiteSpace($dlls) -and [int]$pp.LoadAppInit_DLLs -eq 1) {
                Add-Finding 'UPOZORENJE' 'Malware' "AppInit_DLLs je aktivan i ubacuje: $dlls" 'Ovim se DLL ubacuje u svaki proces. Ako to nije tvoja namerna postavka, ukloni je.' '' $false
            }
        } catch {}
    }

    try {
        foreach ($cls in @('CommandLineEventConsumer','ActiveScriptEventConsumer')) {
            foreach ($c in @(Get-CimInstance -Namespace 'root\subscription' -ClassName $cls -ErrorAction SilentlyContinue)) {
                $detail = [string]$c.CommandLineTemplate
                if (-not $detail) { $detail = [string]$c.ScriptText }
                $show = if ($detail) { $detail.Substring(0, [Math]::Min(160, $detail.Length)) } else { '(bez detalja)' }
                Add-Finding 'KRITICNO' 'Malware' "WMI trajna pretplata '$($c.Name)' pokrece: $show" 'WMI pretplate pokrecu kod bez fajla na disku. Ovo je jak indikator malware-a; ne uklanjaj bez provere.' '' $false
            }
        }
    } catch {}

    try {
        foreach ($d in @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 2 -or $_.DriveType -eq 3 })) {
            $af = "$($d.DeviceID)\autorun.inf"
            if (Test-Path -LiteralPath $af) {
                Add-Finding 'UPOZORENJE' 'Malware' "Na disku $($d.DeviceID) postoji autorun.inf." 'Klasioni USB/Telegram virus koristi autorun.inf. Otvori fajl i proveri sta pokrece.' '' $false
            }
        }
    } catch {}

    try {
        $wd = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
        if ($wd -and [string]$wd.Status -eq 'Running') {
            try {
                $mp = Get-MpPreference -ErrorAction Stop
                $ex = @($mp.ExclusionPath)
                if ($ex.Count -gt 0) {
                    Add-Finding 'UPOZORENJE' 'Zastita' "Defender ima $($ex.Count) iskljucenih putanja: $(($ex | Select-Object -First 6) -join ', ')" 'Malware cesto sam sebi dodaje izuzetke u Defender-u. Ako ih nisi ti dodao, ukloni ih.' '' $false
                }
                if ($mp.DisableRealtimeMonitoring) {
                    Add-Finding 'UPOZORENJE' 'Zastita' 'Defender real-time zastita je iskljucena.' 'Ukljuci real-time zastitu ako zelis aktivnu zastitu.' 'DEFENDER_REALTIME' $true
                }
            } catch {}
        }
    } catch {}

    foreach ($chk in @(
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name='DisableTaskMgr'; Bad=1; Text='Task Manager je zakljucan (DisableTaskMgr=1)' },
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System'; Name='DisableRegistryTools'; Bad=1; Text='Registry Editor je zakljucan (DisableRegistryTools=1)' },
        @{ Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'; Name='EnableLUA'; Bad=0; Text='UAC je iskljucen (EnableLUA=0)' },
        @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name='NoFolderOptions'; Bad=1; Text='Opcije foldera su sakrivene (NoFolderOptions=1)' }
    )) {
        try {
            $val = (Get-ItemProperty -LiteralPath $chk.Path -Name $chk.Name -ErrorAction Stop).($chk.Name)
            if ([int]$val -eq [int]$chk.Bad) {
                Add-Finding 'UPOZORENJE' 'Zastita' $chk.Text 'Malware cesto zakljucava ove alate da bi otezao uklanjanje. Proveri i vrati podrazumevanu vrednost.' '' $false
            }
        } catch {}
    }
}

function Remove-MalwareFindings {
    $keep = @($script:Findings | Where-Object { $script:KiRoMalwareCategories -notcontains [string]$_.Category })
    $script:Findings.Clear()
    $i = 0
    foreach ($f in $keep) {
        $i++
        $f.ID = $i
        [void]$script:Findings.Add($f)
    }
}

function Run-MalwareIndicatorScan {
    Remove-MalwareFindings
    $script:KiRoSignatureCache = @{}
    $script:KiRoSignatureBudget = 8
    $script:KiRoMalwareSeen = @{}
    Write-Host "Malware / Telegram provera indikatora..." -ForegroundColor Magenta
    Write-Host "Ovaj modul NISTA ne brise - samo prikazuje i preporucuje." -ForegroundColor DarkCyan
    Scan-MalwareIndicators
    Scan-TelegramIndicators
    Scan-SystemTamperIndicators
}

function Run-DiagnosticScan {
    Write-Header
    $script:Findings.Clear()
    $script:ScanDetails = [ordered]@{}
    $script:KiRoOsCache = $null
    $script:KiRoSignatureCache = @{}
    $script:KiRoSignatureBudget = 8
    $script:KiRoMalwareSeen = @{}

    Write-Host "Pokrecem FAST dijagnostiku racunara..." -ForegroundColor Green
    Write-Host "Program za sada NISTA ne popravlja i ne brise." -ForegroundColor Yellow
    Write-Host "FAST rezim koristi kratke provere; dubinske provere se rade samo po izboru." -ForegroundColor DarkCyan

    # 1. OS / osnovni podaci
    Show-ScanProgress "1/15  Osnovni podaci sistema"
try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        $script:ScanDetails["Windows"] = "$($os.Caption) | Build $($os.BuildNumber)"
        $script:ScanDetails["RAM"] = "$([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GB"
        $script:ScanDetails["Poslednji boot"] = $os.LastBootUpTime
        $script:KiRoOsCache = $os
    } catch {}

    # 2. Disk / slobodan prostor
Show-ScanProgress "2/15  Diskovi i slobodan prostor"
$sys = Get-SystemDriveInfo
    if ($sys) {
        $script:ScanDetails["System disk"] = "$($sys.Drive) $($sys.FreeGB) GB slobodno od $($sys.TotalGB) GB ($($sys.FreePct)%)"
        if ($sys.FreePct -lt 10) {
            Add-Finding "KRITICNO" "Disk" "Sistemski disk ima samo $($sys.FreePct)% slobodnog prostora." "Oslobodi prostor; bezbedno ciscenje TEMP-a moze pomoci." "TEMP_CLEAN" $true
        } elseif ($sys.FreePct -lt 15) {
            Add-Finding "UPOZORENJE" "Disk" "Sistemski disk ima samo $($sys.FreePct)% slobodnog prostora." "Preporuceno je oslobadjanje prostora." "TEMP_CLEAN" $true
        }
        if ($sys.Health -and $sys.Health -ne "Healthy") {
            Add-Finding "KRITICNO" "Disk" "Windows prijavljuje HealthStatus: $($sys.Health) za sistemski volumen." "Napraviti backup i dodatno proveriti disk." "" $false
        }
    }

    try {
        $physical = @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_PhysicalDisk -ErrorAction Stop)
        $script:ScanDetails["Fizicki diskovi"] = ($physical | ForEach-Object {
            $mt = switch ([int]$_.MediaType) { 3 { 'HDD' } 4 { 'SSD' } 5 { 'SCM' } default { 'Nepoznato' } }
            $hs = switch ([int]$_.HealthStatus) { 1 { 'Warning' } 2 { 'Unhealthy' } default { 'Healthy' } }
            "$($_.FriendlyName): $mt, Health=$hs"
        }) -join " | "
        foreach ($d in $physical) {
            $code = [int]$d.HealthStatus
            if ($code -eq 1 -or $code -eq 2) {
                $hsName = if ($code -eq 1) { 'Warning' } else { 'Unhealthy' }
                Add-Finding "KRITICNO" "Disk" "Disk '$($d.FriendlyName)' prijavljuje HealthStatus: $hsName." "Ne pokusavati agresivne popravke pre backup-a." "" $false
            }
        }
    } catch {}

    # 3. TEMP
Show-ScanProgress "3/15  Privremeni fajlovi"
$tempMB = Get-TempSizeMB
    $script:ScanDetails["TEMP"] = "$tempMB MB"
    if ($tempMB -ge 2000) {
        Add-Finding "UPOZORENJE" "Ciscenje" "TEMP folderi zauzimaju oko $tempMB MB." "Bezbedno ocisti privremene fajlove." "TEMP_CLEAN" $true
    } elseif ($tempMB -ge 500) {
        Add-Finding "INFO" "Ciscenje" "TEMP folderi zauzimaju oko $tempMB MB." "Mozes osloboditi prostor brisanjem privremenih fajlova." "TEMP_CLEAN" $true
    }

    # 4. Defender
Show-ScanProgress "4/15  Microsoft Defender provere"
if (-not [bool]$script:Settings.DefenderChecksEnabled) {
    $script:ScanDetails["Defender provere"] = "ISKLJUCENE u KiRo podesavanjima"
} elseif (Defender-Available) {
    try {
        $st = Get-MpComputerStatus
        $script:ScanDetails["Defender"] = "AV=$($st.AntivirusEnabled), RealTime=$($st.RealTimeProtectionEnabled), SignatureAge=$($st.AntivirusSignatureAge)"
        if (-not $st.AntivirusEnabled) {
            Add-Finding "UPOZORENJE" "Bezbednost" "Microsoft Defender antivirus nije aktivan." "Ako ga namerno drzis iskljucenog, iskljuci Defender provere u KiRo meniju." "" $false
        }
        if (-not $st.RealTimeProtectionEnabled -and $st.AntivirusEnabled) {
            Add-Finding "UPOZORENJE" "Bezbednost" "Defender real-time zastita je iskljucena." "Ukljuci real-time zastitu ako zelis Defender zastitu." "DEFENDER_REALTIME" $true
        }
        if ($st.AntivirusSignatureAge -ge 0 -and $st.AntivirusSignatureAge -lt 3650 -and $st.AntivirusSignatureAge -gt 2) {
            Add-Finding "UPOZORENJE" "Bezbednost" "Defender definicije su stare $($st.AntivirusSignatureAge) dana." "Azuriraj Defender definicije." "DEFENDER_UPDATE" $true
        } elseif ($st.AntivirusSignatureAge -ge 3650) {
            Add-Finding "INFO" "Bezbednost" "Windows vraca nerealan podatak za starost Defender definicija ($($st.AntivirusSignatureAge) dana)." "Proveri Windows Security/Defender status." "" $false
        }
        Write-Host "    Pokrecem Defender Quick Scan..." -ForegroundColor DarkYellow
        try { Start-MpScan -ScanType QuickScan -ErrorAction Stop }
        catch { Add-Finding "UPOZORENJE" "Bezbednost" "Defender Quick Scan nije mogao da se pokrene." "Proveri Defender stanje ili iskljuci Defender provere u KiRo meniju." "" $false }
        $activeThreats=@()
        try { $activeThreats=@(Get-MpThreat -ErrorAction SilentlyContinue) } catch {}
        $script:ScanDetails["Aktivne pretnje"]=$activeThreats.Count
        if ($activeThreats.Count -gt 0) { Add-Finding "KRITICNO" "Malware" "Defender prijavljuje $($activeThreats.Count) aktivnu/e pretnju/e." "Primeni Defender akcije/karantin." "DEFENDER_THREATS" $true }
    } catch { Add-Finding "UPOZORENJE" "Bezbednost" "Defender status nije moguce procitati: $($_.Exception.Message)" "Proveri antivirus servis ili iskljuci Defender provere u KiRo meniju." "" $false }
} else {
    Add-Finding "INFO" "Bezbednost" "Microsoft Defender PowerShell komande nisu dostupne." "Mozes ostaviti Defender provere iskljucene ako ga ne koristis." "" $false
}

    # 5. DISM CheckHealth - BRZA provera
    Show-ScanProgress "5/15  Windows image - brza provera"
try {
        $dismOut = & DISM.exe /Online /Cleanup-Image /CheckHealth 2>&1 | Out-String
        $dismCode = $LASTEXITCODE
        $script:ScanDetails["DISM CheckHealth kod"] = $dismCode

        if ($dismCode -ne 0) {
            Add-Finding "UPOZORENJE" "Windows" "DISM CheckHealth je zavrsio kodom $dismCode." "Pokreni [7] PAMETNA Windows popravka." "SYSTEM_REPAIR" $false
        } else {
            $dismNorm = (([string]$dismOut -replace "`0", ' ') -replace '\s+', ' ').Trim().ToLowerInvariant()
            if ($dismNorm -like '*component store cannot be repaired*' -or $dismNorm -like '*non-repairable*') {
                Add-Finding "UPOZORENJE" "Windows" "DISM CheckHealth prijavljuje ozbiljniji problem sa Windows component store-om." "Pokreni [7] Windows popravku i napravi backup vaznih podataka." "SYSTEM_REPAIR" $false
            } elseif ($dismNorm -like '*the component store is repairable*' -or $dismNorm -like '*component store is repairable*') {
                Add-Finding "UPOZORENJE" "Windows" "DISM CheckHealth prijavljuje da Windows component store treba popravku." "Pokreni [7] Windows popravku; dubinski DISM se pokrece samo ako je potreban." "SYSTEM_REPAIR" $false
            } elseif ($dismNorm -like '*no component store corruption detected*' -or $dismNorm -like '*the operation completed successfully*') {
                $script:ScanDetails["DISM CheckHealth"] = "ISPRAVNO - nema poznate korupcije"
            } else {
                $script:ScanDetails["DISM CheckHealth"] = "Zavrseno - odgovor nije standardan; pogledaj log ako zelis detalje"
            }
        }
    } catch {
        Add-Finding "INFO" "Windows" "Brza DISM provera nije mogla potpuno da se izvrsi." "Ako imas simptome problema, pokreni sistemsku popravku." "SYSTEM_REPAIR" $false
    }
# 6. BRZA provera sistemskih fajlova preko CBS loga
    Show-ScanProgress "6/15  Sistemski fajlovi - brza provera"
try {
        $cbs = Join-Path $env:WINDIR "Logs\CBS\CBS.log"
        if (Test-Path $cbs) {
            # Citamo samo poslednji deo loga, ne ceo fajl.
            $tail = Get-Content -LiteralPath $cbs -Tail 800 -ErrorAction Stop
            $hits = @($tail | Select-String -Pattern "corrupt|cannot repair|repair failed|hash mismatch" -CaseSensitive:$false)
            $script:ScanDetails["CBS recent corruption hits"] = $hits.Count

            if ($hits.Count -gt 0) {
                Add-Finding "UPOZORENJE" "Windows" "U poslednjem delu CBS loga pronadjeno je $($hits.Count) zapisa koji mogu ukazivati na ostecene sistemske fajlove." "Pokreni [7] PAMETNA Windows popravka." "SYSTEM_REPAIR" $false
            } else {
                $script:ScanDetails["CBS brza provera"] = "Nema ociglednih corruption zapisa u poslednjem delu loga"
            }
        } else {
            $script:ScanDetails["CBS brza provera"] = "CBS.log nije pronadjen"
        }
    } catch {
        $script:ScanDetails["CBS brza provera"] = "Nije moguce procitati CBS.log"
    }
# 7. Pending reboot
Show-ScanProgress "7/15  Provera da li Windows ceka restart"
if (Test-PendingReboot) {
        Add-Finding "INFO" "Windows" "Windows ima promene koje cekaju restart." "Sacuvaj rad i restartuj racunar kada ti odgovara." "" $false
        $script:ScanDetails["Pending restart"] = "DA"
    } else {
        $script:ScanDetails["Pending restart"] = "NE"
    }

    # 8. Event logs
Show-ScanProgress "8/15  Kriticne i Error poruke u Event Log-u"
try {
        $since = (Get-Date).AddDays(-3)
        $sysErrors = @(Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=$since} -ErrorAction SilentlyContinue)
        $appErrors = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Level=1,2; StartTime=$since} -ErrorAction SilentlyContinue)
        if (-not [bool]$script:Settings.DefenderChecksEnabled) {
            $sysErrors = @($sysErrors | Where-Object { [string]$_.ProviderName -notmatch 'Defender|Microsoft Security Client|SecurityHealth' })
            $appErrors = @($appErrors | Where-Object { [string]$_.ProviderName -notmatch 'Defender|Microsoft Security Client|SecurityHealth' })
        }
        $script:ScanDetails["System error/critical 3d"] = $sysErrors.Count
        $script:ScanDetails["Application error/critical 3d"] = $appErrors.Count

        if ($sysErrors.Count -ge 20) {
            $topGroups = @($sysErrors | Group-Object ProviderName | Sort-Object Count -Descending)
            $top = ($topGroups | Select-Object -First 3 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ", "
            $mainProvider = if ($topGroups.Count -gt 0) { [string]$topGroups[0].Name } else { '' }
            $fx = if ($mainProvider -match 'Security|Defender|Microsoft Security Client') { 'EVENTLOG_SECURITY' } else { 'EVENTLOG_EXPORT_CLEAR' }
            $rec = if ($fx -eq 'EVENTLOG_SECURITY') { 'Program moze da pokusa Microsoft Security/Defender osvezavanje, sacuva backup System loga i ocisti stare greske iz loga.' } else { 'Program moze da sacuva backup System loga i ocisti stare greske da ostanu samo nove, neresene stavke.' }
            $data = [pscustomobject]@{ LogName='System'; Count=$sysErrors.Count; TopProviders=@($topGroups | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Count=$_.Count } }); MainProvider=$mainProvider }
            Add-Finding "UPOZORENJE" "Event Log" "U System logu ima $($sysErrors.Count) Critical/Error dogadjaja u poslednja 3 dana. Najcesci: $top" $rec $fx $true $data
        }
        if ($appErrors.Count -ge 20) {
            $topGroups = @($appErrors | Group-Object ProviderName | Sort-Object Count -Descending)
            $top = ($topGroups | Select-Object -First 3 | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ", "
            $mainProvider = if ($topGroups.Count -gt 0) { [string]$topGroups[0].Name } else { '' }
            $fx = if ($mainProvider -match 'Security|Defender|Microsoft Security Client') { 'EVENTLOG_SECURITY' } else { 'EVENTLOG_EXPORT_CLEAR' }
            $rec = if ($fx -eq 'EVENTLOG_SECURITY') { 'Program moze da pokusa Microsoft Security/Defender osvezavanje, sacuva backup Application loga i ocisti stare greske iz loga.' } else { 'Program moze da sacuva backup Application loga i ocisti stare greske da ostanu samo nove, neresene stavke.' }
            $data = [pscustomobject]@{ LogName='Application'; Count=$appErrors.Count; TopProviders=@($topGroups | Select-Object -First 5 | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Count=$_.Count } }); MainProvider=$mainProvider }
            Add-Finding "UPOZORENJE" "Event Log" "U Application logu ima $($appErrors.Count) Critical/Error dogadjaja u poslednja 3 dana. Najcesci: $top" $rec $fx $true $data
        }
    } catch {}

    # 9. Startup / scheduled tasks / orphan launch reference
Show-ScanProgress "9/15  Startup, autostart greske i zakazani zadaci"
try {
        $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
        $script:ScanDetails["Startup stavki"] = $startup.Count
        if ($startup.Count -ge 15) {
            Add-Finding "INFO" "Performanse" "Pronadjeno je $($startup.Count) startup stavki." "Pregledaj sta ti zaista treba pri pokretanju Windowsa. Program ih nece nasumicno gasiti." "REVIEW_STARTUP" $false
        }
    } catch {}

    $orphanStartup = 0
    try { $orphanStartup = Scan-OrphanAutoStartEntries } catch {}
    $script:ScanDetails["Pokvarene autostart reference"] = $orphanStartup

    try {
        $taskScan = Scan-OrphanScheduledTasks
        $script:ScanDetails["Non-Microsoft tasks"] = $taskScan.Tasks
        $script:ScanDetails["Pokvareni scheduled tasks"] = $taskScan.Count
    } catch {}

    try {
        $orphanServices = Scan-OrphanAutoServices
        $script:ScanDetails["Auto servisi bez fajla"] = $orphanServices
    } catch {}

    # 10. Network snapshot
Show-ScanProgress "10/15 Aktivne mrezne konekcije"
try {
        $est = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections() |
            Where-Object { $_.State -eq [System.Net.NetworkInformation.TcpState]::Established })
        $script:ScanDetails["Established TCP"] = $est.Count
    } catch {}

Show-ScanProgress "11/15 RAM, pozadinski procesi i performanse"
try { Scan-PerformanceAndBackground } catch {}

Show-ScanProgress "12/15 Ekran - Hz/FPS prikaza"
try { Scan-DisplayPerformance } catch {}

Show-ScanProgress "13/15 Malware indikatori u autostartu i procesima"
try { Scan-MalwareIndicators } catch {}

Show-ScanProgress "14/15 Telegram folder i sumnjivi fajlovi"
try { Scan-TelegramIndicators } catch {}

Show-ScanProgress "15/15 Sistemska zastita, WMI i zakljucani alati"
try { Scan-SystemTamperIndicators } catch {}

    # 16. Pluginovi (v4.2) - automatski ucitani moduli iz foldera Plugins/
    Show-ScanProgress "16/16 Dodatni modulski skenovi: Pluginovi (Plugins/)"
    try {
        $pluginRan = Invoke-KiRoPluginScans
        $script:ScanDetails["Ucitani plugini"] = $script:Plugins.Count
        $script:ScanDetails["Plugin skenova pokrenuto"] = $pluginRan
    } catch {}

    $script:KiRoOsCache = $null
}

function Show-DiagnosticSummary {
    Write-Header
    Write-Host "DIJAGNOSTIKA JE ZAVRSENA" -ForegroundColor Green
    Write-Host ""

    $crit = @($script:Findings | Where-Object Severity -eq "KRITICNO").Count
    $warn = @($script:Findings | Where-Object Severity -eq "UPOZORENJE").Count
    $info = @($script:Findings | Where-Object Severity -eq "INFO").Count

    Write-Host "Ukupno pronadjenih stavki: $($script:Findings.Count)" -ForegroundColor White
    Write-Host "  Kriticno:    $crit" -ForegroundColor Red
    Write-Host "  Upozorenje:  $warn" -ForegroundColor Yellow
    Write-Host "  Informacija: $info" -ForegroundColor Cyan
    Write-Host ""

    if ($script:Findings.Count -eq 0) {
        Write-Host "Nisu pronadjeni problemi po proverama koje ovaj alat radi." -ForegroundColor Green
    } else {
        $script:Findings |
            Select-Object ID, Severity, Category, Problem |
            Format-Table -Wrap -AutoSize
    }

    Write-Host ""
    Write-Host "Log: $LogFile" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-FindingDetails {
    Write-Header
    if ($script:Findings.Count -eq 0) {
        Write-Host "Nema pronadjenih stavki." -ForegroundColor Green
        Pause-KiRo
        return
    }

    foreach ($f in $script:Findings) {
        Write-Host "[$($f.ID)] $($f.Severity) - $($f.Category)" -ForegroundColor Cyan
        Write-Host "Problem:     $($f.Problem)"
        Write-Host "Preporuka:   $($f.Recommendation)"
        if ($f.SafeAutoFix) {
            Write-Host "Automatska popravka: DA" -ForegroundColor Green
        } else {
            Write-Host "Automatska popravka: NE / samo pregled" -ForegroundColor Yellow
        }
        Write-Host "--------------------------------------------------------------------"
    }
    Pause-KiRo
}

function Get-LightSnapshot {
    $sys = Get-SystemDriveInfo
    $temp = Get-TempSizeMB
    $threats = $null
    if (Defender-Available) {
        try { $threats = @(Get-MpThreat -ErrorAction SilentlyContinue).Count } catch {}
    }
    [pscustomobject]@{
        FreeGB = if ($sys) { $sys.FreeGB } else { $null }
        FreePct = if ($sys) { $sys.FreePct } else { $null }
        TempMB = $temp
        Threats = $threats
    }
}

function Show-BeforeAfterSimple($Before, $After, [string]$Title) {
    Write-Host ""
    Write-Host "====================================================================" -ForegroundColor Cyan
    Write-Host "PRE -> POSLE : $Title" -ForegroundColor Cyan
    Write-Host "====================================================================" -ForegroundColor Cyan
    if ($null -ne $Before.FreeGB -and $null -ne $After.FreeGB) {
        $delta = [math]::Round($After.FreeGB - $Before.FreeGB, 2)
        Write-Host "Slobodan prostor: $($Before.FreeGB) GB -> $($After.FreeGB) GB  (promena $delta GB)"
    }
    if ($null -ne $Before.TempMB -and $null -ne $After.TempMB) {
        $removed = [math]::Max(0, [math]::Round($Before.TempMB - $After.TempMB, 1))
        Write-Host "TEMP:            $($Before.TempMB) MB -> $($After.TempMB) MB  (ocisceno $removed MB)"
    }
    if ($null -ne $Before.Threats -and $null -ne $After.Threats) {
        Write-Host "Aktivne pretnje: $($Before.Threats) -> $($After.Threats)"
    }
    Write-Host "====================================================================" -ForegroundColor Cyan
}

function Clear-TempSafe {
    $targets = @($env:TEMP, (Join-Path $env:WINDIR "Temp")) | Select-Object -Unique
    foreach ($p in $targets) {
        if (Test-Path $p) {
            Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    }
    try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}
}


function Export-AndClearEventLog {
    param([Parameter(Mandatory=$true)][string]$LogName)

    $dir = Join-Path $RepairBackupRoot 'Event_Logs'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $safeName = ($LogName -replace '[\\/:*?"<>|]', '_')
    $backup = Join-Path $dir ("{0}_{1}.evtx" -f $safeName, (Get-Date -Format 'yyyyMMdd_HHmmssfff'))
    $ok = $false
    try {
        & wevtutil.exe epl $LogName $backup /ow:true | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $backup)) {
            $ok = $true
        } else {
            $backup = $null
        }
    } catch {
        $backup = $null
    }

    try {
        & wevtutil.exe cl $LogName | Out-Null
        $clearOk = ($LASTEXITCODE -eq 0)
    } catch {
        $clearOk = $false
    }

    [pscustomobject]@{ BackupPath = $backup; Cleared = $clearOk; BackupMade = $ok }
}

function Repair-SecurityStackLight {
    $svcList = if ([bool]$script:Settings.DefenderChecksEnabled) { @('wscsvc','SecurityHealthService','WinDefend','WdNisSvc') } else { @('wscsvc','SecurityHealthService') }
    foreach ($svcName in $svcList) {
        try {
            $svc = Get-Service -Name $svcName -ErrorAction Stop
            if ($svc.StartType -ne 'Disabled' -and $svc.Status -ne 'Running') {
                try { Start-Service -Name $svcName -ErrorAction Stop } catch {}
            }
        } catch {}
    }

    if ([bool]$script:Settings.DefenderChecksEnabled -and (Defender-Available)) {
        try { Update-MpSignature -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { Start-MpScan -ScanType QuickScan -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
}

function Disable-BrokenScheduledTaskWithBackup {
    param(
        [Parameter(Mandatory=$true)]$TaskData,
        [switch]$MicrosoftTask
    )

    $fullTaskName = ([string]$TaskData.TaskPath + [string]$TaskData.TaskName)
    if (-not $fullTaskName.StartsWith('\')) { $fullTaskName = '\' + $fullTaskName }

    $task = Get-ScheduledTask -TaskName $TaskData.TaskName -TaskPath $TaskData.TaskPath -ErrorAction Stop
    $stillBroken = $false
    foreach ($a in @($task.Actions)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$a.Execute)) {
            $st = Get-LaunchReferenceStatus ([string]$a.Execute)
            if ($st -and -not $st.Exists) { $stillBroken = $true; break }
        }
    }
    if (-not $stillBroken) {
        Write-Host "Zadatak vise ne pokazuje na nepostojeci fajl. Ne menjam ga." -ForegroundColor Green
        return [pscustomobject]@{ Success=$true; Changed=$false; XmlBackup=$null; Method='AlreadyOK' }
    }

    # Uvek napravi ceo backup lanac pre upisa XML-a.
    # TaskPath sadrzi backslash-e (npr. \Microsoft\Windows\UpdateOrchestrator\),
    # pa ime fajla mora eksplicitno da zameni i '\' i '/'.
    New-Item -ItemType Directory -Force -Path $RepairBackupRoot | Out-Null
    $dir = Join-Path $RepairBackupRoot 'Scheduled_Tasks'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $rawTaskName = [string]($TaskData.TaskPath + $TaskData.TaskName)
    $safeName = ($rawTaskName -replace '[\\/:*?"<>|]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'task' }
    $xmlPath = Join-Path $dir ("{0}_{1}.xml" -f $safeName, (Get-Date -Format 'HHmmssfff'))

    # Dodatna zastita: ako bi put ipak sadrzao podfolder, napravi ga pre Set-Content.
    $xmlParent = Split-Path -Parent $xmlPath
    if ($xmlParent) { New-Item -ItemType Directory -Force -Path $xmlParent | Out-Null }
    $backupOk = $false

    # Prvo PowerShell export; ako Microsoft task to odbije, koristi schtasks /Query /XML.
    try {
        Export-ScheduledTask -TaskName $TaskData.TaskName -TaskPath $TaskData.TaskPath -ErrorAction Stop | Set-Content -LiteralPath $xmlPath -Encoding Unicode
        if (Test-Path -LiteralPath $xmlPath -PathType Leaf) { $backupOk = $true }
    } catch {}
    if (-not $backupOk) {
        try {
            $xmlRaw = & schtasks.exe /Query /TN $fullTaskName /XML 2>$null
            if ($LASTEXITCODE -eq 0 -and $xmlRaw) {
                $xmlRaw | Set-Content -LiteralPath $xmlPath -Encoding Unicode
                $backupOk = (Test-Path -LiteralPath $xmlPath -PathType Leaf)
            }
        } catch {}
    }

    if (-not $backupOk) {
        Write-Host 'Nisam uspeo da napravim backup zakazanog zadatka. Zbog bezbednosti ga ne menjam.' -ForegroundColor Red
        return [pscustomobject]@{ Success=$false; Changed=$false; XmlBackup=$null; Method='BackupFailed' }
    }

    # Ako je task trenutno aktivan, prvo ga zaustavi. Greška ovde nije fatalna.
    try { Stop-ScheduledTask -TaskName $TaskData.TaskName -TaskPath $TaskData.TaskPath -ErrorAction SilentlyContinue } catch {}
    try { & schtasks.exe /End /TN $fullTaskName 2>$null | Out-Null } catch {}

    $disabled = $false
    $method = ''
    try {
        Disable-ScheduledTask -TaskName $TaskData.TaskName -TaskPath $TaskData.TaskPath -ErrorAction Stop | Out-Null
        $disabled = $true
        $method = 'Disable-ScheduledTask'
    } catch {
        Write-Host "PowerShell nije uspeo da iskljuci task: $($_.Exception.Message)" -ForegroundColor DarkYellow
    }

    # Fallback je posebno vazan za zasticene Microsoft UpdateOrchestrator zadatke.
    if (-not $disabled) {
        try {
            & schtasks.exe /Change /TN $fullTaskName /Disable 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $disabled = $true
                $method = 'schtasks /Change /Disable'
            }
        } catch {}
    }

    # Ne verujemo samo izlazu komande: proveri stvarno stanje zadatka.
    Start-Sleep -Milliseconds 400
    try {
        $verify = Get-ScheduledTask -TaskName $TaskData.TaskName -TaskPath $TaskData.TaskPath -ErrorAction Stop
        if ([string]$verify.State -eq 'Disabled') { $disabled = $true }
        elseif ($verify.Settings -and $verify.Settings.Enabled -eq $false) { $disabled = $true }
    } catch {}

    if (-not $disabled) {
        Write-Host 'Task nije mogao da se iskljuci. Backup je sacuvan, ali problem ostaje.' -ForegroundColor Red
        Write-Host "XML backup: $xmlPath" -ForegroundColor DarkGray
        return [pscustomobject]@{ Success=$false; Changed=$false; XmlBackup=$xmlPath; Method='DisableFailed' }
    }

    Save-RepairBackupRecord ([pscustomobject]@{
        Time = (Get-Date).ToString('o')
        Type = if ($MicrosoftTask) { 'MicrosoftScheduledTask' } else { 'ScheduledTask' }
        TaskName = $TaskData.TaskName
        TaskPath = $TaskData.TaskPath
        Execute = $TaskData.Execute
        XmlBackup = $xmlPath
        Action = 'Disabled'
        Method = $method
    })
    if ($MicrosoftTask) {
        Write-Host "Pokvareni Microsoft zakazani zadatak je ISKLJUCEN (nije obrisan)." -ForegroundColor Green
    } else {
        Write-Host "Pokvareni zakazani zadatak je ISKLJUCEN (nije obrisan)." -ForegroundColor Green
    }
    if ($method) { Write-Host "Metoda: $method" -ForegroundColor DarkGray }
    Write-Host "XML backup: $xmlPath" -ForegroundColor DarkGray
    return [pscustomobject]@{ Success=$true; Changed=$true; XmlBackup=$xmlPath; Method=$method }
}


function Backup-ScheduledTaskXmlOnly {
    param([Parameter(Mandatory=$true)]$TaskData)

    $fullTaskName = ([string]$TaskData.TaskPath + [string]$TaskData.TaskName)
    if (-not $fullTaskName.StartsWith('\\')) { $fullTaskName = '\\' + $fullTaskName.TrimStart('\') }

    New-Item -ItemType Directory -Force -Path $RepairBackupRoot | Out-Null
    $dir = Join-Path $RepairBackupRoot 'Scheduled_Tasks'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $rawTaskName = [string]($TaskData.TaskPath + $TaskData.TaskName)
    $safeName = ($rawTaskName -replace '[\\/:*?"<>|]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'task' }
    $xmlPath = Join-Path $dir ("{0}_{1}.xml" -f $safeName, (Get-Date -Format 'HHmmssfff'))

    $backupOk = $false
    try {
        Export-ScheduledTask -TaskName $TaskData.TaskName -TaskPath $TaskData.TaskPath -ErrorAction Stop |
            Set-Content -LiteralPath $xmlPath -Encoding Unicode
        $backupOk = Test-Path -LiteralPath $xmlPath -PathType Leaf
    } catch {}
    if (-not $backupOk) {
        try {
            $xmlRaw = & schtasks.exe /Query /TN $fullTaskName /XML 2>$null
            if ($LASTEXITCODE -eq 0 -and $xmlRaw) {
                $xmlRaw | Set-Content -LiteralPath $xmlPath -Encoding Unicode
                $backupOk = Test-Path -LiteralPath $xmlPath -PathType Leaf
            }
        } catch {}
    }

    if ($backupOk) {
        Save-RepairBackupRecord ([pscustomobject]@{
            Time=(Get-Date).ToString('o'); Type='ScheduledTaskXmlBackup';
            TaskName=$TaskData.TaskName; TaskPath=$TaskData.TaskPath; XmlBackup=$xmlPath
        })
        return $xmlPath
    }
    return $null
}

function Repair-USOUxBrokerSafely {
    param([Parameter(Mandatory=$true)]$TaskData)

    Write-Host ''
    Write-Host 'UPDATE ORCHESTRATOR POPRAVKA - USO_UxBroker' -ForegroundColor Cyan
    Write-Host 'KiRo nece preuzimati vlasnistvo niti menjati ACL dozvole Windows sistemskih taskova.' -ForegroundColor DarkGray

    $xmlBackup = Backup-ScheduledTaskXmlOnly -TaskData $TaskData
    if (-not $xmlBackup) {
        Write-Host 'Nisam uspeo da napravim XML backup taska. Ne menjam nista.' -ForegroundColor Red
        return $false
    }
    Write-Host "XML backup: $xmlBackup" -ForegroundColor DarkGray

    $target = [string]$TaskData.Target
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Write-Host 'MusNotification.exe sada postoji. Task vise nije orphan.' -ForegroundColor Green
        return $true
    }

    Write-Host '1/3 Pokusavam ciljanu SFC proveru nedostajuceg Windows fajla...' -ForegroundColor Yellow
    try { & sfc.exe "/scanfile=$target" | Out-Host } catch {}
    Start-Sleep -Milliseconds 500
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Write-Host 'Fajl je vracen. Problem je resen.' -ForegroundColor Green
        return $true
    }

    Write-Host '2/3 Proveravam Windows component store...' -ForegroundColor Yellow
    $health = Get-KiRoDismHealthState
    if ($health.State -eq 'Repairable') {
        Write-Host 'DISM je potvrdio da Windows component store treba popravku.' -ForegroundColor Yellow
        $ans = (Read-Host 'Pokrenuti RestoreHealth sada? Moze trajati duze. Upisi DA za nastavak').Trim()
        if ($ans -match '^(?i:da|yes|y)$') {
            $rr = Invoke-KiRoTimedProcess -FilePath "$env:SystemRoot\System32\DISM.exe" -Arguments @('/Online','/Cleanup-Image','/RestoreHealth','/NoRestart','/English') -Label 'DISM RestoreHealth'
            if ($rr.ExitCode -eq 0) {
                try { & sfc.exe "/scanfile=$target" | Out-Host } catch {}
            }
        }
    } elseif ($health.State -eq 'Healthy') {
        Write-Host 'Windows component store je zdrav; nema razloga za spori RestoreHealth.' -ForegroundColor Green
    } else {
        Write-Host 'DISM nije dao rezultat koji opravdava automatski RestoreHealth.' -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Write-Host 'MusNotification.exe je vracen. Problem je resen.' -ForegroundColor Green
        return $true
    }

    Write-Host '3/3 Osvezavam Windows Update / UpdateOrchestrator servise i trazim novu registraciju taska...' -ForegroundColor Yellow
    foreach ($svc in @('bits','wuauserv','usosvc')) {
        try {
            $s = Get-Service -Name $svc -ErrorAction Stop
            if ($s.StartType -ne 'Disabled' -and $s.Status -ne 'Running') { Start-Service -Name $svc -ErrorAction SilentlyContinue }
        } catch {}
    }
    try {
        $uso = Join-Path $env:SystemRoot 'System32\UsoClient.exe'
        if (Test-Path -LiteralPath $uso) {
            & $uso RefreshSettings 2>$null | Out-Null
            Start-Sleep -Seconds 1
            & $uso StartScan 2>$null | Out-Null
        }
    } catch {}
    Start-Sleep -Seconds 2

    try {
        $task = Get-ScheduledTask -TaskName $TaskData.TaskName -TaskPath $TaskData.TaskPath -ErrorAction Stop
        $stillBroken = $false
        foreach ($a in @($task.Actions)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$a.Execute)) {
                $st = Get-LaunchReferenceStatus ([string]$a.Execute)
                if ($st -and -not $st.Exists) { $stillBroken = $true; break }
            }
        }
        if (-not $stillBroken) {
            Write-Host 'UpdateOrchestrator task je osvezen i vise ne pokazuje na nepostojeci fajl.' -ForegroundColor Green
            return $true
        }
    } catch {}

    Write-Host ''
    Write-Host 'Task je i dalje stale, ali je Windows zastitio njegovo menjanje.' -ForegroundColor Yellow
    Write-Host 'KiRo ga NAMERNO nije nasilno menjao: nije preuzimao vlasnistvo i nije dirao ACL dozvole.' -ForegroundColor Yellow
    Write-Host 'Ovaj zapis moze ostati kao Windows Update/Task Scheduler problem dok ga Windows Update ne osvezi.' -ForegroundColor Cyan
    try {
        [pscustomobject]@{ Time=(Get-Date).ToString('o'); TaskPath=$TaskData.TaskPath; TaskName=$TaskData.TaskName; Target=$target; Status='ProtectedStale'; Note='Safe repair attempted; no ACL/ownership changes made.' } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:USOStaleMarker -Encoding UTF8
    } catch {}
    Write-Host 'KiRo je zapamtio da je bezbedna popravka vec pokusana i nece vrteti isti postupak pri svakom skenu.' -ForegroundColor DarkGray
    return $false
}

function Repair-MissingWindowsTaskTarget {
    param([Parameter(Mandatory=$true)][object]$TaskData)
    $target = [string]$TaskData.Target
    if ([string]::IsNullOrWhiteSpace($target)) { Write-Host 'Nema ciljnog fajla.' -ForegroundColor Red; return }
    if (Test-Path -LiteralPath $target -PathType Leaf) { Write-Host 'Ciljni Windows fajl sada postoji.' -ForegroundColor Green; return }
    $winRoot = [IO.Path]::GetFullPath($env:WINDIR).TrimEnd('\')
    $targetFull = $null
    try { $targetFull = [IO.Path]::GetFullPath($target) } catch {}
    if (-not $targetFull -or -not $targetFull.StartsWith($winRoot,[System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host 'Cilj nije u Windows folderu; ne pokrecem sistemsku popravku.' -ForegroundColor Yellow; return
    }
    Write-Host "Pokusavam ciljanu SFC popravku: $targetFull" -ForegroundColor Yellow
    & sfc.exe "/scanfile=$targetFull"
    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $targetFull -PathType Leaf) {
        Write-Host 'Nedostajuci Windows fajl je vracen. Zakazani zadatak ostaje ukljucen.' -ForegroundColor Green
    } else {
        Write-Host 'Ciljana SFC popravka nije vratila fajl.' -ForegroundColor Yellow

        # Poseban bezbedan fallback za stari/pokvareni UpdateOrchestrator USO_UxBroker task.
        # Ako Windows vise nema MusNotification.exe, task samo pravi gresku pri pokretanju.
        # Ne brisemo task: prvo ga izvozimo u XML backup pa ga samo iskljucimo.
        $isUsoUxBroker = (([string]$TaskData.TaskPath -ieq '\Microsoft\Windows\UpdateOrchestrator\') -and
                          ([string]$TaskData.TaskName -ieq 'USO_UxBroker') -and
                          ([IO.Path]::GetFileName($targetFull) -ieq 'MusNotification.exe'))
        if ($isUsoUxBroker) {
            Write-Host 'Prepoznat je USO_UxBroker koji pokazuje na nepostojeci MusNotification.exe.' -ForegroundColor Yellow
            $usoOk = Repair-USOUxBrokerSafely -TaskData $TaskData
            if ($usoOk) {
                Write-Host 'USO_UxBroker popravka je uspela. Ponovni FAST sken vise ne bi trebalo da ga prijavi.' -ForegroundColor Green
            } else {
                Write-Host 'USO_UxBroker ostaje neresen jer Windows nije obnovio cilj niti dozvolio bezbednu izmenu taska.' -ForegroundColor Yellow
            }
        } else {
            Write-Host 'Problem ostaje na listi. Pokreni [7] WINDOWS POPRAVKA ako sumnjas na sistemsko ostecenje.' -ForegroundColor Cyan
        }
    }
}


function Invoke-KiRoTimedProcess {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [Parameter(Mandatory=$true)][string]$Label
    )

    $outFile = Join-Path $env:TEMP ("KiRo_{0}_{1}.out.txt" -f ([IO.Path]::GetFileNameWithoutExtension($FilePath)), ([guid]::NewGuid().ToString('N')))
    $errFile = Join-Path $env:TEMP ("KiRo_{0}_{1}.err.txt" -f ([IO.Path]::GetFileNameWithoutExtension($FilePath)), ([guid]::NewGuid().ToString('N')))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $lastMsg = -30
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds 2
            $sec = [int]$sw.Elapsed.TotalSeconds
            if (($sec - $lastMsg) -ge 15) {
                $lastMsg = $sec
                $ts = $sw.Elapsed.ToString('hh\:mm\:ss')
                Write-Host ("{0} i dalje radi... vreme: {1}" -f $Label,$ts) -ForegroundColor DarkGray
                Write-Host 'Napomena: procenat moze duze da stoji na istoj vrednosti iako proces i dalje radi.' -ForegroundColor DarkGray
            }
        }
        $proc.WaitForExit()
        $sw.Stop()
        $stdout = if (Test-Path $outFile) { Get-Content $outFile -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path $errFile) { Get-Content $errFile -Raw -ErrorAction SilentlyContinue } else { '' }
        if ($stdout) { Write-Host $stdout }
        if ($stderr) { Write-Host $stderr -ForegroundColor DarkYellow }
        return [pscustomobject]@{ ExitCode=$proc.ExitCode; StdOut=$stdout; StdErr=$stderr; Elapsed=$sw.Elapsed }
    } catch {
        $sw.Stop()
        Write-Host ("Ne mogu da pokrenem {0}: {1}" -f $Label,$_.Exception.Message) -ForegroundColor Red
        return [pscustomobject]@{ ExitCode=999; StdOut=''; StdErr=$_.Exception.Message; Elapsed=$sw.Elapsed }
    } finally {
        Remove-Item $outFile,$errFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-KiRoDismHealthState {
    Write-Host 'Brza provera Windows component store-a (DISM CheckHealth)...' -ForegroundColor Cyan

    # CheckHealth je veoma brz, zato ga citamo direktno iz PowerShell-a. Ovo je
    # pouzdanije od redirected Start-Process izlaza na nekim Windows 11 buildovima.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lines = @()
    try {
        $lines = @(& DISM.exe /Online /Cleanup-Image /CheckHealth /English 2>&1)
        $exitCode = $LASTEXITCODE
    } catch {
        $lines = @($_.Exception.Message)
        $exitCode = 999
    }
    $sw.Stop()

    foreach ($line in $lines) {
        if ($null -ne $line) { Write-Host ([string]$line) }
    }

    $rawText = [string]::Join("`n", @($lines | ForEach-Object { [string]$_ }))
    $text = (($rawText -replace "`0", ' ') -replace '\s+', ' ').Trim().ToLowerInvariant()
    $state = 'Unknown'

    # Poruke o stanju imaju prednost nad exit code-om.
    if ($text -match 'component store cannot be repaired|non-repairable') {
        $state = 'NonRepairable'
    }
    elseif ($text -match 'the component store is repairable|component store is repairable') {
        $state = 'Repairable'
    }
    elseif ($text -match 'no component store corruption detected') {
        $state = 'Healthy'
    }
    elseif ($exitCode -eq 0 -and $text -match 'the operation completed successfully') {
        $state = 'Healthy'
    }
    elseif ($exitCode -eq 0) {
        # CheckHealth je zavrsio bez greske i nije prijavio repairable/cannot repair.
        # Ne pokrecemo spore korake samo zato sto je tekst lokalizovan ili drugacije formatiran.
        $state = 'Healthy'
    }
    else {
        $state = 'Error'
    }

    $r = [pscustomobject]@{ ExitCode=$exitCode; StdOut=$rawText; StdErr=''; Elapsed=$sw.Elapsed }
    return [pscustomobject]@{ State=$state; Result=$r; NormalizedText=$text }
}

function Invoke-KiRoQuickWindowsRepair {
    Write-Header
    Write-Host 'QUICK WINDOWS REPAIR' -ForegroundColor Green
    Write-Host 'Prvo se radi samo brzi CheckHealth. Spori RestoreHealth se NE pokrece automatski.' -ForegroundColor Cyan
    Write-Host ''
    $h = Get-KiRoDismHealthState
    switch ($h.State) {
        'Healthy' {
            Write-Host 'Windows component store je ISPRAVAN - nije pronadjena korupcija.' -ForegroundColor Green
            Write-Host 'Dubinska ScanHealth/RestoreHealth popravka NIJE potrebna.' -ForegroundColor Green
        }
        'Repairable' {
            Write-Host 'Windows je potvrdio da component store treba popravku.' -ForegroundColor Yellow
            Write-Host 'Za stvarnu popravku izaberi [7] pa [2] DUBINSKA popravka.' -ForegroundColor Cyan
        }
        'NonRepairable' {
            Write-Host 'DISM prijavljuje ozbiljniji problem koji standardni RestoreHealth mozda ne moze da popravi.' -ForegroundColor Red
            Write-Host 'Preporuka: napravi backup vaznih podataka pre daljih zahvata.' -ForegroundColor Yellow
        }
        default {
            Write-Host 'CheckHealth nije dao pouzdan odgovor. Dubinski ScanHealth nije pokrenut da se ne bi nepotrebno cekalo.' -ForegroundColor Yellow
            Write-Host 'Ako imas stvarne Windows probleme, izaberi [7] pa [2] DUBINSKA popravka.' -ForegroundColor Cyan
        }
    }
    Pause-KiRo
}

function Invoke-KiRoDeepWindowsRepair {
    Write-Header
    Write-Host 'DUBINSKA WINDOWS POPRAVKA' -ForegroundColor Yellow
    Write-Host 'KiRo prvo proverava stanje i pokrece spore korake samo kada su potrebni.' -ForegroundColor Cyan
    Write-Host ''

    $h = Get-KiRoDismHealthState
    $needRestore = $false

    if ($h.State -eq 'Healthy') {
        Write-Host 'CheckHealth ne prijavljuje korupciju. RestoreHealth se preskace.' -ForegroundColor Green
        $sfcChoice = Read-Host 'Zelis li ipak SFC /scannow proveru sistemskih fajlova? (DA/NE)'
        if ($sfcChoice.ToUpper() -eq 'DA') {
            $sfc = Invoke-KiRoTimedProcess -FilePath 'sfc.exe' -Arguments @('/scannow') -Label 'SFC /scannow'
            Write-Host ("SFC kod: {0}" -f $sfc.ExitCode) -ForegroundColor Cyan
        }
        return
    }

    if ($h.State -eq 'Repairable') {
        $needRestore = $true
    } elseif ($h.State -eq 'NonRepairable') {
        Write-Host 'Standardni DISM RestoreHealth verovatno nije dovoljan. Zaustavljam automatsku popravku.' -ForegroundColor Red
        return
    } else {
        Write-Host 'CheckHealth nije dovoljan. Pokrecem ScanHealth da proverim da li je korupcija stvarno prisutna.' -ForegroundColor Yellow
        $scan = Invoke-KiRoTimedProcess -FilePath 'DISM.exe' -Arguments @('/Online','/Cleanup-Image','/ScanHealth','/English') -Label 'DISM ScanHealth'
        $scanText = (($scan.StdOut + "`n" + $scan.StdErr)).ToLowerInvariant()
        if ($scan.ExitCode -eq 0 -and $scanText -match 'no component store corruption detected') {
            Write-Host 'ScanHealth nije pronasao korupciju. RestoreHealth se preskace.' -ForegroundColor Green
            return
        }
        if ($scan.ExitCode -eq 0) { $needRestore = $true }
        else {
            Write-Host 'ScanHealth nije zavrsen uspesno. RestoreHealth se ne pokrece naslepo.' -ForegroundColor Red
            return
        }
    }

    if ($needRestore) {
        Write-Host ''
        Write-Host 'Korupcija je potvrdjena. Sada je RestoreHealth opravdan i moze trajati duze.' -ForegroundColor Yellow
        $go = Read-Host 'Upisi DA da pokrenem RestoreHealth sada'
        if ($go.ToUpper() -ne 'DA') {
            Write-Host 'RestoreHealth nije pokrenut.' -ForegroundColor Cyan
            return
        }
        $restore = Invoke-KiRoTimedProcess -FilePath 'DISM.exe' -Arguments @('/Online','/Cleanup-Image','/RestoreHealth','/English') -Label 'DISM RestoreHealth'
        Write-Host ("DISM RestoreHealth kod: {0}" -f $restore.ExitCode) -ForegroundColor Cyan
        if ($restore.ExitCode -eq 0) {
            Write-Host 'DISM je zavrsio uspesno. Pokrecem SFC /scannow da proverim i popravim sistemske fajlove.' -ForegroundColor Green
            $sfc = Invoke-KiRoTimedProcess -FilePath 'sfc.exe' -Arguments @('/scannow') -Label 'SFC /scannow'
            Write-Host ("SFC kod: {0}" -f $sfc.ExitCode) -ForegroundColor Cyan
        } else {
            Write-Host 'DISM nije zavrsio uspesno, pa SFC nije automatski pokrenut.' -ForegroundColor Red
        }
    }
}

function Windows-RepairMenu {
    while ($true) {
        Write-Header
        Write-Host 'WINDOWS POPRAVKA' -ForegroundColor Cyan
        Write-Host '[1] QUICK - samo brza CheckHealth provera (bez dugog cekanja)' -ForegroundColor Green
        Write-Host '[2] DUBINSKA - Scan/Restore/SFC samo kada je stvarno potrebno' -ForegroundColor Yellow
        Write-Host '[0] Nazad' -ForegroundColor DarkGray
        Write-Host ''
        $w = Read-Host 'Izaberi opciju'
        switch ($w) {
            '1' { Invoke-KiRoQuickWindowsRepair }
            '2' {
                $ok = Read-Host 'Dubinska popravka moze trajati duze ako se potvrdi korupcija. Upisi DA za nastavak'
                if ($ok.ToUpper() -eq 'DA') {
                    Invoke-KiRoDeepWindowsRepair
                    Write-Host ''
                    Write-Host 'Windows popravka je zavrsena. Radim novi FAST sken da ostanu samo nereseni problemi...' -ForegroundColor Cyan
                    Pause-KiRo
                    Run-DiagnosticScan
                }
            }
            '0' { return }
            default { Write-Host 'Nepoznata opcija.' -ForegroundColor Red; Start-Sleep -Seconds 1 }
        }
    }
}

# ============================================================================
#  SAFETY SNAPSHOT + POPRAVKA IZABRANIH NALAZA
#  Ove funkcije su u engine-u (ne u GUI-u) da bi ih mogao da pozove i
#  pozadinski runspace - tako GUI ostaje responzivan tokom popravke.
# ============================================================================

function Get-SafetyRoot {
    $p = Join-Path $LogRoot 'Safety_Snapshots'
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}

function New-KiRoSafetySnapshot {
    $root = Get-SafetyRoot
    $dir = Join-Path $root (Get-Date -Format 'yyyyMMdd_HHmmss')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $regDir = Join-Path $dir 'Registry'
    $taskDir = Join-Path $dir 'Scheduled_Tasks'
    New-Item -ItemType Directory -Force -Path $regDir,$taskDir | Out-Null

    $startupSnapshot = New-Object System.Collections.ArrayList
    foreach ($loc in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )) {
        try {
            $item = Get-ItemProperty -LiteralPath $loc -ErrorAction Stop
            # VAZNO: $item se NE serializuje direktno. Get-ItemProperty vraca i
            # PSPath/PSDrive/PSProvider objekte, a ConvertTo-Json -Depth 8 nad
            # njima praktično visi (PSDriveInfo/ProviderInfo graf je ogroman).
            # Zato vadimo samo prave vrednosti iz registry-ja, kao string.
            $vals = [ordered]@{}
            foreach ($p in $item.PSObject.Properties) {
                if ($p.Name -like 'PS*') { continue }
                $vals[$p.Name] = [string]$p.Value
            }
            [void]$startupSnapshot.Add([pscustomobject]@{ Path=$loc; Values=$vals })
        } catch {}
    }
    try {
        $startupSnapshot | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $regDir 'startup_snapshot.json') -Encoding UTF8
    } catch {}

    try {
        if (Test-Path -LiteralPath $script:SettingsFile) {
            Copy-Item -LiteralPath $script:SettingsFile -Destination (Join-Path $dir 'KiRo_settings.json') -Force
        }
    } catch {}

    try {
        @($script:Findings) | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath (Join-Path $dir 'findings_before.json') -Encoding UTF8
    } catch {}

    foreach ($f in @($script:Findings)) {
        try {
            if ($f.Data -and $f.Data.Type -eq 'ScheduledTask' -and $f.Data.TaskName) {
                $xml = Export-ScheduledTask -TaskName $f.Data.TaskName -TaskPath $f.Data.TaskPath -ErrorAction Stop
                $safe = (($f.Data.TaskPath + $f.Data.TaskName) -replace '[\\/:*?"<>|]','_').Trim('_')
                $xml | Set-Content -LiteralPath (Join-Path $taskDir ($safe + '.xml')) -Encoding Unicode
            }
        } catch {}
    }

    $manifest = [pscustomobject]@{
        Version='4.0'
        Created=(Get-Date).ToString('o')
        Computer=$env:COMPUTERNAME
        Findings=@($script:Findings).Count
        Note='Safety snapshot before KiRo repair'
    }
    $manifest | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $dir 'manifest.json') -Encoding UTF8
    return $dir
}

# Citljiv naziv akcije za traku u GUI-u (npr. "Cistim TEMP foldere i korpu").
function Get-KiRoFixLabel {
    param($Finding)
    $a = [string]$Finding.FixAction
    $t = switch ($a) {
        'TEMP_CLEAN'             { 'Cistim TEMP foldere i korpu' }
        'ORPHAN_STARTUP_REG'     { 'Iskljucujem pokvaren Startup registry unos' }
        'ORPHAN_STARTUP_LNK'     { 'Premestam pokvarenu Startup precicu u backup' }
        'ORPHAN_SERVICE_DISABLE' { 'Iskljucujem servis koji pokazuje na nepostojeci fajl' }
        'ORPHAN_TASK'            { 'Uklanjam zakazani zadatak sa nepostojecim fajlom' }
        'ORPHAN_TASK_MS'         { 'Uklanjam Microsoft zadatak sa nepostojecim fajlom' }
        'EVENTLOG_EXPORT_CLEAR'  { 'Izvozim i praznim Event Log' }
        'SYSTEM_REPAIR'          { 'Pokrecem Windows popravku (DISM/SFC)' }
        default                  { if ($a) { $a } else { 'Popravka stavke' } }
    }
    $nm = ''
    try {
        $d = $Finding.Data
        if ($d) {
            foreach ($k in @('Name','DisplayName','LogName','ShortcutPath','Target','RegistryPath')) {
                $v = $null
                try { $v = $d.$k } catch {}
                if ($v) { $nm = [string]$v; break }
            }
        }
    } catch {}
    if ($nm) {
        try { $nm = Split-Path -Leaf $nm } catch {}
        if ($nm) { return ($t + ' (' + $nm + ')') }
    }
    return $t
}

function Repair-KiRoSelectedFindings {
    param([object[]]$Findings)

    $total = @($Findings).Count
    Write-Host ">>>  Pravim Safety Snapshot" -ForegroundColor Cyan
    $snap = $null
    try {
        # uzmi POSLEDNJU izlaznu vrednost (return $dir) - otporno na eventualni
        # visak izlaza iz pomocnih funkcija unutar snapshot-a
        $snapOut = @(New-KiRoSafetySnapshot)
        if ($snapOut.Count -gt 0) { $snap = [string]$snapOut[$snapOut.Count - 1] }
    } catch {
        Write-Host ("SNAPSHOT_ERROR: " + $_.Exception.Message) -ForegroundColor Red
    }

    $results  = New-Object System.Collections.ArrayList
    $okCount  = 0
    $badCount = 0
    $i = 0
    foreach ($f in @($Findings)) {
        $i++
        $label = Get-KiRoFixLabel $f
        Write-Host (" >>> {0}/{1}  {2}" -f $i, $total, $label) -ForegroundColor Yellow
        $good = $false
        $msg  = ''
        try {
            $r = Invoke-FixAction $f
            if ($null -ne $r -and $r.PSObject.Properties['Success']) {
                $good = [bool]$r.Success
                $msg  = [string]$r.Message
            } else {
                $good = $true
                $msg  = 'Izmena je izvrsena.'
            }
        } catch {
            $good = $false
            $msg  = $_.Exception.Message
        }
        if ($good) { $okCount++ } else { $badCount++ }
        $mark = if ($good) { 'OK: ' } else { 'GRESKA: ' }
        Write-Host ("      -> " + $mark + $msg) -ForegroundColor $(if ($good) { 'Green' } else { 'Red' })
        [void]$results.Add([pscustomobject]@{
            ID       = [int]$f.ID
            Category = [string]$f.Category
            Action   = [string]$f.FixAction
            Label    = $label
            Success  = $good
            Message  = $msg
        })
    }
    Write-Host (" >>>  Gotovo: uspesno {0}, neuspesno {1}" -f $okCount, $badCount) -ForegroundColor Cyan

    return [pscustomobject]@{
        Snapshot = $snap
        Count    = $total
        Ok       = $okCount
        Bad      = $badCount
        Results  = @($results)
    }
}

# ============================================================================
#  UNDO - vracanje poslednje bezbedno povratne KiRo izmene
#  U engine-u je da bi i GUI mogao da ga pokrene u pozadinskoj niti.
# ============================================================================

$script:UndoHistoryFile = Join-Path $LogRoot 'KiRo_undo_history.txt'

function Get-KiRoUndoSignatures {
    $set = @{}
    if (Test-Path -LiteralPath $script:UndoHistoryFile) {
        foreach ($line in @(Get-Content -LiteralPath $script:UndoHistoryFile -ErrorAction SilentlyContinue)) {
            if ($line) { $set[$line] = $true }
        }
    }
    return $set
}

function Get-KiRoLastReversibleRecord {
    $done = Get-KiRoUndoSignatures
    $types = @('StartupShortcut','MalwareQuarantine')
    $logs = @(Get-ChildItem -LiteralPath $LogRoot -Filter 'startup_repair_backup.jsonl' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    foreach ($log in $logs) {
        $lines = @(Get-Content -LiteralPath $log.FullName -ErrorAction SilentlyContinue)
        for ($i=$lines.Count-1; $i -ge 0; $i--) {
            try { $o = $lines[$i] | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($types -notcontains [string]$o.Type) { continue }
            $sig = "{0}|{1}|{2}|{3}|{4}{5}" -f $o.Time,$o.Type,$o.Name,$o.OriginalPath,$o.TaskPath,$o.TaskName
            if (-not $done.ContainsKey($sig)) {
                return [pscustomobject]@{ Record=$o; Signature=$sig; Log=$log.FullName }
            }
        }
    }
    return $null
}

function Invoke-KiRoUndoLastChange {
    $entry = Get-KiRoLastReversibleRecord
    if (-not $entry) {
        return [pscustomobject]@{
            Success = $false
            Manual  = $false
            Message = 'Nema prethodne KiRo izmene koju mogu automatski da vratim.'
        }
    }

    $o = $entry.Record
    $ok = $false
    $err = ''
    try {
        $src = ''
        if ([string]$o.Type -eq 'StartupShortcut')     { $src = [string]$o.BackupPath }
        elseif ([string]$o.Type -eq 'MalwareQuarantine') { $src = [string]$o.QuarantinePath }

        if ($src -and (Test-Path -LiteralPath $src)) {
            $parent = Split-Path -Parent ([string]$o.OriginalPath)
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            Move-Item -LiteralPath $src -Destination $o.OriginalPath -Force -ErrorAction Stop
            $ok = $true
        } else {
            $err = 'Backup fajl vise ne postoji.'
        }
    } catch {
        $err = $_.Exception.Message
    }

    if ($ok) {
        Add-Content -LiteralPath $script:UndoHistoryFile -Value $entry.Signature -Encoding UTF8
        # Neki zapisi (npr. StartupShortcut) nemaju polje Name, pa bi poruka
        # ostala prazna ("Vraceno:   "). Uzimamo ime fajla kao rezervu.
        $undoName = [string]$o.Name
        if (-not $undoName) {
            try { $undoName = Split-Path -Leaf ([string]$o.OriginalPath) } catch { $undoName = '' }
        }
        if (-not $undoName) { $undoName = [string]$o.Type }
        return [pscustomobject]@{
            Success = $true
            Manual  = $false
            Message = 'Poslednja bezbedno povratna KiRo izmena je vracena.'
            Name    = $undoName
            Path    = [string]$o.OriginalPath
        }
    }

    return [pscustomobject]@{
        Success = $false
        Manual  = $true
        Message = 'Backup zapis postoji, ali ova izmena nije mogla automatski da se vrati.' + [Environment]::NewLine +
                  'Razlog: ' + $err + [Environment]::NewLine + [Environment]::NewLine +
                  'Otvori Backup folder za rucni povratak.'
    }
}

function Invoke-FixAction {
    param([Parameter(Mandatory=$true)]$Finding)

    $before = Get-LightSnapshot
    $script:LastFixOutcome = $null
    Write-Host ""
    Write-Host "POPRAVKA [$($Finding.ID)] - $($Finding.Category)" -ForegroundColor Yellow
    Write-Host "$($Finding.Problem)"
    Write-Host ""

    switch ($Finding.FixAction) {
        "TEMP_CLEAN" {
            Write-Host "Cistim samo bezbedne TEMP lokacije i korpu..."
            $mbBefore = 0
            try { $mbBefore = [int](Get-TempSizeMB) } catch {}
            Clear-TempSafe
            $mbAfter = 0
            try { $mbAfter = [int](Get-TempSizeMB) } catch {}
            $freed = $mbBefore - $mbAfter
            if ($freed -lt 0) { $freed = 0 }
            Write-Host ("Oslobodjeno oko {0} MB (pre: {1} MB, posle: {2} MB)." -f $freed, $mbBefore, $mbAfter) -ForegroundColor Green
            $script:LastFixOutcome = [pscustomobject]@{
                Success = $true
                Message = ("Oslobodjeno oko {0} MB (pre {1} MB, posle {2} MB)." -f $freed, $mbBefore, $mbAfter)
            }
        }
        "DEFENDER_UPDATE" {
            try {
                Update-MpSignature -ErrorAction Stop
                Write-Host "Defender definicije su azurirane." -ForegroundColor Green
            } catch {
                Write-Host "Update nije uspeo: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "DEFENDER_REALTIME" {
            try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Write-Host "Pokusano ukljucivanje Defender real-time zastite." -ForegroundColor Green
            } catch {
                Write-Host "Nije moguce promeniti real-time zastitu: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "DEFENDER_THREATS" {
            try {
                Remove-MpThreat -ErrorAction Stop
                Write-Host "Defender je primenio dostupne akcije nad aktivnim pretnjama." -ForegroundColor Green
            } catch {
                Write-Host "Defender akcija nije potpuno uspela: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "ORPHAN_STARTUP_REG" {
            $d = $Finding.Data
            try {
                $key = Get-Item -LiteralPath $d.RegistryPath -ErrorAction Stop
                $current = [string]$key.GetValue($d.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ([string]::IsNullOrWhiteSpace($current)) {
                    Write-Host "Autostart unos vise ne postoji - nema sta da se popravlja." -ForegroundColor Green
                } elseif ($current -ne [string]$d.Command) {
                    Write-Host "Autostart unos se promenio posle skeniranja. Ne diram ga radi bezbednosti." -ForegroundColor Yellow
                } else {
                    $status = Get-LaunchReferenceStatus $current
                    if ($status -and $status.Exists) {
                        Write-Host "Fajl sada postoji. Ne uklanjam autostart unos." -ForegroundColor Green
                    } else {
                        $regBackup = $null
                        try {
                            $regDir = Join-Path $RepairBackupRoot 'Registry'
                            New-Item -ItemType Directory -Force -Path $regDir | Out-Null
                            $nativePath = [string]$d.RegistryPath
                            $nativePath = $nativePath -replace '^HKCU:', 'HKEY_CURRENT_USER'
                            $nativePath = $nativePath -replace '^HKLM:', 'HKEY_LOCAL_MACHINE'
                            $safeRegName = (($d.LocationLabel + '_' + $d.Name) -replace '[\\/:*?"<>|]', '_')
                            $regBackup = Join-Path $regDir ("{0}_{1}.reg" -f $safeRegName, (Get-Date -Format 'HHmmssfff'))
                            & reg.exe export $nativePath $regBackup /y 2>$null | Out-Null
                            if ($LASTEXITCODE -ne 0) { $regBackup = $null }
                        } catch { $regBackup = $null }

                        Save-RepairBackupRecord ([pscustomobject]@{
                            Time = (Get-Date).ToString('o')
                            Type = 'RegistryStartup'
                            RegistryPath = $d.RegistryPath
                            Name = $d.Name
                            Command = $current
                            ValueKind = $d.ValueKind
                            RegBackup = $regBackup
                        })
                        Remove-ItemProperty -LiteralPath $d.RegistryPath -Name $d.Name -Force -ErrorAction Stop
                        Write-Host "Uklonjena je pokvarena autostart referenca '$($d.Name)'." -ForegroundColor Green
                        if ($regBackup) { Write-Host "Registry backup: $regBackup" -ForegroundColor DarkGray }
                        Write-Host "Backup zapis: $script:RepairBackupLog" -ForegroundColor DarkGray
                    }
                }
            } catch {
                Write-Host "Autostart popravka nije uspela: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "ORPHAN_STARTUP_LNK" {
            $d = $Finding.Data
            try {
                if (-not (Test-Path -LiteralPath $d.ShortcutPath -PathType Leaf)) {
                    Write-Host "Startup precica vise ne postoji - nema sta da se popravlja." -ForegroundColor Green
                } elseif (Test-Path -LiteralPath $d.Target -PathType Leaf) {
                    Write-Host "Ciljni fajl sada postoji. Ne pomeram Startup precicu." -ForegroundColor Green
                } else {
                    $dir = Join-Path $RepairBackupRoot 'Broken_Startup_Shortcuts'
                    New-Item -ItemType Directory -Force -Path $dir | Out-Null
                    $base = [IO.Path]::GetFileNameWithoutExtension($d.ShortcutPath)
                    $ext = [IO.Path]::GetExtension($d.ShortcutPath)
                    $dest = Join-Path $dir ("{0}_{1}{2}" -f $base, (Get-Date -Format 'HHmmssfff'), $ext)
                    Move-Item -LiteralPath $d.ShortcutPath -Destination $dest -Force -ErrorAction Stop
                    Save-RepairBackupRecord ([pscustomobject]@{
                        Time = (Get-Date).ToString('o')
                        Type = 'StartupShortcut'
                        OriginalPath = $d.ShortcutPath
                        BackupPath = $dest
                        Target = $d.Target
                    })
                    Write-Host "Pokvarena Startup precica je premestena u backup." -ForegroundColor Green
                    Write-Host "Backup: $dest" -ForegroundColor DarkGray
                }
            } catch {
                Write-Host "Popravka Startup precice nije uspela: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "ORPHAN_SERVICE_DISABLE" {
            $d = $Finding.Data
            try {
                $svc = Get-CimInstance Win32_Service -Filter ("Name='" + ([string]$d.Name).Replace("'","''") + "'") -ErrorAction Stop
                $st = Get-LaunchReferenceStatus ([string]$svc.PathName)
                if (-not $st -or $st.Exists) {
                    Write-Host 'Servis vise ne pokazuje na nepostojeci fajl. Ne menjam ga.' -ForegroundColor Green
                } else {
                    $regBackup = $null
                    try {
                        $regDir = Join-Path $RepairBackupRoot 'Services'
                        New-Item -ItemType Directory -Force -Path $regDir | Out-Null
                        $safeName = ([string]$d.Name -replace '[\/:*?"<>|]','_')
                        $regBackup = Join-Path $regDir ("{0}_{1}.reg" -f $safeName,(Get-Date -Format 'HHmmssfff'))
                        & reg.exe export ("HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\" + $d.Name) $regBackup /y 2>$null | Out-Null
                        if ($LASTEXITCODE -ne 0) { $regBackup = $null }
                    } catch { $regBackup = $null }
                    try { if ([string]$svc.State -eq 'Running') { Stop-Service -Name $d.Name -Force -ErrorAction SilentlyContinue } } catch {}
                    Set-Service -Name $d.Name -StartupType Disabled -ErrorAction Stop
                    Save-RepairBackupRecord ([pscustomobject]@{Time=(Get-Date).ToString('o');Type='OrphanServiceDisabled';Name=$d.Name;DisplayName=$d.DisplayName;PathName=$svc.PathName;Target=$st.Target;PreviousStartMode=$d.StartMode;RegBackup=$regBackup})
                    Write-Host "Orphan servis '$($d.Name)' je ISKLJUCEN (nije obrisan)." -ForegroundColor Green
                    if ($regBackup) { Write-Host "Registry backup: $regBackup" -ForegroundColor DarkGray }
                }
            } catch {
                Write-Host "Popravka orphan servisa nije uspela: $($_.Exception.Message)" -ForegroundColor Red
            }
        }

        "ORPHAN_TASK" {
            $d = $Finding.Data
            try {
                $null = Disable-BrokenScheduledTaskWithBackup -TaskData $d
            } catch {
                Write-Host "Popravka zakazanog zadatka nije uspela: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "MICROSOFT_TASK_REPAIR" {
            $d = $Finding.Data
            try { Repair-MissingWindowsTaskTarget -TaskData $d } catch { Write-Host "Microsoft task popravka nije uspela: $($_.Exception.Message)" -ForegroundColor Red }
        }
        "ORPHAN_TASK_MS" {
            $d = $Finding.Data
            try {
                $null = Disable-BrokenScheduledTaskWithBackup -TaskData $d -MicrosoftTask
            } catch {
                Write-Host "Popravka Microsoft zakazanog zadatka nije uspela: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "EVENTLOG_EXPORT_CLEAR" {
            $d = $Finding.Data
            try {
                $res = Export-AndClearEventLog -LogName ([string]$d.LogName)
                Save-RepairBackupRecord ([pscustomobject]@{
                    Time = (Get-Date).ToString('o')
                    Type = 'EventLogClear'
                    LogName = $d.LogName
                    BackupPath = $res.BackupPath
                    MainProvider = $d.MainProvider
                    Count = $d.Count
                })
                if ($res.BackupMade) { Write-Host "Backup Event Log-a: $($res.BackupPath)" -ForegroundColor DarkGray }
                if ($res.Cleared) {
                    Write-Host "Event Log '$($d.LogName)' je ociscen. Posle ponovnog skeniranja ostace samo novi/nereseni zapisi." -ForegroundColor Green
                } else {
                    Write-Host "Log je backup-ovan, ali ciscenje nije uspelo." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "Obrada Event Log-a nije uspela: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "EVENTLOG_SECURITY" {
            $d = $Finding.Data
            try {
                Write-Host "Pokusavam laganu popravku Microsoft Security/Defender servisa..." -ForegroundColor Yellow
                Repair-SecurityStackLight
                $res = Export-AndClearEventLog -LogName ([string]$d.LogName)
                Save-RepairBackupRecord ([pscustomobject]@{
                    Time = (Get-Date).ToString('o')
                    Type = 'SecurityEventLogRepair'
                    LogName = $d.LogName
                    BackupPath = $res.BackupPath
                    MainProvider = $d.MainProvider
                    Count = $d.Count
                })
                if ($res.BackupMade) { Write-Host "Backup Event Log-a: $($res.BackupPath)" -ForegroundColor DarkGray }
                if ($res.Cleared) {
                    Write-Host "Microsoft Security/Defender osvezavanje je pokusano, a stari zapisi iz loga su ocisceni." -ForegroundColor Green
                } else {
                    Write-Host "Osvezavanje je pokusano, ali ciscenje loga nije uspelo." -ForegroundColor Yellow
                }
            } catch {
                Write-Host "Security/Event Log popravka nije uspela: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        "SYSTEM_REPAIR" {
            Write-Host "Ova stavka se sada resava kroz PAMETNU Windows popravku." -ForegroundColor Cyan
            Invoke-KiRoQuickWindowsRepair
        }
        default {
            Write-Host "Za ovu stavku nema bezbedne automatske popravke." -ForegroundColor Yellow
            Write-Host "Preporuka: $($Finding.Recommendation)"
        }
    }

    $after = Get-LightSnapshot
    Show-BeforeAfterSimple $before $after "$($Finding.Category) / ID $($Finding.ID)"

    # Ishod za GUI. Ako grana nije postavila svoj, javljamo uspeh.
    if ($null -ne $script:LastFixOutcome) {
        $outcome = $script:LastFixOutcome
        $script:LastFixOutcome = $null
        return $outcome
    }
    return [pscustomobject]@{ Success = $true; Message = 'Izmena je izvrsena.' }
}

function Fix-AllSafe {
    Write-Header
    $safe = @($script:Findings | Where-Object { $_.SafeAutoFix -and $_.FixAction })
    if ($safe.Count -eq 0) {
        Write-Host "Nema stavki koje program moze bezbedno automatski da popravi." -ForegroundColor Green
        Pause-KiRo
        return
    }

    Write-Host "BRZA POPRAVKA ne pokrece spori DISM RestoreHealth ni SFC /scannow." -ForegroundColor Cyan
    Write-Host "Windows provera/popravka je pod opcijom [7] i sada ima QUICK i DUBINSKI rezim." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Sledece bezbedne automatske popravke ce biti pokusane:" -ForegroundColor Yellow
    $safe | Select-Object ID, Category, Problem | Format-Table -Wrap -AutoSize
    Write-Host ""
    $confirm = Read-Host "Upisi DA ako zelis da nastavim"
    if ($confirm.ToUpper() -ne "DA") {
        Write-Host "Nista nije promenjeno."
        Pause-KiRo
        return
    }

    # Globalne akcije se rade samo jednom, ali popravke konkretnih startup/task
    # stavki moraju da se izvrse za SVAKU pronadjenu stavku.
    $doneActions = @{}
    $globalActions = @('TEMP_CLEAN','DEFENDER_UPDATE','DEFENDER_REALTIME','DEFENDER_THREATS','SYSTEM_REPAIR')
    foreach ($f in $safe) {
        $isGlobal = $globalActions -contains [string]$f.FixAction
        if ($isGlobal) {
            if (-not $doneActions.ContainsKey($f.FixAction)) {
                [void](Invoke-FixAction $f)
                $doneActions[$f.FixAction] = $true
            }
        } else {
            [void](Invoke-FixAction $f)
        }
    }

    Write-Host ""
    Write-Host "Bezbedne automatske popravke su zavrsene." -ForegroundColor Green
    Write-Host "Sada automatski radim ponovno FAST skeniranje da ostanu samo nereseni problemi..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    Run-DiagnosticScan
}

function Fix-Selected {
    Write-Header
    if ($script:Findings.Count -eq 0) {
        Write-Host "Nema pronadjenih stavki."
        Pause-KiRo
        return
    }

    $script:Findings | Select-Object ID, Severity, Category, Problem | Format-Table -Wrap -AutoSize
    Write-Host ""
    $raw = Read-Host "Upisi brojeve koje hoces da obradim (npr. 1,3,5)"
    $ids = $raw -split "[,; ]+" | Where-Object { $_ -match "^\d+$" } | ForEach-Object { [int]$_ } | Select-Object -Unique
    if (-not $ids) {
        Write-Host "Nije izabran nijedan ispravan broj." -ForegroundColor Yellow
        Pause-KiRo
        return
    }

    $didRepair = $false
    foreach ($id in $ids) {
        $f = $script:Findings | Where-Object ID -eq $id | Select-Object -First 1
        if (-not $f) {
            Write-Host "ID $id ne postoji." -ForegroundColor Yellow
            continue
        }

        Write-Host ""
        Write-Host "[$id] $($f.Problem)" -ForegroundColor Cyan
        Write-Host "Preporuka: $($f.Recommendation)"
        if ($f.SafeAutoFix -and $f.FixAction) {
            $c = Read-Host "Da li hoces da program sada pokusa popravku? (DA/NE)"
            if ($c.ToUpper() -eq "DA") {
                [void](Invoke-FixAction $f)
                $didRepair = $true
            }
        } else {
            if ($f.FixAction -eq "SYSTEM_REPAIR") {
                Write-Host "Ova Windows popravka je namerno izdvojena jer moze dugo da traje." -ForegroundColor Yellow
                Write-Host "Pokreni je samo preko opcije [7] DUBINSKA Windows popravka." -ForegroundColor Cyan
            } else {
                Write-Host "Ova stavka je samo za pregled; program je nece automatski menjati." -ForegroundColor Yellow
            }
        }
    }

    if ($didRepair) {
        Write-Host ""
        Write-Host "Pokrecem ponovno FAST skeniranje da ostanu samo nereseni problemi..." -ForegroundColor Cyan
        Start-Sleep -Seconds 2
        Run-DiagnosticScan
    } else {
        Pause-KiRo
    }
}



# ===================== KiRo Malware/Trojan Scan (bez Defender-a) =====================
$script:MalwareWhitelistFile = Join-Path $LogRoot 'malware_whitelist.jsonl'
$script:MalwareQuarantineRoot = Join-Path $LogRoot 'Quarantine'
New-Item -ItemType Directory -Force -Path $script:MalwareQuarantineRoot | Out-Null

function Get-KiRoSha256 {
    param([string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        }
    } catch {}
    return ''
}

function Get-KiRoWhitelistHashes {
    $set = @{}
    if (Test-Path -LiteralPath $script:MalwareWhitelistFile) {
        foreach ($line in @(Get-Content -LiteralPath $script:MalwareWhitelistFile -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $o = $line | ConvertFrom-Json -ErrorAction Stop
                if ($o.Hash) { $set[[string]$o.Hash.ToUpperInvariant()] = $true }
            } catch {}
        }
    }
    return $set
}

function Add-KiRoWhitelistItem {
    param([string]$Path)
    $hash = Get-KiRoSha256 $Path
    if (-not $hash) { return $false }
    $rec = [pscustomobject]@{ Time=(Get-Date).ToString('o'); Hash=$hash; Path=$Path }
    $rec | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:MalwareWhitelistFile -Encoding UTF8
    return $true
}

function Get-KiRoSignatureInfo {
    param([string]$Path)
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        return [pscustomobject]@{ Status=[string]$s.Status; Signer=if($s.SignerCertificate){$s.SignerCertificate.Subject}else{''} }
    } catch {
        return [pscustomobject]@{ Status='UnknownError'; Signer='' }
    }
}

function Test-KiRoProtectedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    try { $full=[IO.Path]::GetFullPath($Path) } catch { $full=$Path }
    $roots = @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
    foreach ($r in $roots) {
        try {
            $rr=[IO.Path]::GetFullPath($r).TrimEnd('\')+'\\'
            if ($full.StartsWith($rr,[System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        } catch {}
    }
    return $false
}

function Test-KiRoKnownGood {
    param([string]$Path,[object]$Sig)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $full=[IO.Path]::GetFullPath($Path) } catch { $full=$Path }
    $pl=$full.ToLowerInvariant()
    $name=[IO.Path]::GetFileName($full).ToLowerInvariant()

    # Poznati Windows/Microsoft fajlovi samo kada su na ocekivanoj lokaciji.
    $win=[Environment]::GetFolderPath('Windows').ToLowerInvariant().TrimEnd('\')
    if ($pl.StartsWith($win+'\\system32\\') -and $name -in @(
        'rundll32.exe','svchost.exe','explorer.exe','conhost.exe','dllhost.exe','taskhostw.exe','sihost.exe','ctfmon.exe'
    )) { return $true }

    if ($pl -like '*\microsoft\edgewebview\application\*\msedgewebview2.exe') { return $true }
    if ($pl -like '*\windowsapps\microsoft.widgetsplatformruntime_*\widgetsservice\widgetsservice.exe') { return $true }

    # Realtek audio servis na DriverStore lokaciji.
    if ($pl -like ($win+'\\system32\\driverstore\\filerepository\\realtek*\\rtkauduservice64.exe')) { return $true }

    # Validan Microsoft/Windows/Realtek potpis u Program Files / Windows lokaciji je dovoljan za nizi rizik.
    if ($Sig -and $Sig.Status -eq 'Valid' -and $Sig.Signer) {
        $signer=([string]$Sig.Signer).ToLowerInvariant()
        if ($signer -match 'microsoft|windows|realtek') {
            if ($pl.StartsWith($win+'\\') -or $pl.StartsWith($env:ProgramFiles.ToLowerInvariant()+'\\') -or (${env:ProgramFiles(x86)} -and $pl.StartsWith(${env:ProgramFiles(x86)}.ToLowerInvariant()+'\\'))) {
                return $true
            }
        }
    }
    return $false
}

function Get-KiRoMalwareRisk {
    param([string]$Path,[string]$Source='File',[string]$CommandLine='')
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    try { $f=Get-Item -LiteralPath $Path -Force -ErrorAction Stop } catch { return $null }
    $ext=$f.Extension.ToLowerInvariant()
    if ($ext -notin @('.exe','.dll','.com','.bat','.cmd','.ps1','.vbs','.js','.jse','.wsf','.scr','.hta')) { return $null }

    $reasons = New-Object System.Collections.Generic.List[string]
    $score=0
    $p=$f.FullName
    $pl=$p.ToLowerInvariant()
    $cmd=[string]$CommandLine

    $userWritable = ($pl -like (([Environment]::GetFolderPath('UserProfile')).ToLowerInvariant() + '*'))
    $inTemp = ($pl -like '*\appdata\local\temp\*' -or $pl -like '*\windows\temp\*' -or ($env:TEMP -and $pl -like (($env:TEMP).ToLowerInvariant().TrimEnd('\')+'\\*')))
    $inStartup = ($pl -like '*\microsoft\windows\start menu\programs\startup\*')
    $roamingSvc = ($pl -like '*\appdata\roaming\microsoft\windows\services\*')

    $sig=Get-KiRoSignatureInfo $p
    if (Test-KiRoKnownGood -Path $p -Sig $sig) { return $null }

    # v4.1: u Telegram folderu su normalni SAMO Telegram.exe / Updater.exe /
    # unins000. Sve ostalo sto se moze pokrenuti je jak signal.
    $bn = [IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant()
    if ($pl -like '*\telegram desktop\*') {
        if ($bn -in @('telegram','updater','unins000')) { return $null }
        $score += 4
        $reasons.Add('izvrsni fajl u Telegram folderu koji nije Telegram')
    }

    if ($roamingSvc) { $score += 6; $reasons.Add('veoma neobicna AppData\\Roaming\\Microsoft\\Windows\\Services putanja') }
    if ($inTemp) { $score += 3; $reasons.Add('izvrsni fajl u TEMP folderu') }
    if ($inStartup) { $score += 2; $reasons.Add('direktno u Startup folderu') }
    if ($Source -in @('Startup','Task','Service')) { $score += 2; $reasons.Add("automatsko pokretanje: $Source") }
    elseif ($Source -eq 'Process' -and $userWritable) { $score += 1; $reasons.Add('aktivan proces iz korisnickog foldera') }

    if ($sig.Status -ne 'Valid') {
        if ($userWritable) { $score += 2 } else { $score += 1 }
        $reasons.Add("digitalni potpis: $($sig.Status)")
    } elseif ($sig.Signer) {
        $reasons.Add("potpisan: $($sig.Signer)")
    }

    if (($f.Attributes -band [IO.FileAttributes]::Hidden) -ne 0) { $score += 1; $reasons.Add('skriven fajl') }
    if (($f.Attributes -band [IO.FileAttributes]::System) -ne 0 -and $userWritable) { $score += 1; $reasons.Add('SYSTEM atribut u korisnickom folderu') }

    $base=[IO.Path]::GetFileNameWithoutExtension($f.Name)
    # Nasumicno ime je samo slab signal i racuna se samo u korisnickim/rizicnim lokacijama.
    if ($userWritable -and $base -match '^[a-z0-9]{8,16}$' -and $base -match '\\d') { $score += 1; $reasons.Add('neobicno ime fajla u korisnickom folderu') }
    if ($ext -in @('.scr','.hta','.jse','.wsf')) { $score += 2; $reasons.Add("rizicna ekstenzija $ext") }
    if ($ext -in @('.vbs','.js','.ps1','.bat','.cmd') -and ($inTemp -or $inStartup -or $Source -in @('Startup','Task','Service'))) { $score += 2; $reasons.Add('skripta se automatski pokrece') }

    # Za Task analiziraj i argumente/komandu, ne samo launcher.
    if ($Source -eq 'Task' -and $cmd) {
        $cl=$cmd.ToLowerInvariant()
        if ($cl -match '(?:-enc|-encodedcommand|frombase64string|iex\s*\(|invoke-expression|downloadstring|javascript:|vbscript:)') {
            $score += 4; $reasons.Add('Task koristi sumnjive/skrivene argumente')
        }
        if ($cl -match '\\appdata\\|\\temp\\|\\users\\public\\') {
            $score += 2; $reasons.Add('Task argumenti vode u korisnicku/rizicnu putanju')
        }
    }

    $hash=Get-KiRoSha256 $p
    $level=if($score -ge 7){'VISOK'}elseif($score -ge 5){'SREDNJI'}else{'NIZI'}
    [pscustomobject]@{
        Path=$p; Name=$f.Name; Source=$Source; Score=$score; Level=$level; Reasons=($reasons -join '; ');
        Signature=$sig.Status; Signer=$sig.Signer; Hash=$hash; SizeKB=[math]::Round($f.Length/1KB,1); CommandLine=$cmd
    }
}

function Get-KiRoMalwareCandidates {
    $seen=@{}
    $raw = New-Object System.Collections.ArrayList

    function Add-CandidatePath([string]$Path,[string]$Source,[string]$CommandLine='') {
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try { $full=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path.Trim('"'))) } catch { return }
        $key=($full+'|'+$Source+'|'+$CommandLine).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return }
        $seen[$key]=$true
        $r=Get-KiRoMalwareRisk -Path $full -Source $Source -CommandLine $CommandLine
        if ($r -and $r.Score -ge 3) { [void]$raw.Add($r) }
    }

    # 1) Aktivni procesi.
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
            $ep=[string]$p.ExecutablePath
            if ($ep) { Add-CandidatePath $ep 'Process' ([string]$p.CommandLine) }
        }
    } catch {}

    # 2) Startup unosi.
    try {
        foreach ($s in @(Get-StartupItemsForManagement)) {
            if ($s.Target) { Add-CandidatePath ([string]$s.Target) 'Startup' ([string]$s.Command) }
        }
    } catch {}

    # 3) Scheduled Tasks - prikazi celu komandu i argumente.
    try {
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            foreach ($a in @($t.Actions)) {
                $e=[string]$a.Execute
                $arg=[string]$a.Arguments
                $cmd=($e + $(if($arg){' '+$arg}else{''})).Trim()
                if ($e) {
                    $st=Get-LaunchReferenceStatus $e
                    if ($st -and $st.Target -and $st.Exists) { Add-CandidatePath ([string]$st.Target) 'Task' $cmd }
                }
            }
        }
    } catch {}

    # 4) Servisi.
    try {
        foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
            if (-not $s.PathName) { continue }
            $st=Get-LaunchReferenceStatus ([string]$s.PathName)
            if ($st -and $st.Target -and $st.Exists) { Add-CandidatePath ([string]$st.Target) 'Service' ([string]$s.PathName) }
        }
    } catch {}

    # 5) Ogranicena dubinska pretraga najrizicnijih korisnickih foldera.
    $scanDirs=@(
        (Join-Path $env:APPDATA 'Microsoft\\Windows\\Services'),
        (Join-Path $env:APPDATA 'Microsoft\\Windows\\Start Menu\\Programs\\Startup'),
        (Join-Path $env:APPDATA 'Telegram Desktop'),
        $env:TEMP,
        (Join-Path $env:LOCALAPPDATA 'Temp')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    foreach ($d in $scanDirs) {
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Force -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1200)) {
                Add-CandidatePath $f.FullName 'File' ''
            }
        } catch {}
    }

    # v4.1: fajlovi koji NISU izvrsni, ali su u Telegram folderu sumnjivi
    # (izvestaji o ukradenim nalozima, comboliste, temp dumpovi).
    foreach ($td in @((Join-Path $env:APPDATA 'Telegram Desktop'))) {
        if (-not $td -or -not (Test-Path -LiteralPath $td)) { continue }
        try {
            foreach ($f in @(Get-ChildItem -LiteralPath $td -File -Force -Recurse -ErrorAction SilentlyContinue | Select-Object -First 400)) {
                $fn = $f.Name.ToLowerInvariant()
                if ($fn -in @('telegram.exe','updater.exe','unins000.exe')) { continue }
                $ext = $f.Extension.ToLowerInvariant()
                if ($ext -notin @('.txt','.log','.dat','.csv','.json','.xml','.ini','.sql')) { continue }
                $susp = ($fn -match 'combolist|combo|pass|cred|cookie|token|account|dump|stealer|log|temp|@|ipvanish|ulp')
                $hid  = ((($f.Attributes -band [IO.FileAttributes]::Hidden) -ne 0) -or (($f.Attributes -band [IO.FileAttributes]::System) -ne 0))
                if (-not ($susp -or $hid)) { continue }
                $key2 = ('data|' + $f.FullName).ToLowerInvariant()
                if ($seen.ContainsKey($key2)) { continue }
                $seen[$key2] = $true
                [void]$raw.Add([pscustomobject]@{
                    Path=$f.FullName; Name=$f.Name; Source='TelegramData'; Score=6; Level='SREDNJI';
                    Reasons='fajl u Telegram folderu koji ne pripada Telegramu - lici na izvestaj ukradenih podataka';
                    Signature='Nije izvrsni fajl'; Signer=''; Hash=(Get-KiRoSha256 $f.FullName);
                    SizeKB=[math]::Round($f.Length/1KB,1); CommandLine=''
                })
            }
        } catch {}
    }

    $wl=Get-KiRoWhitelistHashes
    @($raw | Where-Object { -not $_.Hash -or -not $wl.ContainsKey($_.Hash) } | Sort-Object @{Expression='Score';Descending=$true}, @{Expression='Path';Descending=$false})
}

function Remove-KiRoSelectedFile {
    param([object]$Item,[switch]$Quarantine)
    $path=[string]$Item.Path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]@{Ok=$true;Message='Fajl vise ne postoji.'} }
    if (Test-KiRoProtectedPath $path) { return [pscustomobject]@{Ok=$false;Message='Zasticena Windows/Program Files lokacija - KiRo ne brise automatski.'} }

    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "ExecutablePath IS NOT NULL" -ErrorAction SilentlyContinue)) {
            if ($p.ExecutablePath -and $p.ExecutablePath.Equals($path,[System.StringComparison]::OrdinalIgnoreCase)) {
                try { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
    } catch {}
    try { [void](Disable-MatchingStartupReferences -ExecutablePath $path) } catch {}

    try {
        if ($Quarantine) {
            $qdir=Join-Path $script:MalwareQuarantineRoot (Get-Date -Format 'yyyyMMdd_HHmmss')
            New-Item -ItemType Directory -Force -Path $qdir | Out-Null
            $dest=Join-Path $qdir ([IO.Path]::GetFileName($path))
            Move-Item -LiteralPath $path -Destination $dest -Force -ErrorAction Stop
            $meta=[pscustomobject]@{Time=(Get-Date).ToString('o');Original=$path;Quarantine=$dest;Hash=$Item.Hash;Reasons=$Item.Reasons}
            $meta | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $qdir 'quarantine.jsonl') -Encoding UTF8
            Save-RepairBackupRecord ([pscustomobject]@{
                Time=(Get-Date).ToString('o'); Type='MalwareQuarantine';
                OriginalPath=$path; QuarantinePath=$dest; Hash=$Item.Hash
            })
            return [pscustomobject]@{Ok=$true;Message="Premesteno u karantin: $dest"}
        } else {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            return [pscustomobject]@{Ok=$true;Message='Obrisano.'}
        }
    } catch {
        return [pscustomobject]@{Ok=$false;Message=$_.Exception.Message}
    }
}

function Malware-TrojanScanMenu {
    while ($true) {
        Write-Header
        Write-Host 'MALWARE / TROJAN SKEN - JEDNOSTAVNI PRIKAZ' -ForegroundColor Cyan
        Write-Host 'KiRo NE brise nista sam. Ti biras sta ces da karantinises ili obrises.' -ForegroundColor Green
        Write-Host 'Poznate Windows/Microsoft/Realtek stavke se automatski skrivaju iz rezultata.' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host 'Skeniram...' -ForegroundColor DarkCyan
        $allItems=@(Get-KiRoMalwareCandidates)
        if ($allItems.Count -eq 0) {
            Write-Host ''
            Write-Host 'Nema kandidata koji su presli KiRo prag sumnjivosti.' -ForegroundColor Green
            Pause-KiRo
            return
        }

        $showRecommended=$true
        $selected=@{}
        while ($true) {
            $items=if($showRecommended){ @($allItems | Where-Object { $_.Score -ge 5 }) } else { @($allItems) }
            if ($showRecommended -and $items.Count -eq 0) { $showRecommended=$false; $items=@($allItems) }

            Write-Header
            Write-Host 'MALWARE / TROJAN SKEN' -ForegroundColor Cyan
            Write-Host $(if($showRecommended){'Prikaz: samo PREPORUCENE ZA PROVERU (SREDNJI/VISOK rizik)'}else{'Prikaz: SVE pronadjene stavke'}) -ForegroundColor Yellow
            Write-Host 'Unesi broj (npr. 1 ili 1,3,5) da oznacis/ponistis stavku.' -ForegroundColor White
            Write-Host ''

            $i=1
            foreach ($it in $items) {
                $identity=[string]$it.Path+'|'+[string]$it.CommandLine
                $mark=if($selected.ContainsKey($identity)){'X'}else{' '}
                $level=if($it.Score -ge 7){'VISOK RIZIK'}elseif($it.Score -ge 5){'PROVERI'}else{'NIZAK RIZIK'}
                $color=if($it.Score -ge 7){'Red'}elseif($it.Score -ge 5){'Yellow'}else{'DarkGray'}
                Write-Host ("[{0}] {1,2}. {2} - {3}" -f $mark,$i,$level,$it.Name) -ForegroundColor $color
                Write-Host ("     Lokacija: {0}" -f $it.Path) -ForegroundColor Gray
                Write-Host ("     Izvor: {0}   Potpis: {1}" -f $it.Source,$it.Signature) -ForegroundColor DarkGray
                if ($it.CommandLine -and $it.CommandLine -ne $it.Path) {
                    Write-Host ("     Pokrece: {0}" -f $it.CommandLine) -ForegroundColor DarkGray
                }
                Write-Host ("     Zasto: {0}" -f $it.Reasons) -ForegroundColor DarkGray
                Write-Host ''
                $i++
            }

            Write-Host '[P] Prikazi samo preporucene / sve' -ForegroundColor Cyan
            Write-Host '[K] Karantin oznacenih   [D] Obrisi oznacene   [W] Dozvoli (whitelist)' -ForegroundColor Cyan
            Write-Host '[N] Ponisti oznake       [R] Novi sken         [0] Nazad' -ForegroundColor Cyan
            $raw=(Read-Host 'Izbor').Trim()
            if ($raw -eq '0') { return }

            switch ($raw.ToUpperInvariant()) {
                'P' { $showRecommended=-not $showRecommended; continue }
                'N' { $selected=@{}; continue }
                'R' { break }
                'W' {
                    if ($selected.Count -eq 0) { Write-Host 'Nista nije oznaceno.' -ForegroundColor Yellow; Pause-KiRo; continue }
                    foreach($it in $allItems) {
                        $identity=[string]$it.Path+'|'+[string]$it.CommandLine
                        if ($selected.ContainsKey($identity) -and (Add-KiRoWhitelistItem $it.Path)) { Write-Host "Dozvoljeno: $($it.Name)" -ForegroundColor Green }
                    }
                    Start-Sleep -Seconds 1
                    break
                }
                'K' {
                    if ($selected.Count -eq 0) { Write-Host 'Nista nije oznaceno.' -ForegroundColor Yellow; Pause-KiRo; continue }
                    $yes=Read-Host 'Upisi DA za KARANTIN samo oznacenih stavki'
                    if ($yes.ToUpperInvariant() -ne 'DA') { continue }
                    foreach($it in $allItems) {
                        $identity=[string]$it.Path+'|'+[string]$it.CommandLine
                        if (-not $selected.ContainsKey($identity)) { continue }
                        $res=Remove-KiRoSelectedFile -Item $it -Quarantine
                        Write-Host "$($it.Name): $($res.Message)" -ForegroundColor $(if($res.Ok){'Green'}else{'Red'})
                    }
                    Pause-KiRo
                    break
                }
                'D' {
                    if ($selected.Count -eq 0) { Write-Host 'Nista nije oznaceno.' -ForegroundColor Yellow; Pause-KiRo; continue }
                    Write-Host 'PAZNJA: Brisanje je trajno. Ako nisi siguran, koristi K = Karantin.' -ForegroundColor Red
                    $yes=Read-Host 'Upisi OBRISI za trajno brisanje SAMO oznacenih stavki'
                    if ($yes.ToUpperInvariant() -ne 'OBRISI') { continue }
                    foreach($it in $allItems) {
                        $identity=[string]$it.Path+'|'+[string]$it.CommandLine
                        if (-not $selected.ContainsKey($identity)) { continue }
                        $res=Remove-KiRoSelectedFile -Item $it
                        Write-Host "$($it.Name): $($res.Message)" -ForegroundColor $(if($res.Ok){'Green'}else{'Red'})
                    }
                    Pause-KiRo
                    break
                }
                default {
                    $ids=$raw -split '[,; ]+' | Where-Object { $_ -match '^\\d+$' } | ForEach-Object { [int]$_ } | Select-Object -Unique
                    foreach($id in $ids) {
                        if ($id -lt 1 -or $id -gt $items.Count) { continue }
                        $it=$items[$id-1]
                        $identity=[string]$it.Path+'|'+[string]$it.CommandLine
                        if ($selected.ContainsKey($identity)) { $selected.Remove($identity) } else { $selected[$identity]=$true }
                    }
                    continue
                }
            }
            break
        }
    }
}
# ================================================================================

function Show-TechnicalDetails {
    Write-Header
    Write-Host "TEHNICKI PODACI SKENIRANJA" -ForegroundColor Cyan
    Write-Host ""
    foreach ($k in $script:ScanDetails.Keys) {
        Write-Host ("{0,-28}: {1}" -f $k, $script:ScanDetails[$k])
    }
    Write-Host ""
    Write-Host "Log: $LogFile"
    Pause-KiRo
}

function Repair-DecisionMenu {
    while ($true) {
        # Uvek ponovo prikazi aktuelnu listu. Posle ENTER-a korisnik se vraca ovde,
        # a program vise ne pada nazad u PowerShell prompt.
        Show-DiagnosticSummary

        Write-Host 'STA ZELIS DALJE?' -ForegroundColor Cyan
        Write-Host '[1] BRZA POPRAVKA - bez dubinskog DISM/SFC' -ForegroundColor Green
        Write-Host '[2] Izaberi pojedinacne probleme koje hoces da popravljas' -ForegroundColor White
        Write-Host '[3] Prikazi detaljno svaki pronadjeni problem' -ForegroundColor White
        Write-Host '[4] Prikazi tehnicke podatke skeniranja' -ForegroundColor White
        Write-Host '[5] Ponovo FAST skeniraj racunar (provera POSLE popravke)' -ForegroundColor White
        Write-Host '[6] Otvori folder sa logovima' -ForegroundColor White
        Write-Host '[7] WINDOWS POPRAVKA - QUICK ili DUBINSKA (pametno pokretanje DISM/SFC)' -ForegroundColor Yellow
        Write-Host '[8] STARTUP + POZADINSKI PROCESI + RAM optimizacija' -ForegroundColor Cyan
        Write-Host '[9] EKRAN - najveci Hz/FPS za trenutnu rezoluciju' -ForegroundColor Cyan
        Write-Host '[10] MALWARE / TROJAN SKEN - bez Defender-a, ti oznacavas sta se uklanja' -ForegroundColor Magenta
        $defState = if ([bool]$script:Settings.DefenderChecksEnabled) { 'UKLJUCENE' } else { 'ISKLJUCENE' }
        Write-Host "[11] Defender provere: $defState  (promeni)" -ForegroundColor DarkYellow
        Write-Host '[12] MALWARE / TELEGRAM DUBINSKA PROVERA - indikatori bez brisanja' -ForegroundColor Magenta
        Write-Host '[0] Izlaz' -ForegroundColor DarkGray
        Write-Host ''

        $c = Read-Host 'Izaberi opciju'
        switch ($c) {
            '1' {
                Fix-AllSafe
                # Fix-AllSafe vec radi novi FAST scan kada je bilo popravki.
            }
            '2' {
                Fix-Selected
                # Ako je stavka samo za pregled, ENTER sada vraca ovde u meni.
            }
            '3' {
                Show-FindingDetails
            }
            '4' {
                Show-TechnicalDetails
            }
            '5' {
                Run-DiagnosticScan
            }
            '6' {
                try { Start-Process explorer.exe $LogRoot } catch {}
            }
            '7' {
                Windows-RepairMenu
            }
            '8' {
                Performance-OptimizationMenu
            }
            '9' {
                Display-OptimizationMenu
                # Posle promene Hz osvezi dijagnostiku da se skinu resene INFO stavke.
                Run-DiagnosticScan
            }
            '10' {
                Malware-TrojanScanMenu
            }
            '11' {
                Toggle-DefenderChecks
                Run-DiagnosticScan
            }
            '12' {
                Run-MalwareIndicatorScan
                Show-DiagnosticSummary
                Pause-KiRo
            }
            '0' { return }
            default {
                Write-Host 'Nepoznata opcija.' -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ============================================================================
#  v4.1 - AKCIJE ZA GUI (bez crne konzole)
#  Ovo je most izmedju GUI-ja i "tezih" popravki. Sve se pokrece iz
#  pozadinske niti GUI-ja, javlja napredak preko >>> markera i vraca
#  uredan izvestaj (isti oblik kao Repair-KiRoSelectedFindings).
# ============================================================================

function Invoke-KiRoMalwareActions {
    param(
        [ValidateSet('List','Quarantine','Delete','Whitelist')][string]$Mode = 'List',
        [object[]]$Items = @()
    )

    if ($Mode -eq 'List') {
        Write-Host '>>>  Trazim sumnjive fajlove i procese' -ForegroundColor Cyan
        $c = @(Get-KiRoMalwareCandidates)
        Write-Host (">>>  Gotovo: {0} kandidata" -f $c.Count) -ForegroundColor Cyan
        return $c
    }

    $all = @($Items)
    if ($all.Count -eq 0) {
        return [pscustomobject]@{ Mode=$Mode; Count=0; Ok=0; Bad=0; Results=@() }
    }

    $i = 0
    $ok = 0
    $bad = 0
    $results = New-Object System.Collections.ArrayList
    foreach ($it in $all) {
        $i++
        $name = [string]$it.Name
        if (-not $name) { $name = Split-Path -Leaf ([string]$it.Path) }
        Write-Host (" >>> {0}/{1}  {2}" -f $i, $all.Count, $name) -ForegroundColor Yellow
        $good = $false
        $msg  = ''
        try {
            switch ($Mode) {
                'Quarantine' {
                    $r = Remove-KiRoSelectedFile -Item $it -Quarantine
                    $good = [bool]$r.Ok
                    $msg  = [string]$r.Message
                }
                'Delete' {
                    $r = Remove-KiRoSelectedFile -Item $it
                    $good = [bool]$r.Ok
                    $msg  = [string]$r.Message
                }
                'Whitelist' {
                    $good = [bool](Add-KiRoWhitelistItem ([string]$it.Path))
                    $msg  = if ($good) { 'Dodato na listu dozvoljenih.' } else { 'Ne mogu da izracunam hash fajla.' }
                }
            }
        } catch {
            $good = $false
            $msg  = $_.Exception.Message
        }
        if ($good) { $ok++ } else { $bad++ }
        Write-Host ("      -> " + $(if ($good) { 'OK: ' } else { 'GRESKA: ' }) + $msg) -ForegroundColor $(if ($good) { 'Green' } else { 'Red' })
        [void]$results.Add([pscustomobject]@{
            Label   = $name
            Path    = [string]$it.Path
            Success = $good
            Message = $msg
        })
    }
    Write-Host (" >>>  Gotovo: uspesno {0}, neuspesno {1}" -f $ok, $bad) -ForegroundColor Cyan
    return [pscustomobject]@{ Mode=$Mode; Count=$all.Count; Ok=$ok; Bad=$bad; Results=@($results) }
}

function Invoke-KiRoToolFix {
    param(
        [ValidateSet('WindowsRepair','DefenderFix','DefenderRealtime','EventLogSecurity')][string]$Action = 'WindowsRepair'
    )

    $lines = New-Object System.Collections.ArrayList
    $ok    = $true

    switch ($Action) {
        'WindowsRepair' {
            Write-Host '>>>  DISM CheckHealth' -ForegroundColor Cyan
            $h = Get-KiRoDismHealthState
            [void]$lines.Add('DISM CheckHealth: ' + [string]$h.State)
            if ([string]$h.State -eq 'Healthy') {
                [void]$lines.Add('Component store je ispravan - dubinska popravka nije potrebna.')
            } elseif ([string]$h.State -eq 'Repairable') {
                Write-Host '>>>  SFC /scannow (moze da potraje nekoliko minuta)' -ForegroundColor Yellow
                $r = Invoke-KiRoTimedProcess -FilePath 'sfc.exe' -Arguments @('/scannow') -Label 'SFC'
                [void]$lines.Add('SFC je zavrsio (izlazni kod ' + [string]$r.ExitCode + ').')
                if ([int]$r.ExitCode -ne 0) { $ok = $false }
            } else {
                [void]$lines.Add('DISM prijavljuje ozbiljniji problem. Za dubinsku popravku koristi PUN KONZOLNI MENI.')
                $ok = $false
            }
        }
        'DefenderFix' {
            Write-Host '>>>  Azuriram Defender definicije' -ForegroundColor Cyan
            try { Update-MpSignature -ErrorAction Stop; [void]$lines.Add('Defender definicije su azurirane.') }
            catch { [void]$lines.Add('Definicije nisu azurirane: ' + $_.Exception.Message); $ok = $false }
            Write-Host '>>>  Uklanjam aktivne pretnje' -ForegroundColor Cyan
            try { Remove-MpThreat -ErrorAction Stop; [void]$lines.Add('Defender je primenio akcije nad pretnjama.') }
            catch { [void]$lines.Add('Uklanjanje pretnji nije uspelo: ' + $_.Exception.Message) }
            Write-Host '>>>  Ukljucujem real-time zastitu' -ForegroundColor Cyan
            try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop; [void]$lines.Add('Real-time zastita je ukljucena.') }
            catch { [void]$lines.Add('Real-time zastita nije promenjena: ' + $_.Exception.Message) }
        }
        'DefenderRealtime' {
            Write-Host '>>>  Ukljucujem real-time zastitu' -ForegroundColor Cyan
            try { Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop; [void]$lines.Add('Real-time zastita je ukljucena.') }
            catch { [void]$lines.Add('Real-time zastita nije promenjena: ' + $_.Exception.Message); $ok = $false }
        }
        'EventLogSecurity' {
            Write-Host '>>>  Lagan osvezi security steka' -ForegroundColor Cyan
            try { Repair-SecurityStackLight; [void]$lines.Add('Osvezavanje security steka je pokusano.') }
            catch { [void]$lines.Add('Osvezavanje nije uspelo: ' + $_.Exception.Message) }
            Write-Host '>>>  Export i ciscenje Security loga' -ForegroundColor Cyan
            try {
                $res = Export-AndClearEventLog -LogName 'Security'
                if ($res.BackupMade) { [void]$lines.Add('Backup loga: ' + [string]$res.BackupPath) }
                if ($res.Cleared) { [void]$lines.Add('Security log je ociscen.') }
                else { [void]$lines.Add('Log je backup-ovan, ciscenje nije uspelo.'); $ok = $false }
            } catch {
                [void]$lines.Add('Ciscenje loga nije uspelo: ' + $_.Exception.Message)
                $ok = $false
            }
        }
    }

    Write-Host ('>>>  Gotovo: alat ' + [string]$Action) -ForegroundColor Cyan
    return [pscustomobject]@{ Action=$Action; Success=$ok; Message=($lines -join '  |  ') }
}

if (-not $script:KiRoLibraryMode) {
    try {
        switch ($Action) {
            'Scan' {
                Run-DiagnosticScan
                Show-DiagnosticSummary
                Pause-KiRo
            }
            'WindowsRepair' { Windows-RepairMenu }
            'Performance' { Performance-OptimizationMenu }
            'Display' { Display-OptimizationMenu }
            'Malware' { Malware-TrojanScanMenu }
            'Indicators' {
                Run-MalwareIndicatorScan
                Show-DiagnosticSummary
                Pause-KiRo
            }
            'ToggleDefender' {
                Toggle-DefenderChecks
                Run-DiagnosticScan
                Show-DiagnosticSummary
                Pause-KiRo
            }
            'Menu' {
                Run-DiagnosticScan
                Repair-DecisionMenu
            }
            default {
                Run-DiagnosticScan
                Repair-DecisionMenu
            }
        }
    } catch {
        Write-Host ""
        Write-Host "DOGODILA SE GRESKA:" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Log: $LogFile"
        Read-Host "Pritisni ENTER za izlaz"
    } finally {
        try { Stop-Transcript | Out-Null } catch {}
    }
}
