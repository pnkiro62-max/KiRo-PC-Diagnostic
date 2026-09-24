#requires -version 5.1
param([switch]$TestMode,[switch]$NoElevate)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------------------------------------------------------------- sigurnosna mreza
trap {
    $m = $_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine + $_.ScriptStackTrace
    try {
        $lg = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'KiRo_PC_Diagnostic_Logs'
        New-Item -ItemType Directory -Force -Path $lg | Out-Null
        Add-Content -LiteralPath (Join-Path $lg 'KiRo_GUI_error.log') -Value ((Get-Date).ToString('s') + '  ' + $m) -Encoding UTF8
    } catch {}
    [System.Windows.Forms.MessageBox]::Show("KiRo GUI greska:" + [Environment]::NewLine + [Environment]::NewLine + $m, 'KiRo v4.0', 'OK', 'Error') | Out-Null
    exit 1
}

function Ensure-GuiAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @(
            '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden',
            '-File',('"' + $PSCommandPath + '"')
        )
        exit
    }
}
if (-not $TestMode -and -not $NoElevate) { Ensure-GuiAdmin }

# ---------------------------------------------------------------- engine
$script:KiRoLibraryMode = $true
$EnginePath = Join-Path $PSScriptRoot 'KiRo_PC_Diagnostic_Repair_v4_0_ENGINE.ps1'
if (-not (Test-Path -LiteralPath $EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show("Nedostaje ENGINE fajl:" + [Environment]::NewLine + $EnginePath,'KiRo v4.0') | Out-Null
    exit
}
. $EnginePath
function Pause-KiRo { }

function Show-KiRoMessage {
    param([string]$Text,[string]$Title='KiRo v4.0',[string]$Kind='Info')
    $icon = switch ($Kind) {
        'Error' { [System.Windows.Forms.MessageBoxIcon]::Error }
        'Warning' { [System.Windows.Forms.MessageBoxIcon]::Warning }
        default { [System.Windows.Forms.MessageBoxIcon]::Information }
    }
    [System.Windows.Forms.MessageBox]::Show(
        $Text,$Title,[System.Windows.Forms.MessageBoxButtons]::OK,$icon
    ) | Out-Null
}

function Test-KiRoIsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Start-KiRoConsoleModule {
    param([Parameter(Mandatory=$true)][string]$Action,[string]$Title='')
    $a = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass',
        '-File',('"' + $EnginePath + '"'),'-Action',$Action
    )
    $nm = if ($Title) { $Title } else { $Action }
    try {
        # Ako smo vec admin, NE trazimo ponovo UAC - samo otvorimo modul.
        if (Test-KiRoIsAdmin) {
            Start-Process powershell.exe -ArgumentList $a -WorkingDirectory $PSScriptRoot
        } else {
            Start-Process powershell.exe -Verb RunAs -ArgumentList $a -WorkingDirectory $PSScriptRoot
        }
        Set-KiRoResult ("Otvoren modul: " + $nm + ".  Radi u zasebnom prozoru (naslov: KiRo v4.0 - ALATI: " + $Action + "). Ovaj prozor ostaje slobodan.") 'Info'
    } catch {
        Set-KiRoResult ('Ne mogu da pokrenem modul: ' + $_.Exception.Message) 'Error'
    }
}

# ================================================================ PALETA
$C = @{
    Bg        = '#F3F6FB'
    Card      = '#FFFFFF'
    Border    = '#D9E2EF'
    Head      = '#14304C'
    HeadText  = '#FFFFFF'
    HeadMuted = '#A8C0D8'
    Accent    = '#2D7FF9'
    AccentDk  = '#1B63CE'
    AccentLt  = '#8CBCFF'
    Text      = '#16202B'
    Muted     = '#5D6E80'
    Danger    = '#D6453B'
    Warn      = '#C87A0A'
    Info      = '#2E7DD1'
    Ok        = '#2E9E68'
    GridHead  = '#E7EEF9'
    RowAlt    = '#F7FAFE'
    Sel       = '#D3E5FF'
    BtnLight  = '#FFFFFF'
    BtnLightH = '#EAF2FE'
    Track     = '#DCE6F2'
    Band      = '#EEF4FD'
}
function Col { param([string]$hex) [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Fo  { param([string]$fam,[single]$size,[string]$style='Regular')
    $s = [System.Drawing.FontStyle]::$style
    return (New-Object System.Drawing.Font($fam,$size,$s))
}
function Set-FlatButton {
    param($b,[string]$Back,[string]$Fore,[string]$Hover,[string]$Down,[string]$Border='')
    $b.FlatStyle = 'Flat'
    $b.UseVisualStyleBackColor = $false
    $b.BackColor = Col $Back
    $b.ForeColor = Col $Fore
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Border) {
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = Col $Border
    } else {
        $b.FlatAppearance.BorderSize = 0
    }
    $b.FlatAppearance.MouseOverBackColor = Col $Hover
    $b.FlatAppearance.MouseDownBackColor = Col $Down
}

# ================================================================ FORMA
$form = New-Object System.Windows.Forms.Form
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Text = 'KiRo PC Diagnostic & Repair v4.0'
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI',10)
$form.BackColor = Col $C.Bg
$form.ForeColor = Col $C.Text
$form.MinimumSize = New-Object System.Drawing.Size(820,520)

# Sirina se namerno ogranicava (MAX_DIP) da prozor ne bude razvucen preko celog ekrana.
# Visina se racuna iz radne povrsine, pa se deli sa DPI skalom.
$MAX_DIP = 1000
$gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$dpiScale = $gfx.DpiX / 96.0
$gfx.Dispose()
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$wantW = [int](($wa.Width  / $dpiScale) * 0.95)
if ($wantW -gt $MAX_DIP) { $wantW = $MAX_DIP }
if ($wantW -lt 820) { $wantW = 820 }
$wantH = [int](($wa.Height / $dpiScale) * 0.95)
if ($wantH -lt 520) { $wantH = 520 }
$form.Size = New-Object System.Drawing.Size($wantW,$wantH)

# ---------------------------------------------------------------- zaglavlje
$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 58
$header.BackColor = Col $C.Head

$title = New-Object System.Windows.Forms.Label
$title.Text = 'KiRo PC DIAGNOSTIC && REPAIR'
$title.ForeColor = Col $C.HeadText
$title.Font = Fo 'Segoe UI Semibold' 14
$title.AutoSize = $true
$title.BackColor = [System.Drawing.Color]::Transparent
$title.Location = New-Object System.Drawing.Point(20,8)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'v4.0   |   Skeniraj  ->  Oznaci  ->  Popravi'
$subtitle.ForeColor = Col $C.HeadMuted
$subtitle.Font = Fo 'Segoe UI' 9
$subtitle.AutoSize = $true
$subtitle.BackColor = [System.Drawing.Color]::Transparent
$subtitle.Location = New-Object System.Drawing.Point(22,35)
$header.Controls.Add($subtitle)

$headStripe = New-Object System.Windows.Forms.Panel
$headStripe.Dock = 'Bottom'
$headStripe.Height = 3
$headStripe.BackColor = Col $C.Accent
$header.Controls.Add($headStripe)

$headHint = New-Object System.Windows.Forms.Label
$headHint.Text = 'ADMIN REZIM'
$headHint.ForeColor = Col $C.Accent
$headHint.Font = Fo 'Segoe UI Semibold' 9
$headHint.AutoSize = $true
$headHint.Dock = 'Right'
$headHint.TextAlign = 'MiddleCenter'
$headHint.Padding = New-Object System.Windows.Forms.Padding(0,0,20,0)
$headHint.BackColor = [System.Drawing.Color]::Transparent
$header.Controls.Add($headHint)

# ---------------------------------------------------------------- glavni raspored
$main = New-Object System.Windows.Forms.TableLayoutPanel
$main.Dock = 'Fill'
$main.ColumnCount = 1
$main.RowCount = 3
$main.BackColor = Col $C.Bg
[void]$main.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',58)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute',46)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100)))

# --- red 1: 3 dugmeta (SKENIRAJ / POPRAVI OZNACENO / ALATI)
$toolbar = New-Object System.Windows.Forms.FlowLayoutPanel
$toolbar.Dock = 'Fill'
$toolbar.FlowDirection = 'LeftToRight'
$toolbar.WrapContents = $false
$toolbar.BackColor = Col $C.Bg
$toolbar.Padding = New-Object System.Windows.Forms.Padding(16,11,16,0)
$main.Controls.Add($toolbar,0,0)

function New-TopButton {
    param([string]$Text,[int]$Width=130,[string]$Back=$C.BtnLight,[string]$Fore=$C.Head,
          [string]$Hover=$C.BtnLightH,[string]$Down='#DCE8F8',[string]$Border=$C.Border)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Size = New-Object System.Drawing.Size($Width,36)
    $b.Margin = New-Object System.Windows.Forms.Padding(0,0,10,0)
    $b.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $b $Back $Fore $Hover $Down $Border
    return $b
}

$btnScan     = New-TopButton 'SKENIRAJ' 130 $C.Accent $C.HeadText $C.AccentDk $C.AccentDk ''
$btnRepair   = New-TopButton 'POPRAVI OZNACENO' 176 $C.Ok $C.HeadText '#27875A' '#1F6E49' ''
$btnTools    = New-TopButton 'ALATI' 130
$toolbar.Controls.AddRange(@($btnScan,$btnRepair,$btnTools))

# --- red 2: traka sa statusom / animacijom
$animOuter = New-Object System.Windows.Forms.Panel
$animOuter.Dock = 'Fill'
$animOuter.BackColor = Col $C.Border
$animOuter.Padding = New-Object System.Windows.Forms.Padding(1)
$animOuter.Margin = New-Object System.Windows.Forms.Padding(16,0,16,10)
$main.Controls.Add($animOuter,0,1)

$animInner = New-Object System.Windows.Forms.Panel
$animInner.Dock = 'Fill'
$animInner.BackColor = Col $C.Band
$animInner.Padding = New-Object System.Windows.Forms.Padding(12,0,12,0)
$animOuter.Controls.Add($animInner)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Dock = 'Fill'
$summaryLabel.Text = 'Spreman. Klikni SKENIRAJ. Dvoklik na red u tabeli daje detalje i preporuku.'
$summaryLabel.TextAlign = 'MiddleLeft'
$summaryLabel.AutoEllipsis = $true
$summaryLabel.ForeColor = Col $C.Muted
$summaryLabel.BackColor = [System.Drawing.Color]::Transparent
$summaryLabel.Font = Fo 'Segoe UI Semibold' 9.5
$animInner.Controls.Add($summaryLabel)

$animLabel = New-Object System.Windows.Forms.Label
$animLabel.Dock = 'Left'
$animLabel.Width = 350
$animLabel.Text = 'Skeniram...'
$animLabel.TextAlign = 'MiddleLeft'
$animLabel.AutoEllipsis = $true
$animLabel.Visible = $false
$animLabel.ForeColor = Col $C.Head
$animLabel.BackColor = [System.Drawing.Color]::Transparent
$animLabel.Font = Fo 'Segoe UI Semibold' 9.5
$animInner.Controls.Add($animLabel)

$elapsedLabel = New-Object System.Windows.Forms.Label
$elapsedLabel.Dock = 'Right'
$elapsedLabel.Width = 118
$elapsedLabel.Text = ''
$elapsedLabel.TextAlign = 'MiddleRight'
$elapsedLabel.Visible = $false
$elapsedLabel.ForeColor = Col $C.Muted
$elapsedLabel.BackColor = [System.Drawing.Color]::Transparent
$elapsedLabel.Font = Fo 'Consolas' 9.5
$animInner.Controls.Add($elapsedLabel)

$animTrackWrap = New-Object System.Windows.Forms.Panel
$animTrackWrap.Dock = 'Fill'
$animTrackWrap.Visible = $false
$animTrackWrap.BackColor = [System.Drawing.Color]::Transparent
$animInner.Controls.Add($animTrackWrap)

$animTrack = New-Object System.Windows.Forms.Panel
$animTrack.BackColor = Col $C.Track
$animTrack.Size = New-Object System.Drawing.Size(200,6)
$animTrack.Location = New-Object System.Drawing.Point(18,20)
$animTrackWrap.Controls.Add($animTrack)

$animKnob = New-Object System.Windows.Forms.Panel
$animKnob.BackColor = Col $C.Accent
$animKnob.Size = New-Object System.Drawing.Size(80,6)
$animKnob.Location = New-Object System.Drawing.Point(0,0)
$animTrack.Controls.Add($animKnob)

# --- potvrda popravke: poruka + PRAVA dugmad DA/NE u istoj traci (bez modala)
$confirmWrap = New-Object System.Windows.Forms.Panel
$confirmWrap.Dock = 'Fill'
$confirmWrap.Visible = $false
$confirmWrap.Padding = New-Object System.Windows.Forms.Padding(0,7,0,7)
$confirmWrap.BackColor = [System.Drawing.Color]::Transparent
$animInner.Controls.Add($confirmWrap)

$confirmLabel = New-Object System.Windows.Forms.Label
$confirmLabel.Dock = 'Fill'
$confirmLabel.TextAlign = 'MiddleLeft'
$confirmLabel.AutoEllipsis = $true
$confirmLabel.Text = ''
$confirmLabel.ForeColor = Col $C.Warn
$confirmLabel.BackColor = [System.Drawing.Color]::Transparent
$confirmLabel.Font = Fo 'Segoe UI Semibold' 9.5
$confirmWrap.Controls.Add($confirmLabel)

$btnConfirmNo = New-Object System.Windows.Forms.Button
$btnConfirmNo.Text = 'NE'
$btnConfirmNo.Dock = 'Right'
$btnConfirmNo.Width = 78
$btnConfirmNo.Font = Fo 'Segoe UI Semibold' 9.5
Set-FlatButton $btnConfirmNo $C.BtnLight $C.Head $C.BtnLightH '#DCE8F8' $C.Border
$confirmWrap.Controls.Add($btnConfirmNo)

$btnConfirmYes = New-Object System.Windows.Forms.Button
$btnConfirmYes.Text = 'DA, POPRAVI'
$btnConfirmYes.Dock = 'Right'
$btnConfirmYes.Width = 168
$btnConfirmYes.Font = Fo 'Segoe UI Semibold' 9.5
Set-FlatButton $btnConfirmYes $C.Ok $C.HeadText '#27875A' '#1F6E49' ''
$confirmWrap.Controls.Add($btnConfirmYes)

# --- red 3: tabela
$card = New-Object System.Windows.Forms.Panel
$card.Dock = 'Fill'
$card.BackColor = Col $C.Border
$card.Padding = New-Object System.Windows.Forms.Padding(1)
$card.Margin = New-Object System.Windows.Forms.Padding(16,0,16,14)
$main.Controls.Add($card,0,2)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.ReadOnly = $false
$grid.MultiSelect = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeRowsMode = 'AllCells'
$grid.RowHeadersVisible = $false
$grid.BorderStyle = 'None'
$grid.BackgroundColor = Col $C.Card
$grid.GridColor = Col $C.Border
$grid.CellBorderStyle = 'SingleHorizontal'
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersBorderStyle = 'Single'
$grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$grid.ColumnHeadersHeight = 32
$grid.ColumnHeadersDefaultCellStyle.BackColor = Col $C.GridHead
$grid.ColumnHeadersDefaultCellStyle.ForeColor = Col $C.Head
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = Col $C.GridHead
$grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = Col $C.Head
$grid.ColumnHeadersDefaultCellStyle.Font = Fo 'Segoe UI Semibold' 9.5
$grid.DefaultCellStyle.BackColor = Col $C.Card
$grid.DefaultCellStyle.ForeColor = Col $C.Text
$grid.DefaultCellStyle.SelectionBackColor = Col $C.Sel
$grid.DefaultCellStyle.SelectionForeColor = Col $C.Text
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4,2,4,2)
$grid.AlternatingRowsDefaultCellStyle.BackColor = Col $C.RowAlt
$grid.AlternatingRowsDefaultCellStyle.SelectionBackColor = Col $C.Sel
$grid.RowTemplate.Height = 30
$card.Controls.Add($grid)

$colCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colCheck.HeaderText = [char]0x2713
$colCheck.Width = 42
$colCheck.SortMode = 'NotSortable'
[void]$grid.Columns.Add($colCheck)

$colId = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colId.HeaderText = 'ID'
$colId.Width = 46
$colId.ReadOnly = $true
$colId.SortMode = 'NotSortable'
[void]$grid.Columns.Add($colId)

$colSeverity = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colSeverity.HeaderText = 'Nivo'
$colSeverity.Width = 104
$colSeverity.ReadOnly = $true
$colSeverity.SortMode = 'NotSortable'
[void]$grid.Columns.Add($colSeverity)

$colCategory = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colCategory.HeaderText = 'Kategorija'
$colCategory.Width = 140
$colCategory.ReadOnly = $true
$colCategory.SortMode = 'NotSortable'
[void]$grid.Columns.Add($colCategory)

$colProblem = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colProblem.HeaderText = 'Problem'
$colProblem.AutoSizeMode = 'Fill'
$colProblem.ReadOnly = $true
$colProblem.SortMode = 'NotSortable'
[void]$grid.Columns.Add($colProblem)

$colFix = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFix.HeaderText = 'Auto'
$colFix.Width = 60
$colFix.ReadOnly = $true
$colFix.SortMode = 'NotSortable'
[void]$grid.Columns.Add($colFix)

# ---------------------------------------------------------------- statusna traka
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor = Col $C.Card
$statusStrip.SizingGrip = $false
$statusStrip.Font = Fo 'Segoe UI' 9

$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = 'Spreman.'
$statusLabel.Spring = $true
$statusLabel.TextAlign = 'MiddleLeft'
$statusLabel.ForeColor = Col $C.Text
[void]$statusStrip.Items.Add($statusLabel)

$snapStatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$snapStatusLabel.Text = 'Snapshot: nema'
$snapStatusLabel.ForeColor = Col $C.Muted
[void]$statusStrip.Items.Add($snapStatusLabel)

$logLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$logLabel.Text = 'Logovi: Documents\KiRo_PC_Diagnostic_Logs'
$logLabel.ForeColor = Col $C.Muted
[void]$statusStrip.Items.Add($logLabel)

# ---------------------------------------------------------------- raspored
$form.Controls.Add($main)
$form.Controls.Add($header)
$form.Controls.Add($statusStrip)
# Fill kontrola mora biti na indeksu 0 (poslednja se rasporedjuje),
# ivicne trake na vecim indeksima - tako se nista ne preklapa.
$form.Controls.SetChildIndex($main,0)
$form.Controls.SetChildIndex($header,1)
$form.Controls.SetChildIndex($statusStrip,2)
# Isto pravilo i unutar trake sa animacijom: Fill (klizac) je na indeksu 0.
# summaryLabel je takodje Fill, ali je NIKAD vidljiv zajedno sa ostalima
# (Set-KiRoBusyUi pali/gasi cele grupe), pa ne moze da pojede njihov prostor.
$animInner.Controls.SetChildIndex($animTrackWrap,0)
$animInner.Controls.SetChildIndex($animLabel,1)
$animInner.Controls.SetChildIndex($elapsedLabel,2)
$animInner.Controls.SetChildIndex($summaryLabel,3)
# confirmWrap je takodje Fill i NIKAD nije vidljiv zajedno sa ostalima.
$animInner.Controls.SetChildIndex($confirmWrap,4)
$confirmWrap.Controls.SetChildIndex($confirmLabel,0)
$confirmWrap.Controls.SetChildIndex($btnConfirmNo,1)
$confirmWrap.Controls.SetChildIndex($btnConfirmYes,2)

# ================================================================ ANIMACIJA
$script:SpinFrames = @('|','/','-','\')
$script:AnimTick   = 0
$script:JobState   = $null

# Stanje poruka i potvrde. U glavnom toku NEMA modalnih dijaloga - svaka
# poruka se vidi u traci ispod dugmadi i u statusnoj liniji na dnu prozora.
$script:LastResult     = ''
$script:LastResultKind = 'Info'
$script:IdleHint       = ''
$script:ConfirmArmed   = $false
$script:ConfirmTimer   = $null
$script:DetailsForm    = $null
$script:PendingRepair  = @()
$script:ToolsForm      = $null
# Akcije koje GUI sme da izvrsi bez dodatnog pitanja (bezbedne, sa backup-om).
$script:KiRoAllowedFixes = @('TEMP_CLEAN','ORPHAN_STARTUP_REG','ORPHAN_STARTUP_LNK',
                             'ORPHAN_SERVICE_DISABLE','ORPHAN_TASK','ORPHAN_TASK_MS',
                             'EVENTLOG_EXPORT_CLEAR')

function Layout-AnimBand {
    try {
        $w = $animTrackWrap.ClientSize.Width
        $h = $animTrackWrap.ClientSize.Height
        if ($w -lt 120) { return }
        $animTrack.Width = [Math]::Max(80, $w - 36)
        $animTrack.Height = 6
        $animTrack.Left = 18
        $animTrack.Top = [Math]::Max(0, [int](($h - 6) / 2))
        $kw = [int]($animTrack.Width / 5)
        if ($kw -lt 60) { $kw = 60 }
        $animKnob.Size = New-Object System.Drawing.Size($kw,6)
        $animKnob.Top = 0
        if ($animKnob.Left -gt ($animTrack.Width - $animKnob.Width)) {
            $animKnob.Left = [Math]::Max(0, $animTrack.Width - $animKnob.Width)
        }
    } catch {}
}

function Set-KiRoBusyUi {
    param([bool]$Busy)
    $confirmWrap.Visible   = $false
    $summaryLabel.Visible  = -not $Busy
    $animLabel.Visible     = $Busy
    $elapsedLabel.Visible  = $Busy
    $animTrackWrap.Visible = $Busy
    $btnScan.Enabled     = -not $Busy
    $btnRepair.Enabled   = -not $Busy
    $btnTools.Enabled    = -not $Busy
    if ($Busy) { Layout-AnimBand }
}

# ---------------------------------------------------------------- poruke u traci
# Sve poruke idu u traku ispod dugmadi + u statusnu liniju. Nema MessageBox-a
# u glavnom toku, pa nista ne moze da blokira prozor ni da "zbuni" program.
function Update-KiRoIdle {
    $txt = [string]$script:LastResult
    if ($script:IdleHint) {
        if ($txt) { $txt += '   |   ' }
        $txt += [string]$script:IdleHint
    }
    if (-not $txt) { $txt = 'Spreman. Klikni SKENIRAJ. Dvoklik na red u tabeli daje detalje.' }
    $col = switch ([string]$script:LastResultKind) {
        'Ok'    { $C.Ok }
        'Warn'  { $C.Warn }
        'Error' { $C.Danger }
        default { $C.Muted }
    }
    $summaryLabel.ForeColor = Col $col
    $summaryLabel.Text = $txt
    $st = if ($script:LastResult) { $script:LastResult }
          elseif ($script:IdleHint) { $script:IdleHint }
          else { 'Spreman.' }
    $statusLabel.Text = $st
}

function Set-KiRoResult {
    param([string]$Text,[string]$Kind='Info')
    $script:LastResult = $Text
    $script:LastResultKind = $Kind
    Update-KiRoIdle
}

function Set-KiRoHint {
    param([string]$Text)
    $script:IdleHint = $Text
    Update-KiRoIdle
}

# 1 stavka / 2 stavke / 5 stavki
function KiRoStavke {
    param([int]$n)
    if ($n -eq 1) { return "$n stavka" }
    if ($n -ge 2 -and $n -le 4) { return "$n stavke" }
    return "$n stavki"
}

function Hide-KiRoConfirm {
    $script:ConfirmArmed = $false
    $script:PendingRepair = @()
    if ($script:ConfirmTimer) { try { $script:ConfirmTimer.Stop() } catch {} }
    if ($confirmWrap) { $confirmWrap.Visible = $false }
}

function Disarm-KiRoRepair {
    Hide-KiRoConfirm
    $btnRepair.Text = 'POPRAVI OZNACENO'
    $btnRepair.Width = 176
    Set-FlatButton $btnRepair $C.Ok $C.HeadText '#27875A' '#1F6E49' ''
    if (-not $script:JobState) {
        if ($summaryLabel) { $summaryLabel.Visible = $true }
        if ($confirmWrap)  { $confirmWrap.Visible  = $false }
    }
}

# Potvrda popravke BEZ modalnog dijaloga: u traci se pojave poruka i dva
# jasna dugmeta - DA, POPRAVI / NE. Ako se ne potvrdi za 20 s, samo nestane.
function Arm-KiRoRepair {
    param([object[]]$Items)
    $n = @($Items).Count
    $script:PendingRepair = @($Items)
    $script:ConfirmArmed = $true
    $lbl = @($Items | ForEach-Object { Get-KiRoFixLabel $_ } | Select-Object -Unique)
    $lblTxt = ($lbl -join '  +  ')
    $confirmLabel.Text = ("Popraviti " + (KiRoStavke $n) + "?   Prvo Safety Snapshot, pa popravka u pozadini.")
    $summaryLabel.Visible = $false
    $confirmWrap.Visible  = $true
    $statusLabel.Text = ("Cekam potvrdu: " + (KiRoStavke $n) + "  ->  " + $lblTxt)
    if (-not $script:ConfirmTimer) {
        $script:ConfirmTimer = New-Object System.Windows.Forms.Timer
        $script:ConfirmTimer.Interval = 20000
        $script:ConfirmTimer.Add_Tick({
            $script:ConfirmTimer.Stop()
            if ($script:ConfirmArmed) {
                Hide-KiRoConfirm
                $summaryLabel.Visible = $true
                Set-KiRoResult 'Potvrda je istekla - popravka nije pokrenuta.' 'Info'
            }
        })
    }
    $script:ConfirmTimer.Stop()
    $script:ConfirmTimer.Start()
}

function Confirm-KiRoRepair {
    $items = @($script:PendingRepair)
    Hide-KiRoConfirm
    $summaryLabel.Visible = $true
    if (@($items).Count -eq 0) {
        Set-KiRoResult 'Nema stavki za popravku.' 'Warn'
        return
    }
    Start-KiRoJob -Mode 'Repair' -Payload $items
}

function Populate-KiRoGrid {
    $grid.Rows.Clear()
    foreach ($f in @($script:Findings)) {
        $fixable = if ($f.SafeAutoFix -and $f.FixAction) { 'DA' } else { 'NE' }
        # Stavke bezbedne za automatsku popravku su ODMAH oznacene - tako klik na
        # POPRAVI OZNACENO odmah ima smisla. Korisnik moze da skine oznaku.
        $checked = [bool]($f.SafeAutoFix -and $f.FixAction -and
                          ($script:KiRoAllowedFixes -contains [string]$f.FixAction))
        $idx = $grid.Rows.Add($checked,$f.ID,$f.Severity,$f.Category,$f.Problem,$fixable)
        $grid.Rows[$idx].Tag = $f

        $sevCol = switch ([string]$f.Severity) {
            'KRITICNO'   { $C.Danger }
            'UPOZORENJE' { $C.Warn }
            default      { $C.Info }
        }
        $grid.Rows[$idx].Cells[2].Style.ForeColor = Col $sevCol
        $grid.Rows[$idx].Cells[2].Style.Font = New-Object System.Drawing.Font('Segoe UI Semibold',9.5)
        $grid.Rows[$idx].Cells[1].Style.ForeColor = Col $C.Muted
        $grid.Rows[$idx].Cells[5].Style.ForeColor = Col $(if ($fixable -eq 'DA') { $C.Ok } else { $C.Muted })
        $grid.Rows[$idx].Cells[5].Style.Alignment = 'MiddleCenter'
        $grid.Rows[$idx].Cells[0].Style.Alignment = 'MiddleCenter'
    }

    $n = @($script:Findings).Count
    if ($n -eq 0) {
        $summaryLabel.Text = 'Nema pronadjenih problema. Sistem izgleda cisto.'
        return
    }
    $krit = @($script:Findings | Where-Object Severity -eq 'KRITICNO').Count
    $upoz = @($script:Findings | Where-Object Severity -eq 'UPOZORENJE').Count
    $malw = @($script:Findings | Where-Object { $script:KiRoMalwareCategories -contains [string]$_.Category }).Count
    $fixa = @($script:Findings | Where-Object { $_.SafeAutoFix -and $_.FixAction }).Count
    $chk = @($script:Findings | Where-Object { $_.SafeAutoFix -and $_.FixAction -and
              ($script:KiRoAllowedFixes -contains [string]$_.FixAction) }).Count
    $summaryLabel.Text = "Nalaza: $n    KRITICNO: $krit    UPOZORENJE: $upoz    Malware/Telegram: $malw    Za popravku: $fixa    Oznaceno: $chk"
}

function Renumber-KiRoFindings {
    $i = 0
    foreach ($f in @($script:Findings)) {
        $i++
        try { $f.ID = $i } catch {}
    }
}

# ================================================================ POZADINSKI POSAO
# Svi poslovi (sken, popravka, snapshot, undo) idu u pozadinsku nit.
# GUI ostaje responzivan, a anim traka prikazuje stvarni napredak.
function Start-KiRoJob {
    param(
        [ValidateSet('Full','Repair','Snapshot','Undo')][string]$Mode = 'Full',
        [object[]]$Payload = @()
    )
    if ($script:JobState) { return }
    Disarm-KiRoRepair
    if ($Mode -eq 'Repair') { $btnRepair.Text = 'POPRAVLJAM...' }

    $busyTxt = switch ($Mode) {
        'Repair'   { 'Popravljam oznacene stavke...' }
        'Snapshot' { 'Pravim Safety Snapshot...' }
        'Undo'     { 'Vracam poslednju izmenu...' }
        default    { 'Skeniram racunar...' }
    }

    $script:IdleHint = ''
    Set-KiRoBusyUi $true
    $summaryLabel.Text = $busyTxt
    $statusLabel.Text  = $busyTxt
    $animLabel.Text    = '|  Priprema...'
    $elapsedLabel.Text = ''
    if ($Mode -eq 'Full') { $grid.Rows.Clear() }

    # Nalazi za popravku se prenose u pozadinsku nit kao base64 JSON
    # (base64 izbegava svaki problem sa navodnicima i specijalnim znakovima).
    $payloadB64 = ''
    if (@($Payload).Count -gt 0) {
        try {
            $json = ConvertTo-Json -InputObject @($Payload) -Depth 8 -Compress
            $payloadB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        } catch { $payloadB64 = '' }
    }

    $eng = $EnginePath.Replace("'", "''")
    $lines = @(
        '$ErrorActionPreference = ''Continue'''
        '$script:KiRoLibraryMode = $true'
        '$script:KiRoNoTranscript = $true'
        ("try { . '" + $eng + "' } catch { Write-Host ('ENGINE_LOAD_ERROR: ' + `$_.Exception.Message) }")
        ('$mode = ''@MODE@''')
        ('$b64 = ''@B64@''')
        'if ($b64) {'
        '    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))'
        '    $items = @($json | ConvertFrom-Json)'
        '    $script:Findings = New-Object System.Collections.ArrayList'
        '    foreach ($it in $items) { [void]$script:Findings.Add($it) }'
        '}'
        'switch ($mode) {'
        '    ''Full''     { Run-DiagnosticScan; $script:Findings }'
        '    ''Repair''   { Repair-KiRoSelectedFindings -Findings @($script:Findings) }'
        '    ''Snapshot'' { Repair-KiRoSelectedFindings -Findings @() }'
        '    ''Undo''     { Invoke-KiRoUndoLastChange }'
        '}'
    )
    $sb = (($lines -join "`r`n").Replace('@MODE@', $Mode).Replace('@B64@', $payloadB64))

    $rs = $null
    $ps = $null
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($sb)
        $handle = $ps.BeginInvoke()
    } catch {
        try { if ($ps) { $ps.Dispose() } } catch {}
        try { if ($rs) { $rs.Dispose() } } catch {}
        Set-KiRoBusyUi $false
        Set-KiRoResult ('Posao nije mogao da se pokrene: ' + $_.Exception.Message) 'Error'
        return
    }

    $script:JobState = [pscustomobject]@{
        PS       = $ps
        Handle   = $handle
        Runspace = $rs
        Mode     = $Mode
        Started  = Get-Date
        Step     = 0
        Total    = 0
        StepText = 'Priprema...'
    }
    $script:AnimTick = 0
    $animTimer.Start()
}

function Complete-KiRoJob {
    $st = $script:JobState
    if (-not $st) { return }
    $script:JobState = $null
    $animTimer.Stop()
    Disarm-KiRoRepair

    $out = $null
    try { $out = $st.PS.EndInvoke($st.Handle) } catch { $out = $null }

    $secs = ((Get-Date) - $st.Started).TotalSeconds
    $mode = [string]$st.Mode
    $failedJob = $false
    try { $failedJob = ($st.PS.InvocationStateInfo.State -eq 'Failed') } catch {}

    try { $st.PS.Dispose() } catch {}
    try { $st.Runspace.Dispose() } catch {}
    $animLabel.Text = ''

    # ---- POPRAVKA / SNAPSHOT
    if ($mode -eq 'Repair' -or $mode -eq 'Snapshot') {
        $res = $null
        foreach ($o in @($out)) {
            if ($null -ne $o -and $o.PSObject.Properties['Snapshot']) { $res = $o }
        }
        $snap = ''
        $cnt  = 0
        if ($res) {
            try { $snap = [string]$res.Snapshot } catch {}
            try { $cnt  = [int]$res.Count } catch {}
        }
        if ($snap) { $snapStatusLabel.Text = "Snapshot: $(Split-Path $snap -Leaf)" }

        Set-KiRoBusyUi $false

        $snapLeaf = if ($snap) { Split-Path $snap -Leaf } else { 'nema' }
        if ($mode -eq 'Repair') {
            $okN  = 0
            $badN = 0
            try { $okN  = [int]$res.Ok  } catch {}
            try { $badN = [int]$res.Bad } catch {}

            # Izvestaj: tacno se vidi sta je uradjeno, stavku po stavku.
            $rl = New-Object System.Collections.ArrayList
            [void]$rl.Add('IZVESTAJ POPRAVKE')
            [void]$rl.Add('')
            [void]$rl.Add(("Vreme rada      : {0:0.0} s" -f $secs))
            [void]$rl.Add(("Ukupno stavki   : {0}" -f $cnt))
            [void]$rl.Add(("Uspesno         : {0}" -f $okN))
            [void]$rl.Add(("Neuspesno       : {0}" -f $badN))
            [void]$rl.Add(("Safety Snapshot : {0}" -f $snapLeaf))
            [void]$rl.Add('')
            [void]$rl.Add('--- STAVKA PO STAVKA ---')
            $k = 0
            foreach ($rr in @($res.Results)) {
                $k++
                [void]$rl.Add(("{0}) {1}  [{2}]" -f $k, [string]$rr.Label, $(if ([bool]$rr.Success) { 'OK' } else { 'GRESKA' })))
                if ($rr.Message) { [void]$rl.Add('      ' + [string]$rr.Message) }
            }
            if ($k -eq 0) { [void]$rl.Add('(nijedna stavka nije izvrsena)') }
            $report = ($rl -join [Environment]::NewLine)
            try {
                Add-Content -LiteralPath (Join-Path $LogRoot 'KiRo_popravke.log') -Value ((Get-Date).ToString('s') + [Environment]::NewLine + $report + [Environment]::NewLine) -Encoding UTF8
            } catch {}

            if ($failedJob -or $badN -gt 0) {
                Set-KiRoResult ("Popravka zavrsena: uspesno {0}, NEUSPESNO {1} od {2} za {3} s. Otvoren je izvestaj." -f $okN, $badN, $cnt, [math]::Round($secs,1)) 'Error'
            } else {
                Set-KiRoResult ("Popravka zavrsena: {0} za {1} s.  Uspesno {2}/{3}.  Snapshot: {4}." -f (KiRoStavke $cnt), [math]::Round($secs,1), $okN, $cnt, $snapLeaf) 'Ok'
            }
            Show-KiRoDetails $report ("Izvestaj popravke - " + (KiRoStavke $cnt))
            Start-KiRoJob -Mode 'Full'
        } else {
            Set-KiRoResult ("Safety Snapshot napravljen: {0}   ({1} s)." -f $snapLeaf, [math]::Round($secs,1)) 'Ok'
        }
        return
    }

    # ---- UNDO
    if ($mode -eq 'Undo') {
        $res = $null
        foreach ($o in @($out)) {
            if ($null -ne $o -and $o.PSObject.Properties['Success']) { $res = $o }
        }
        Set-KiRoBusyUi $false
        if (-not $res) {
            Set-KiRoResult 'Vracanje nije uspelo - nema odgovora iz modula za undo.' 'Error'
            return
        }
        if ([bool]$res.Success) {
            Set-KiRoResult ("Vraceno: {0}   ({1} s). Skeniram ponovo..." -f $res.Name, [math]::Round($secs,1)) 'Ok'
            Start-KiRoJob -Mode 'Full'
        } else {
            $kind = if ([bool]$res.Manual) { 'Warn' } else { 'Info' }
            Set-KiRoResult ("Undo: {0}" -f [string]$res.Message) $kind
        }
        return
    }

    # ---- SKEN
    $returned = New-Object System.Collections.ArrayList
    foreach ($o in @($out)) {
        if ($null -eq $o) { continue }
        if ($o.PSObject.Properties['Severity'] -and $o.PSObject.Properties['Category'] -and $o.PSObject.Properties['Problem']) {
            [void]$returned.Add($o)
        }
    }

    $script:Findings = $returned
    Renumber-KiRoFindings
    Populate-KiRoGrid
    Set-KiRoBusyUi $false

    if ($failedJob) {
        Set-KiRoResult ("Sken je zavrsen sa greskom posle {0} s." -f [math]::Round($secs,1)) 'Error'
    } else {
        Set-KiRoHint ("Sken zavrsen: {0} nalaza za {1} s.  Oznaci kucice i klikni POPRAVI OZNACENO." -f $returned.Count, [math]::Round($secs,1))
    }
}

function Step-KiRoAnim {
    $st = $script:JobState
    if (-not $st) { return }
    $script:AnimTick++

    # traka zna da ostane nerasporedjena ako je bila skrivena u trenutku layout-a
    $wantTrack = [Math]::Max(80, $animTrackWrap.ClientSize.Width - 36)
    if ($animTrack.Width -ne $wantTrack -and $animTrackWrap.ClientSize.Width -gt 120) {
        Layout-AnimBand
    }

    # citanje napretka iz pozadinske niti
    try {
        $recs = $st.PS.Streams.Information.ReadAll()
        foreach ($r in @($recs)) {
            $msg = [string]$r.MessageData.Message
            if ($msg -match '>>>\s*(?:(\d+)\s*/\s*(\d+)\s+)?(.+)$') {
                if ($Matches[1]) {
                    $st.Step = [int]$Matches[1]
                    $st.Total = [int]$Matches[2]
                }
                $st.StepText = $Matches[3].Trim()
            }
        }
    } catch {}

    $spin = $script:SpinFrames[$script:AnimTick % 4]
    $secs = ((Get-Date) - $st.Started).TotalSeconds
    $cnt  = if ($st.Total -gt 0) { "$($st.Step)/$($st.Total)  " } else { '' }
    $verb = switch ([string]$st.Mode) {
        'Repair'   { 'Popravljam' }
        'Snapshot' { 'Radim' }
        'Undo'     { 'Vracam' }
        default    { 'Skeniram' }
    }
    $animLabel.Text = "$spin  $verb`: $($st.StepText)"
    $elapsedLabel.Text = ("{0}{1:0.0} s" -f $cnt, $secs)

    # klizac (marquee) levo-desno
    $span = $animTrack.Width - $animKnob.Width
    if ($span -gt 0) {
        $phase = ($script:AnimTick % 40) / 40.0
        $p = if ($phase -le 0.5) { $phase * 2 } else { (1 - $phase) * 2 }
        $animKnob.Left = [int]($p * $span)
    }
    if (($script:AnimTick % 20) -lt 10) {
        $animKnob.BackColor = Col $C.Accent
    } else {
        $animKnob.BackColor = Col $C.AccentLt
    }

    $state = 'Running'
    try { $state = [string]$st.PS.InvocationStateInfo.State } catch {}
    if ($state -in @('Completed','Failed','Stopped')) {
        Complete-KiRoJob
    }
}

$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 90
$animTimer.Add_Tick({ Step-KiRoAnim })

# ================================================================ POPRAVKA
function Get-GuiSelectedFindings {
    $list = New-Object System.Collections.ArrayList
    foreach ($row in $grid.Rows) {
        if ($row.IsNewRow) { continue }
        if ([bool]$row.Cells[0].Value -and $row.Tag) { [void]$list.Add($row.Tag) }
    }
    return @($list)
}

function Show-KiRoFindingDetails {
    param($f)
    if (-not $f) { return }
    $text = "ID: $($f.ID)" + [Environment]::NewLine +
            "Nivo: $($f.Severity)" + [Environment]::NewLine +
            "Kategorija: $($f.Category)" + [Environment]::NewLine + [Environment]::NewLine +
            $f.Problem + [Environment]::NewLine + [Environment]::NewLine +
            "Preporuka: $($f.Recommendation)"
    if ($script:KiRoMalwareCategories -contains [string]$f.Category) {
        $text += [Environment]::NewLine + [Environment]::NewLine +
            'KiRo ovaj nalaz ne menja automatski. Za karantin / whitelist koristi ALATI -> MALWARE.'
    }
    Show-KiRoDetails $text ("Detalji nalaza #" + $f.ID)
}

# Detalji se prikazuju u NEZAVISNOM prozoru (Show, ne ShowDialog) - glavni
# prozor ostaje upotrebljiv i nista se ne blokira.
function Show-KiRoDetails {
    param([string]$Text,[string]$Caption='Detalji')
    try {
        if ($script:DetailsForm -and -not $script:DetailsForm.IsDisposed) { $script:DetailsForm.Close() }
    } catch {}
    $df = New-Object System.Windows.Forms.Form
    $df.Text = "KiRo - $Caption"
    $df.Size = New-Object System.Drawing.Size(600,400)
    $df.StartPosition = 'CenterScreen'
    $df.MinimizeBox = $false
    $df.MaximizeBox = $false
    $df.ShowIcon = $false
    $df.ShowInTaskbar = $false
    $df.KeyPreview = $true
    $df.BackColor = Col $C.Card
    $df.ForeColor = Col $C.Text
    $df.Font = Fo 'Segoe UI' 9.5

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true
    $tb.ReadOnly = $true
    $tb.ScrollBars = 'Vertical'
    $tb.WordWrap = $true
    $tb.Dock = 'Fill'
    $tb.BorderStyle = 'FixedSingle'
    $tb.BackColor = Col $C.Card
    $tb.ForeColor = Col $C.Text
    $tb.Font = Fo 'Segoe UI' 9.5
    $tb.Text = $Text

    $pad = New-Object System.Windows.Forms.Panel
    $pad.Dock = 'Fill'
    $pad.Padding = New-Object System.Windows.Forms.Padding(14,14,14,8)
    $pad.BackColor = Col $C.Card
    $pad.Controls.Add($tb)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'ZATVORI'
    $btnClose.Dock = 'Bottom'
    $btnClose.Height = 36
    $btnClose.Margin = New-Object System.Windows.Forms.Padding(14,0,14,12)
    Set-FlatButton $btnClose $C.Accent $C.HeadText $C.AccentDk $C.AccentDk ''
    $btnClose.Add_Click({ try { $script:DetailsForm.Close() } catch {} })

    $foot = New-Object System.Windows.Forms.Panel
    $foot.Dock = 'Bottom'
    $foot.Height = 50
    $foot.Padding = New-Object System.Windows.Forms.Padding(14,6,14,10)
    $foot.BackColor = Col $C.Card
    $foot.Controls.Add($btnClose)

    $df.Controls.Add($pad)
    $df.Controls.Add($foot)
    $df.Controls.SetChildIndex($pad,0)
    $df.Controls.SetChildIndex($foot,1)
    $df.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { try { $script:DetailsForm.Close() } catch {} } })

    $script:DetailsForm = $df
    $df.Show()
    $df.Activate()
}

function Repair-GuiSelected {
    if ($script:JobState) {
        Set-KiRoResult 'Sacekaj da se trenutni posao (sken ili popravka) zavrsi.' 'Warn'
        return
    }
    $selected = @(Get-GuiSelectedFindings)
    if ($selected.Count -eq 0) {
        Disarm-KiRoRepair
        Set-KiRoResult 'Nisi oznacio nijedan problem. Klikni kucicu u prvom stupcu kod zeljenog reda.' 'Warn'
        return
    }

    $repairable = @($selected | Where-Object { $_.SafeAutoFix -and $_.FixAction -and ($script:KiRoAllowedFixes -contains [string]$_.FixAction) })
    if ($repairable.Count -eq 0) {
        Disarm-KiRoRepair
        $onlyMal = @($selected | Where-Object { $script:KiRoMalwareCategories -contains [string]$_.Category }).Count -eq $selected.Count
        if ($onlyMal) {
            Set-KiRoResult 'Malware / Telegram nalazi se NAMERNO ne popravljaju automatski. Za karantin otvori ALATI -> MALWARE.' 'Warn'
        } else {
            Set-KiRoResult 'Oznacene stavke nisu pogodne za bezbednu automatsku popravku. Otvori ALATI za napredne module.' 'Warn'
        }
        return
    }

    # Potvrda bez modalnog dijaloga: u traci se pojave dugmadi DA, POPRAVI / NE.
    if (-not $script:ConfirmArmed) {
        Arm-KiRoRepair $repairable
        return
    }
    Confirm-KiRoRepair
}

# ---------------------------------------------------------------- ALATI
# Umesto crnog konzolnog menija sa 12 opcija koje se kucaju, ALATI sada
# otvara prozor sa dugmadima. Klik vodi pravo u zeljeni modul, bez
# ponovnog skena cele masine.
function Show-KiRoTools {
    # Svaka greska se prikazuje u traci - nikad tiho "nista se ne desi".
    try { Show-KiRoToolsInner }
    catch { Set-KiRoResult ('ALATI ne moze da se otvori: ' + $_.Exception.Message) 'Error' }
}

function Show-KiRoToolsInner {
    try {
        if ($script:ToolsForm -and -not $script:ToolsForm.IsDisposed) {
            $script:ToolsForm.Activate()
            return
        }
    } catch {}

    $tf = New-Object System.Windows.Forms.Form
    $tf.Text = 'KiRo - ALATI'
    $tf.ClientSize = New-Object System.Drawing.Size(560,472)
    $tf.StartPosition = 'CenterParent'
    $tf.FormBorderStyle = 'FixedDialog'
    $tf.MaximizeBox = $false
    $tf.MinimizeBox = $false
    $tf.ShowIcon = $false
    $tf.KeyPreview = $true
    $tf.BackColor = Col $C.Card
    $tf.ForeColor = Col $C.Text
    $tf.Font = Fo 'Segoe UI' 9.5
    $script:ToolsForm = $tf

    $hdr = New-Object System.Windows.Forms.Label
    $hdr.Dock = 'Top'
    $hdr.Height = 48
    $hdr.TextAlign = 'MiddleLeft'
    $hdr.Padding = New-Object System.Windows.Forms.Padding(16,0,10,0)
    $hdr.Text = 'ALATI  -  klikni modul (otvara se u zasebnom prozoru)'
    $hdr.BackColor = Col $C.Head
    $hdr.ForeColor = Col $C.HeadText
    $hdr.Font = Fo 'Segoe UI Semibold' 10.5
    $tf.Controls.Add($hdr)

    # --- traka 2: dugmad prebacena sa glavnog ekrana (SNAPSHOT / UNDO / LOGOVI)
    $toolBar2 = New-Object System.Windows.Forms.FlowLayoutPanel
    $toolBar2.Dock = 'Bottom'
    $toolBar2.Height = 58
    $toolBar2.FlowDirection = 'LeftToRight'
    $toolBar2.WrapContents = $false
    $toolBar2.Padding = New-Object System.Windows.Forms.Padding(14,10,14,4)
    $toolBar2.BackColor = Col $C.Card
    $tf.Controls.Add($toolBar2)

    $btnToolsSnapshot = New-Object System.Windows.Forms.Button
    $btnToolsSnapshot.Text = 'SNAPSHOT'
    $btnToolsSnapshot.Size = New-Object System.Drawing.Size(160,36)
    $btnToolsSnapshot.Margin = New-Object System.Windows.Forms.Padding(0,0,10,0)
    $btnToolsSnapshot.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $btnToolsSnapshot $C.BtnLight $C.Head $C.BtnLightH '#DCE8F8' $C.Border
    $toolBar2.Controls.Add($btnToolsSnapshot)

    $btnToolsUndo = New-Object System.Windows.Forms.Button
    $btnToolsUndo.Text = 'UNDO'
    $btnToolsUndo.Size = New-Object System.Drawing.Size(160,36)
    $btnToolsUndo.Margin = New-Object System.Windows.Forms.Padding(0,0,10,0)
    $btnToolsUndo.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $btnToolsUndo $C.BtnLight $C.Head $C.BtnLightH '#DCE8F8' $C.Border
    $toolBar2.Controls.Add($btnToolsUndo)

    $btnToolsLogs = New-Object System.Windows.Forms.Button
    $btnToolsLogs.Text = 'LOGOVI'
    $btnToolsLogs.Size = New-Object System.Drawing.Size(160,36)
    $btnToolsLogs.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $btnToolsLogs $C.BtnLight $C.Head $C.BtnLightH '#DCE8F8' $C.Border
    $toolBar2.Controls.Add($btnToolsLogs)

    $closeBar = New-Object System.Windows.Forms.Panel
    $closeBar.Dock = 'Bottom'
    $closeBar.Height = 56
    $closeBar.Padding = New-Object System.Windows.Forms.Padding(14,4,14,14)
    $closeBar.BackColor = Col $C.Card
    $tf.Controls.Add($closeBar)

    $hostPad = New-Object System.Windows.Forms.Panel
    $hostPad.Dock = 'Fill'
    $hostPad.Padding = New-Object System.Windows.Forms.Padding(14,12,14,6)
    $hostPad.BackColor = Col $C.Card
    $tf.Controls.Add($hostPad)

    $btnCloseTools = New-Object System.Windows.Forms.Button
    $btnCloseTools.Text = 'ZATVORI'
    $btnCloseTools.Dock = 'Right'
    $btnCloseTools.Width = 130
    $btnCloseTools.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $btnCloseTools $C.BtnLight $C.Head $C.BtnLightH '#DCE8F8' $C.Border
    $btnCloseTools.Add_Click({ try { $script:ToolsForm.Close() } catch {} })
    $closeBar.Controls.Add($btnCloseTools)

    # Raspored ide od NAJVECEG indeksa ka najmanjem:
    #   hdr(3) uzima vrh, closeBar(2) samo dno, toolBar2(1) iznad njega,
    #   hostPad(0, Fill) dobija ostatak. Bez ovoga se trake preklapaju.
    $tf.Controls.SetChildIndex($hostPad,0)
    $tf.Controls.SetChildIndex($toolBar2,1)
    $tf.Controls.SetChildIndex($closeBar,2)
    $tf.Controls.SetChildIndex($hdr,3)

    $tbl = New-Object System.Windows.Forms.TableLayoutPanel
    $tbl.Dock = 'Fill'
    $tbl.ColumnCount = 1
    $tbl.BackColor = Col $C.Card
    $hostPad.Controls.Add($tbl)

    $defs = @(
        @('MALWARE / TELEGRAM  -  karantin, brisanje, whitelist','Malware','Malware / Telegram',      $C.Danger,
          'Skenira sumnjive fajlove i procese. Ti oznacavas sta ide u KARANTIN (moze da se vrati), sta se brise, ili sta se dozvoljava (whitelist).'),
        @('DUBINSKA PROVERA  -  samo indikatori, nista se ne brise','Indicators','Dubinska provera',  $C.Warn,
          'Prikazuje indikatore: WMI trajnost, IFEO Debugger, AppInit_DLLs, autorun.inf, Telegram folder. Nista ne menja i ne brise.'),
        @('WINDOWS POPRAVKA  -  DISM / SFC','WindowsRepair','Windows popravka',                       $C.Accent,
          'Pokrece DISM i SFC da popravi sistemske fajlove. Moze da traje 10-30 minuta.'),
        @('PERFORMANSA  -  startup, pozadinski procesi, RAM','Performance','Performansa',              $C.Info,
          'Prikaz startup programa, pozadinskih procesa i potrosnje RAM-a. Zaustavljas samo ono sto sam izaberes.'),
        @('EKRAN  -  najveci Hz / FPS','Display','Ekran',                                             $C.Info,
          'Nalazi najveci Hz/FPS za trenutnu rezoluciju. Rezolucija se ne menja.'),
        @('DEFENDER PROVERE  -  ukljuci / iskljuci','ToggleDefender','Defender provere',              $C.Muted,
          'Ukljucuje ili iskljucuje Defender provere unutar KiRo skena. Ne dira podesavanja Windows Defender-a.'),
        @('PUN KONZOLNI MENI  -  sve opcije (skenira pa nudi meni)','Menu','Pun konzolni meni',      $C.Muted,
          'Otvara stari konzolni meni sa svim opcijama. Prvo uradi sken, pa nudi izbor.')
    )
    $tbl.RowCount = $defs.Count
    for ($i = 0; $i -lt $defs.Count; $i++) {
        [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle(
            [System.Windows.Forms.SizeType]::Absolute, 40)))
    }
    # Paznja: brojac reda mora biti svoj. `for` petlja iznad ostavi $i = Count,
    # pa je ranije svih 7 dugmadi islo u nepostojeci red -> prozor se nije otvarao.
    # Tooltipovi i u ALATI prozoru - svaki modul objasni sta radi.
    $tip2 = New-Object System.Windows.Forms.ToolTip
    $tip2.InitialDelay = 300
    $tip2.ReshowDelay  = 80
    $tip2.AutoPopDelay = 30000
    $tip2.ShowAlways   = $true

    $ri = 0
    foreach ($d in $defs) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = [string]$d[0]
        $b.Dock = 'Fill'
        $b.TextAlign = 'MiddleLeft'
        $b.Padding = New-Object System.Windows.Forms.Padding(12,0,0,0)
        $b.Margin = New-Object System.Windows.Forms.Padding(0,0,0,4)
        $b.Font = Fo 'Segoe UI Semibold' 9.5
        Set-FlatButton $b $C.BtnLight ([string]$d[3]) $C.BtnLightH '#DCE8F8' $C.Border
        $b.Tag = @([string]$d[1],[string]$d[2])
        try { $tip2.SetToolTip($b,[string]$d[4]) } catch {}
        $b.Add_Click({
            $t = $this.Tag
            Start-KiRoConsoleModule -Action ([string]$t[0]) -Title ([string]$t[1])
        })
        $tbl.Controls.Add($b, 0, $ri)
        $ri++
    }

    # Prebacena dugmad: zatvore ALATI pa pokrenu posao, da se na glavnom
    # prozoru odmah vidi animacija i rezultat (bez sakrivanja signala).
    $btnToolsSnapshot.Add_Click({
        try { $script:ToolsForm.Close() } catch {}
        Start-KiRoJob -Mode 'Snapshot'
    })
    $btnToolsUndo.Add_Click({
        try { $script:ToolsForm.Close() } catch {}
        Start-KiRoJob -Mode 'Undo'
    })
    $btnToolsLogs.Add_Click({ try { Start-Process explorer.exe $LogRoot } catch {} })

    try { $tip2.SetToolTip($btnToolsSnapshot,'Pravi Safety Snapshot trenutnog stanja (startup, servisi, zakazani zadaci) bez ikakve izmene. Snapshot se pravi i automatski pre svake popravke.') } catch {}
    try { $tip2.SetToolTip($btnToolsUndo,'Vraca poslednju izmenu koju je KiRo uradio - npr. vrati premestenu Startup precicu iz backup-a.') } catch {}
    try { $tip2.SetToolTip($btnToolsLogs,'Otvara folder sa svim logovima i backup zapisima: Documents\KiRo_PC_Diagnostic_Logs.') } catch {}
    try { $tip2.SetToolTip($btnCloseTools,'Zatvara prozor ALATI. Glavni prozor ostaje otvoren.') } catch {}
    $tf.Add_FormClosed({ try { $tip2.Dispose() } catch {} })

    $tf.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { try { $script:ToolsForm.Close() } catch {} } })
    $tf.Add_FormClosed({ try { $script:ToolsForm = $null } catch {} })
    $tf.Show($form)
}

# ---------------------------------------------------------------- tooltipovi
# Objasnjenje se pojavi kada se mis zadrzi na dugmetu - da se ne mora
# pogadjati sta koje dugme radi.
$script:Tip = New-Object System.Windows.Forms.ToolTip
$script:Tip.InitialDelay  = 300
$script:Tip.ReshowDelay   = 80
$script:Tip.AutoPopDelay  = 30000
$script:Tip.ShowAlways    = $true

function Set-Tip {
    param($Control,[string]$Text)
    if ($Control -and $Text) {
        try { $script:Tip.SetToolTip($Control,$Text) } catch {}
    }
}

Set-Tip $btnScan 'Skenira ceo sistem: disk, RAM, startup, servisi, zakazani zadaci, Event Log, Defender i malware/Telegram indikatori. Nista se ne menja - samo pregled.'
Set-Tip $btnRepair 'Popravlja SAMO stavke sa kucicom. Prvo pita DA/NE, pa pravi Safety Snapshot i radi u pozadini. Pokvareni unosi se prebacuju u backup, ne brisu se trajno.'
Set-Tip $btnTools 'Dodatni moduli: MALWARE/TELEGRAM karantin, dubinska provera indikatora, Windows popravka (DISM/SFC), performansa, ekran (Hz/FPS), Defender provere. Tu su i SNAPSHOT, UNDO i LOGOVI.'
Set-Tip $btnConfirmYes 'Potvrdjuje popravku oznacenih stavki. Prvo se pravi Safety Snapshot, pa popravka ide u pozadini - traka pokazuje napredak stavku po stavku.'
Set-Tip $btnConfirmNo 'Otkazuje popravku. Nista se ne menja i nista se ne brise.'

# ---------------------------------------------------------------- dogadjaji
$btnScan.Add_Click({ Start-KiRoJob -Mode 'Full' })
$btnRepair.Add_Click({ Repair-GuiSelected })
$btnConfirmYes.Add_Click({ Confirm-KiRoRepair })
$btnConfirmNo.Add_Click({
    Hide-KiRoConfirm
    $summaryLabel.Visible = $true
    Set-KiRoResult 'Otkazano - nista nije menjano.' 'Info'
})
$btnTools.Add_Click({ Show-KiRoTools })

$grid.Add_CellDoubleClick({
    param($sender,$e)
    if ($e.RowIndex -lt 0) { return }
    $row = $grid.Rows[$e.RowIndex]
    if (-not $row.Tag) { return }
    Show-KiRoFindingDetails $row.Tag
})

$animTrackWrap.Add_SizeChanged({ Layout-AnimBand })

$form.Add_Shown({
    Layout-AnimBand
    Set-KiRoBusyUi $false
    Start-KiRoJob -Mode 'Full'
})

$form.Add_FormClosed({
    try { $animTimer.Stop(); $animTimer.Dispose() } catch {}
    try {
        if ($script:JobState) {
            $script:JobState.PS.Stop()
            $script:JobState.PS.Dispose()
            $script:JobState.Runspace.Dispose()
            $script:JobState = $null
        }
    } catch {}
    try { Stop-Transcript | Out-Null } catch {}
})

if ($TestMode) {
    Layout-AnimBand
    Write-Host 'GUI_BUILD_OK'
    Write-Host ("FORM {0}x{1}  dpiScale={2}  MAX_DIP={3}" -f $form.Size.Width,$form.Size.Height,$dpiScale,$MAX_DIP)
    Write-Host ("DUGMAD {0}: {1}" -f $toolbar.Controls.Count, (($toolbar.Controls | ForEach-Object { $_.Text }) -join ' | '))
    try { Stop-Transcript | Out-Null } catch {}
    exit 0
}

[void]$form.ShowDialog()
