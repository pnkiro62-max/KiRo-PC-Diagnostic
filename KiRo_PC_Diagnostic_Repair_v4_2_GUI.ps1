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
    [System.Windows.Forms.MessageBox]::Show("KiRo GUI greska:" + [Environment]::NewLine + [Environment]::NewLine + $m, 'KiRo v4.2', 'OK', 'Error') | Out-Null
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
$EnginePath = Join-Path $PSScriptRoot 'KiRo_PC_Diagnostic_Repair_v4_2_ENGINE.ps1'
if (-not (Test-Path -LiteralPath $EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show("Nedostaje ENGINE fajl:" + [Environment]::NewLine + $EnginePath,'KiRo v4.2') | Out-Null
    exit
}
. $EnginePath
function Pause-KiRo { }

function Show-KiRoMessage {
    param([string]$Text,[string]$Title='KiRo v4.2',[string]$Kind='Info')
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
        Set-KiRoResult ("Otvoren modul: " + $nm + ".  Radi u zasebnom prozoru (naslov: KiRo v4.2 - ALATI: " + $Action + "). Ovaj prozor ostaje slobodan.") 'Info'
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
$form.Text = 'KiRo PC Diagnostic & Repair v4.2'
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
$subtitle.Text = 'v4.2   |   Skeniraj  ->  Oznaci  ->  Popravi'
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

# --- red 1: 4 dugmeta (SKENIRAJ / POPRAVI OZNACENO / ALATI / PLUGINI)
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
$btnPlugins = New-TopButton 'PLUGINI' 130 $C.Info $C.HeadText $C.AccentLt $C.AccentLt ''
$toolbar.Controls.AddRange(@($btnScan,$btnRepair,$btnTools,$btnPlugins))

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

# --- ponuda alata (v4.1): kada oznacena stavka NE moze automatski,
# ovde se nude dugmad tacno onog alata koji je resava (umesto slepe poruke).
$toolWrap = New-Object System.Windows.Forms.Panel
$toolWrap.Dock = 'Fill'
$toolWrap.Visible = $false
$toolWrap.Padding = New-Object System.Windows.Forms.Padding(0,7,0,7)
$toolWrap.BackColor = [System.Drawing.Color]::Transparent
$animInner.Controls.Add($toolWrap)

$toolLabel = New-Object System.Windows.Forms.Label
$toolLabel.Dock = 'Fill'
$toolLabel.TextAlign = 'MiddleLeft'
$toolLabel.AutoEllipsis = $true
$toolLabel.Text = ''
$toolLabel.ForeColor = Col $C.Warn
$toolLabel.BackColor = [System.Drawing.Color]::Transparent
$toolLabel.Font = Fo 'Segoe UI Semibold' 9.5
$toolWrap.Controls.Add($toolLabel)

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
# Ista prica i za ponudu alata: Fill, nikad vidljiva zajedno sa ostalima.
$animInner.Controls.SetChildIndex($toolWrap,5)
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
# v4.1: dodate su i dve akcije koje je ENGINE vec oznacavao kao bezbedne,
# a GUI ih je ranije odbijao (kolona "Auto" je pisala DA, popravka nije radila).
$script:KiRoAllowedFixes = @('TEMP_CLEAN','ORPHAN_STARTUP_REG','ORPHAN_STARTUP_LNK',
                             'ORPHAN_SERVICE_DISABLE','ORPHAN_TASK','ORPHAN_TASK_MS',
                             'EVENTLOG_EXPORT_CLEAR','DEFENDER_REALTIME',
                             'MICROSOFT_TASK_REPAIR')

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
    $toolWrap.Visible      = $false
    $summaryLabel.Visible  = -not $Busy
    $animLabel.Visible     = $Busy
    $elapsedLabel.Visible  = $Busy
    $animTrackWrap.Visible = $Busy
    $btnScan.Enabled     = -not $Busy
    $btnRepair.Enabled   = -not $Busy
    $btnTools.Enabled    = -not $Busy
    $btnPlugins.Enabled  = -not $Busy
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
    if ($toolWrap) { $toolWrap.Visible = $false }
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
        [ValidateSet('Full','Repair','Snapshot','Undo','Malware','Tool','Indicators')][string]$Mode = 'Full',
        [object[]]$Payload = @(),
        [string]$Action = ''
    )
    if ($script:JobState) { return }
    Disarm-KiRoRepair
    if ($Mode -eq 'Repair') { $btnRepair.Text = 'POPRAVLJAM...' }

    $busyTxt = switch ($Mode) {
        'Repair'     { 'Popravljam oznacene stavke...' }
        'Snapshot'   { 'Pravim Safety Snapshot...' }
        'Undo'       { 'Vracam poslednju izmenu...' }
        'Malware'    { 'Radim nad sumnjivim stavkama...' }
        'Tool'       { 'Pokrecem alat...' }
        'Indicators' { 'Dubinska provera indikatora...' }
        default      { 'Skeniram racunar...' }
    }

    $script:IdleHint = ''
    Set-KiRoBusyUi $true
    $summaryLabel.Text = $busyTxt
    $statusLabel.Text  = $busyTxt
    $animLabel.Text    = '|  Priprema...'
    $elapsedLabel.Text = ''
    if ($Mode -eq 'Full' -or $Mode -eq 'Indicators') { $grid.Rows.Clear() }

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
        ('$act = ''@ACT@''')
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
        '    ''Malware''    { Invoke-KiRoMalwareActions -Mode $act -Items @($script:Findings) }'
        '    ''Tool''       { Invoke-KiRoToolFix -Action $act }'
        '    ''Indicators'' { Run-MalwareIndicatorScan; $script:Findings }'
        '}'
    )
    $sb = (($lines -join "`r`n").Replace('@MODE@', $Mode).Replace('@ACT@', $Action).Replace('@B64@', $payloadB64))

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
        Action   = $Action
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

    # ---- MALWARE / KARANTIN (v4.1)
    if ($mode -eq 'Malware') {
        Set-KiRoBusyUi $false
        $act = [string]$st.Action
        if ($act -eq 'List') {
            $cands = New-Object System.Collections.ArrayList
            foreach ($o in @($out)) {
                if ($null -eq $o) { continue }
                if ($o.PSObject.Properties['Score'] -and $o.PSObject.Properties['Path']) { [void]$cands.Add($o) }
            }
            $script:QCandidates = @($cands)
            Populate-QuarantineGrid $script:QCandidates
            Set-KiRoResult ("Karantin: pronadjeno {0} sumnjivih stavki za {1} s." -f $cands.Count, [math]::Round($secs,1)) 'Ok'
            return
        }
        $res = $null
        foreach ($o in @($out)) {
            if ($null -ne $o -and $o.PSObject.Properties['Results']) { $res = $o }
        }
        $okN = 0
        $badN = 0
        if ($res) {
            try { $okN = [int]$res.Ok } catch {}
            try { $badN = [int]$res.Bad } catch {}
        }
        $verb = switch ($act) {
            'Quarantine' { 'KARANTIN' }
            'Delete'     { 'BRISANJE' }
            'Whitelist'  { 'DOZVOLJENE STAVKE' }
            default      { $act }
        }
        $rl = New-Object System.Collections.ArrayList
        [void]$rl.Add('IZVESTAJ: ' + $verb)
        [void]$rl.Add('')
        [void]$rl.Add(('Vreme rada   : {0:0.0} s' -f $secs))
        [void]$rl.Add(('Ukupno       : {0}' -f $(if ($res) { [int]$res.Count } else { 0 })))
        [void]$rl.Add(('Uspesno      : {0}' -f $okN))
        [void]$rl.Add(('Neuspesno    : {0}' -f $badN))
        [void]$rl.Add('')
        [void]$rl.Add('--- STAVKA PO STAVKA ---')
        $k = 0
        if ($res) {
            foreach ($rr in @($res.Results)) {
                $k++
                [void]$rl.Add(('{0}) {1}  [{2}]' -f $k, [string]$rr.Label, $(if ([bool]$rr.Success) { 'OK' } else { 'GRESKA' })))
                [void]$rl.Add('      ' + [string]$rr.Path)
                if ($rr.Message) { [void]$rl.Add('      ' + [string]$rr.Message) }
            }
        }
        if ($k -eq 0) { [void]$rl.Add('(nijedna stavka nije izvrsena)') }
        $report = ($rl -join [Environment]::NewLine)
        try {
            Add-Content -LiteralPath (Join-Path $LogRoot 'KiRo_popravke.log') -Value ((Get-Date).ToString('s') + [Environment]::NewLine + $report + [Environment]::NewLine) -Encoding UTF8
        } catch {}
        if ($failedJob -or $badN -gt 0) {
            Set-KiRoResult ("{0} zavrseno: uspesno {1}, NEUSPESNO {2} za {3} s. Otvoren je izvestaj." -f $verb, $okN, $badN, [math]::Round($secs,1)) 'Error'
        } else {
            Set-KiRoResult ("{0} zavrseno: {1} za {2} s." -f $verb, (KiRoStavke $(if ($res) { [int]$res.Count } else { 0 })), [math]::Round($secs,1)) 'Ok'
        }
        Show-KiRoDetails $report ('Karantin - ' + $verb)
        Start-KiRoJob -Mode 'Malware' -Action 'List'
        return
    }

    # ---- ALAT (v4.1): DISM/SFC, Defender, Security log - bez konzole
    if ($mode -eq 'Tool') {
        Set-KiRoBusyUi $false
        $res = $null
        foreach ($o in @($out)) {
            if ($null -ne $o -and $o.PSObject.Properties['Action']) { $res = $o }
        }
        if (-not $res) {
            Set-KiRoResult 'Alat nije vratio rezultat.' 'Error'
            return
        }
        $kind = if ([bool]$res.Success) { 'Ok' } else { 'Warn' }
        Set-KiRoResult ("Alat gotov za {0} s.  {1}" -f [math]::Round($secs,1), [string]$res.Message) $kind
        $rl2 = New-Object System.Collections.ArrayList
        [void]$rl2.Add('IZVESTAJ ALATA')
        [void]$rl2.Add('')
        [void]$rl2.Add(('Akcija     : {0}' -f [string]$res.Action))
        [void]$rl2.Add(('Vreme rada : {0:0.0} s' -f $secs))
        [void]$rl2.Add(('Ishod      : {0}' -f $(if ([bool]$res.Success) { 'USPESNO' } else { 'Treba paznja' })))
        [void]$rl2.Add('')
        [void]$rl2.Add([string]$res.Message)
        Show-KiRoDetails ($rl2 -join [Environment]::NewLine) ('Alat - ' + [string]$res.Action)
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
        if ($mode -eq 'Indicators') {
            Set-KiRoHint ("Dubinska provera zavrsena: {0} indikatora za {1} s.  Oznaci kucice i klikni POPRAVI OZNACENO." -f $returned.Count, [math]::Round($secs,1))
        } else {
            Set-KiRoHint ("Sken zavrsen: {0} nalaza za {1} s.  Oznaci kucice i klikni POPRAVI OZNACENO." -f $returned.Count, [math]::Round($secs,1))
        }
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
        'Repair'     { 'Popravljam' }
        'Snapshot'   { 'Radim' }
        'Undo'       { 'Vracam' }
        'Malware'    { 'Radim' }
        'Tool'       { 'Alat' }
        'Indicators' { 'Proveravam' }
        default      { 'Skeniram' }
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
            'KiRo ovaj nalaz ne menja automatski. Za karantin / whitelist koristi ALATI -> MALWARE (otvara prozor KARANTIN).'
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
            Set-KiRoResult 'Malware / Telegram nalazi se NAMERNO ne popravljaju automatski.' 'Warn'
        } else {
            Set-KiRoResult 'Oznacene stavke nisu pogodne za bezbednu automatsku popravku.' 'Warn'
        }
        # v4.1: umesto slepe ulice, odmah nudimo dugme alata koji ih resava.
        Show-KiRoToolOffers -Findings $selected -Message ("Ove stavke idu preko alata (" + (KiRoStavke $selected.Count) + "):")
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
    $hdr.Text = 'ALATI  -  klikni modul (GUI moduli rade u glavnom prozoru)'
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

    # v4.1: gde god je moguce, modul ide kroz GUI (pozadinska nit + izvestaj),
    # a ne kroz crnu konzolu. Konzola ostaje samo za module koji traze kucanje.
    $defs = @(
        @('MALWARE / TELEGRAM  -  prozor KARANTIN','KARANTIN','Malware / Telegram',      $C.Danger,
          'Otvara prozor KARANTIN: tabela sumnjivih fajlova i procesa sa ocenom rizika i razlogom. Ti oznacavas sta ide u karantin (moze da se vrati), sta se brise, ili sta se dozvoljava.'),
        @('DUBINSKA PROVERA  -  indikatori u tabeli','GUI:Indicators','Dubinska provera',  $C.Warn,
          'Prikazuje indikatore u glavnoj tabeli: WMI trajnost, IFEO Debugger, AppInit_DLLs, autorun.inf, Telegram folder. Nista ne menja i ne brise.'),
        @('WINDOWS POPRAVKA  -  DISM / SFC','GUI:WindowsRepair','Windows popravka',                       $C.Accent,
          'DISM CheckHealth u pozadini. Ako Windows prijavi da je potrebna popravka, pokrece se i SFC. Bez konzole.'),
        @('PERFORMANSA  -  startup, pozadinski procesi, RAM','Performance','Performansa',              $C.Info,
          'Prikaz startup programa, pozadinskih procesa i potrosnje RAM-a. Zaustavljas samo ono sto sam izaberes (konzolni modul).'),
        @('EKRAN  -  najveci Hz / FPS','Display','Ekran',                                             $C.Info,
          'Nalazi najveci Hz/FPS za trenutnu rezoluciju. Rezolucija se ne menja (konzolni modul).'),
        @('DEFENDER POPRAVKA  -  definicije, pretnje, zastita','GUI:DefenderFix','Defender popravka',   $C.Ok,
          'Azurira Defender definicije, uklanja aktivne pretnje i ukljucuje real-time zastitu. Radi u pozadini, bez konzole.'),
        @('PUN KONZOLNI MENI  -  sve opcije (kuca se)','Menu','Pun konzolni meni',      $C.Muted,
          'Konzolni meni sa svim opcijama: dubinska DISM popravka, performansa, ekran, sigurnosni modul. Ovde se izbor kuca.')
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
            $act = [string]$t[0]
            $ttl = [string]$t[1]
            if ($act -eq 'KARANTIN') {
                try { $script:ToolsForm.Close() } catch {}
                Show-KiRoQuarantine
                return
            }
            if ($act -like 'GUI:*') {
                $real = $act.Substring(4)
                try { $script:ToolsForm.Close() } catch {}
                if ($real -eq 'Indicators') { Start-KiRoJob -Mode 'Indicators' }
                else { Start-KiRoJob -Mode 'Tool' -Action $real }
                return
            }
            Start-KiRoConsoleModule -Action $act -Title $ttl
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

# ================================================================ KARANTIN (v4.1)
# Umesto crnog konzolnog menija u kome se kuca K/D/W: prozor sa tabelom
# kandidata, kucicama i dugmadima. Posao ide u pozadinsku nit glavnog prozora,
# pa se vidi stvarni napredak, a na kraju se dobija izvestaj.
$script:QuarantineForm = $null
$script:QGrid          = $null
$script:QStatus        = $null
$script:QBtnDelete     = $null
$script:QCandidates    = @()
$script:QArmed         = $false
$script:QTimer         = $null

function Get-QuarantineSelected {
    $list = New-Object System.Collections.ArrayList
    $g = $script:QGrid
    if (-not $g) { return @() }
    foreach ($row in $g.Rows) {
        if ($row.IsNewRow) { continue }
        if ([bool]$row.Cells[0].Value -and $row.Tag) { [void]$list.Add($row.Tag) }
    }
    return @($list)
}

function Populate-QuarantineGrid {
    param([object[]]$Items)
    $g = $script:QGrid
    if (-not $g) { return }
    $g.Rows.Clear()
    foreach ($c in @($Items)) {
        $idx = $g.Rows.Add($false,[string]$c.Level,[string]$c.Name,[string]$c.Path,
                           [string]$c.Reasons,[string]$c.Signature)
        $g.Rows[$idx].Tag = $c
        $col = switch ([string]$c.Level) {
            'VISOK'   { $C.Danger }
            'SREDNJI' { $C.Warn }
            default   { $C.Muted }
        }
        $g.Rows[$idx].Cells[1].Style.ForeColor = Col $col
        $g.Rows[$idx].Cells[1].Style.Font = New-Object System.Drawing.Font('Segoe UI Semibold',9.5)
        $g.Rows[$idx].Cells[3].Style.ForeColor = Col $C.Muted
    }
    $n = @($Items).Count
    if ($script:QStatus) {
        if ($n -eq 0) {
            $script:QStatus.Text = 'Nema kandidata koji su presli prag sumnjivosti. Sistem izgleda cisto.'
            $script:QStatus.ForeColor = Col $C.Ok
        } else {
            $script:QStatus.Text = ("{0} kandidata. Oznaci kucicom, pa KARANTIN (moze da se vrati) ili OBRISI (trajno)." -f $n)
            $script:QStatus.ForeColor = Col $C.Text
        }
    }
}

function Disarm-Quarantine {
    $script:QArmed = $false
    if ($script:QTimer) { try { $script:QTimer.Stop() } catch {} }
    if ($script:QBtnDelete) {
        $script:QBtnDelete.Text = 'OBRISI'
        Set-FlatButton $script:QBtnDelete $C.Danger $C.HeadText '#B8352C' '#A32D2D' ''
    }
}

# Brisanje je trajno, pa trazi DRUGI klik na isto dugme (bez modala).
function Arm-Quarantine {
    $n = @(Get-QuarantineSelected).Count
    if ($n -eq 0) {
        if ($script:QStatus) {
            $script:QStatus.Text = 'Nisi oznacio nijednu stavku.'
            $script:QStatus.ForeColor = Col $C.Warn
        }
        return
    }
    $script:QArmed = $true
    if ($script:QBtnDelete) {
        $script:QBtnDelete.Text = 'POTVRDI BRISANJE'
        Set-FlatButton $script:QBtnDelete $C.Warn $C.HeadText '#A9660A' '#8A5608' ''
    }
    if ($script:QStatus) {
        $script:QStatus.Text = ('Brisanje je TRAJNO za ' + (KiRoStavke $n) + '. Klikni ponovo za potvrdu (ili sacekaj 12 s).')
        $script:QStatus.ForeColor = Col $C.Warn
    }
    if (-not $script:QTimer) {
        $script:QTimer = New-Object System.Windows.Forms.Timer
        $script:QTimer.Interval = 12000
        $script:QTimer.Add_Tick({ $script:QTimer.Stop(); Disarm-Quarantine })
    }
    $script:QTimer.Stop()
    $script:QTimer.Start()
}

function Start-QuarantineJob {
    param([ValidateSet('List','Quarantine','Delete','Whitelist')][string]$Action = 'List')
    if ($script:JobState) { return }
    Disarm-Quarantine
    $items = @()
    if ($Action -ne 'List') {
        $items = Get-QuarantineSelected
        if (@($items).Count -eq 0) {
            if ($script:QStatus) {
                $script:QStatus.Text = 'Nisi oznacio nijednu stavku.'
                $script:QStatus.ForeColor = Col $C.Warn
            }
            return
        }
    }
    $verb = switch ($Action) {
        'Quarantine' { 'Stavljam u karantin...' }
        'Delete'     { 'Brisem oznacene stavke...' }
        'Whitelist'  { 'Dozvoljavam oznacene stavke...' }
        default      { 'Trazim sumnjive fajlove i procese...' }
    }
    if ($script:QStatus) {
        $script:QStatus.Text = $verb
        $script:QStatus.ForeColor = Col $C.Accent
    }
    Start-KiRoJob -Mode 'Malware' -Payload $items -Action $Action
}

function Show-KiRoQuarantine {
    try {
        if ($script:QuarantineForm -and -not $script:QuarantineForm.IsDisposed) {
            $script:QuarantineForm.Activate()
            return
        }
    } catch {}

    $qf = New-Object System.Windows.Forms.Form
    $qf.Text = 'KiRo - KARANTIN'
    $qf.ClientSize = New-Object System.Drawing.Size(980,540)
    $qf.StartPosition = 'CenterParent'
    $qf.MinimumSize = New-Object System.Drawing.Size(780,420)
    $qf.ShowIcon = $false
    $qf.BackColor = Col $C.Bg
    $qf.Font = Fo 'Segoe UI' 9.5

    # Raspored: Fill prvi, pa gornja i donja traka - tako se nista ne preklapa
    # (u WinForms se rasporedjuje od NAJVECEG indeksa ka nuli).
    $qGridCard = New-Object System.Windows.Forms.Panel
    $qGridCard.Dock = 'Fill'
    $qGridCard.BackColor = Col $C.Border
    $qGridCard.Padding = New-Object System.Windows.Forms.Padding(1)
    $qGridCard.Margin = New-Object System.Windows.Forms.Padding(16,0,16,10)
    $qf.Controls.Add($qGridCard)

    $qGrid = New-Object System.Windows.Forms.DataGridView
    $qGrid.Dock = 'Fill'
    $qGrid.AllowUserToAddRows = $false
    $qGrid.AllowUserToDeleteRows = $false
    $qGrid.AllowUserToResizeRows = $false
    $qGrid.ReadOnly = $false
    $qGrid.MultiSelect = $false
    $qGrid.SelectionMode = 'FullRowSelect'
    $qGrid.RowHeadersVisible = $false
    $qGrid.BorderStyle = 'None'
    $qGrid.BackgroundColor = Col $C.Card
    $qGrid.GridColor = Col $C.Border
    $qGrid.CellBorderStyle = 'SingleHorizontal'
    $qGrid.EnableHeadersVisualStyles = $false
    $qGrid.ColumnHeadersBorderStyle = 'Single'
    $qGrid.ColumnHeadersHeightSizeMode = 'DisableResizing'
    $qGrid.ColumnHeadersHeight = 32
    $qGrid.ColumnHeadersDefaultCellStyle.BackColor = Col $C.GridHead
    $qGrid.ColumnHeadersDefaultCellStyle.ForeColor = Col $C.Head
    $qGrid.ColumnHeadersDefaultCellStyle.Font = Fo 'Segoe UI Semibold' 9.5
    $qGrid.DefaultCellStyle.BackColor = Col $C.Card
    $qGrid.DefaultCellStyle.ForeColor = Col $C.Text
    $qGrid.DefaultCellStyle.SelectionBackColor = Col $C.Sel
    $qGrid.DefaultCellStyle.SelectionForeColor = Col $C.Text
    $qGrid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(4,2,4,2)
    $qGrid.AlternatingRowsDefaultCellStyle.BackColor = Col $C.RowAlt
    $qGrid.AlternatingRowsDefaultCellStyle.SelectionBackColor = Col $C.Sel
    $qGrid.RowTemplate.Height = 30
    $qGridCard.Controls.Add($qGrid)

    $c1 = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $c1.HeaderText = [char]0x2713
    $c1.Width = 42
    $c1.SortMode = 'NotSortable'
    [void]$qGrid.Columns.Add($c1)
    $c2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c2.HeaderText = 'Rizik'
    $c2.Width = 84
    $c2.ReadOnly = $true
    $c2.SortMode = 'NotSortable'
    [void]$qGrid.Columns.Add($c2)
    $c3 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c3.HeaderText = 'Naziv'
    $c3.Width = 150
    $c3.ReadOnly = $true
    $c3.SortMode = 'NotSortable'
    [void]$qGrid.Columns.Add($c3)
    $c4 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c4.HeaderText = 'Putanja'
    $c4.AutoSizeMode = 'Fill'
    $c4.ReadOnly = $true
    $c4.SortMode = 'NotSortable'
    [void]$qGrid.Columns.Add($c4)
    $c5 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c5.HeaderText = 'Zasto je sumnjivo'
    $c5.Width = 250
    $c5.ReadOnly = $true
    $c5.SortMode = 'NotSortable'
    [void]$qGrid.Columns.Add($c5)
    $c6 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c6.HeaderText = 'Potpis'
    $c6.Width = 120
    $c6.ReadOnly = $true
    $c6.SortMode = 'NotSortable'
    [void]$qGrid.Columns.Add($c6)

    $qHead = New-Object System.Windows.Forms.Label
    $qHead.Dock = 'Top'
    $qHead.Height = 56
    $qHead.TextAlign = 'MiddleLeft'
    $qHead.Padding = New-Object System.Windows.Forms.Padding(16,0,10,0)
    $qHead.Text = 'KARANTIN  -  sumnjivi fajlovi i procesi'
    $qHead.BackColor = Col $C.Head
    $qHead.ForeColor = Col $C.HeadText
    $qHead.Font = Fo 'Segoe UI Semibold' 11
    $qf.Controls.Add($qHead)

    $qFoot = New-Object System.Windows.Forms.Panel
    $qFoot.Dock = 'Bottom'
    $qFoot.Height = 96
    $qFoot.Padding = New-Object System.Windows.Forms.Padding(16,8,16,16)
    $qFoot.BackColor = Col $C.Card
    $qf.Controls.Add($qFoot)

    $qStatus = New-Object System.Windows.Forms.Label
    $qStatus.Dock = 'Top'
    $qStatus.Height = 26
    $qStatus.TextAlign = 'MiddleLeft'
    $qStatus.AutoEllipsis = $true
    $qStatus.Text = 'Ucitavam kandidate...'
    $qStatus.ForeColor = Col $C.Muted
    $qStatus.Font = Fo 'Segoe UI Semibold' 9.5
    $qFoot.Controls.Add($qStatus)

    $qBtnBar = New-Object System.Windows.Forms.Panel
    $qBtnBar.Dock = 'Fill'
    $qBtnBar.BackColor = Col $C.Card
    $qFoot.Controls.Add($qBtnBar)

    # Dugmad se dodaju redom: poslednje dodato je najblize desnoj ivici.
    $qBtnQuarantine = New-Object System.Windows.Forms.Button
    $qBtnQuarantine.Text = 'KARANTIN'
    $qBtnQuarantine.Dock = 'Right'
    $qBtnQuarantine.Width = 168
    $qBtnQuarantine.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $qBtnQuarantine $C.Ok $C.HeadText '#27875A' '#1F6E49' ''
    $qBtnBar.Controls.Add($qBtnQuarantine)

    $qBtnDelete = New-Object System.Windows.Forms.Button
    $qBtnDelete.Text = 'OBRISI'
    $qBtnDelete.Dock = 'Right'
    $qBtnDelete.Width = 168
    $qBtnDelete.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $qBtnDelete $C.Danger $C.HeadText '#B8352C' '#A32D2D' ''
    $qBtnBar.Controls.Add($qBtnDelete)

    $qBtnAllow = New-Object System.Windows.Forms.Button
    $qBtnAllow.Text = 'DOZVOLI'
    $qBtnAllow.Dock = 'Right'
    $qBtnAllow.Width = 130
    $qBtnAllow.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $qBtnAllow $C.BtnLight $C.Head $C.BtnLightH '#DCE8F8' $C.Border
    $qBtnBar.Controls.Add($qBtnAllow)

    $qBtnRefresh = New-Object System.Windows.Forms.Button
    $qBtnRefresh.Text = 'OSVEZI'
    $qBtnRefresh.Dock = 'Right'
    $qBtnRefresh.Width = 120
    $qBtnRefresh.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $qBtnRefresh $C.BtnLight $C.Head $C.BtnLightH '#DCE8F8' $C.Border
    $qBtnBar.Controls.Add($qBtnRefresh)

    $qBtnClose = New-Object System.Windows.Forms.Button
    $qBtnClose.Text = 'ZATVORI'
    $qBtnClose.Dock = 'Right'
    $qBtnClose.Width = 120
    $qBtnClose.Font = Fo 'Segoe UI Semibold' 9.5
    Set-FlatButton $qBtnClose $C.BtnLight $C.Head $C.BtnLightH '#DCE8F8' $C.Border
    $qBtnBar.Controls.Add($qBtnClose)

    $qTip = New-Object System.Windows.Forms.ToolTip
    $qTip.InitialDelay = 300
    $qTip.ReshowDelay  = 80
    $qTip.AutoPopDelay = 30000
    $qTip.ShowAlways   = $true
    try { $qTip.SetToolTip($qBtnQuarantine,'Premesta oznacene fajlove u Documents\KiRo_PC_Diagnostic_Logs\Quarantine. Ne brise ih - UNDO moze da ih vrati.') } catch {}
    try { $qTip.SetToolTip($qBtnDelete,'TRAJNO brise oznacene fajlove. Trazi drugi klik za potvrdu. Ako nisi siguran, koristi KARANTIN.') } catch {}
    try { $qTip.SetToolTip($qBtnAllow,'Dodaje oznacene fajlove na listu dozvoljenih - vise se ne prikazuju kao sumnjivi.') } catch {}
    try { $qTip.SetToolTip($qBtnRefresh,'Ponovo trazi sumnjive fajlove i procese.') } catch {}

    $script:QGrid      = $qGrid
    $script:QStatus    = $qStatus
    $script:QBtnDelete = $qBtnDelete

    $qBtnQuarantine.Add_Click({ Start-QuarantineJob 'Quarantine' })
    $qBtnDelete.Add_Click({
        if ($script:QArmed) { Disarm-Quarantine; Start-QuarantineJob 'Delete' }
        else { Arm-Quarantine }
    })
    $qBtnAllow.Add_Click({ Start-QuarantineJob 'Whitelist' })
    $qBtnRefresh.Add_Click({ Start-QuarantineJob 'List' })
    $qBtnClose.Add_Click({ try { $script:QuarantineForm.Close() } catch {} })

    $qGrid.Add_CellDoubleClick({
        param($s,$e)
        if ($e.RowIndex -lt 0) { return }
        $row = $qGrid.Rows[$e.RowIndex]
        if (-not $row.Tag) { return }
        $c = $row.Tag
        $t = 'Naziv: ' + [string]$c.Name + [Environment]::NewLine +
             'Putanja: ' + [string]$c.Path + [Environment]::NewLine +
             'Rizik: ' + [string]$c.Level + '   (ocena ' + [string]$c.Score + ')' + [Environment]::NewLine +
             'Izvor: ' + [string]$c.Source + '   Potpis: ' + [string]$c.Signature + [Environment]::NewLine +
             'Velicina: ' + [string]$c.SizeKB + ' KB' + [Environment]::NewLine + [Environment]::NewLine +
             'Zasto je sumnjivo: ' + [string]$c.Reasons
        Show-KiRoDetails $t ('Kandidat - ' + [string]$c.Name)
    })

    $qf.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { try { $script:QuarantineForm.Close() } catch {} } })
    $qf.Add_FormClosed({
        try { $qTip.Dispose() } catch {}
        $script:QuarantineForm = $null
        $script:QGrid          = $null
        $script:QStatus        = $null
        $script:QBtnDelete     = $null
    })

    $qf.Controls.SetChildIndex($qGridCard,0)
    $qf.Controls.SetChildIndex($qHead,1)
    $qf.Controls.SetChildIndex($qFoot,2)

    $script:QuarantineForm = $qf
    $qf.Add_Shown({ Start-QuarantineJob 'List' })
    $qf.Show($form)
}

# ================================================================ PONUDA ALATA (v4.1)
# Kada oznacena stavka ne moze automatski, GUI nudi tacan alat u istoj traci.
$script:ToolOffers  = @()
$script:OffersTimer = $null

function Hide-KiRoToolOffers {
    $script:ToolOffers = @()
    if ($script:OffersTimer) { try { $script:OffersTimer.Stop() } catch {} }
    if ($toolWrap) { $toolWrap.Visible = $false }
}

function Get-KiRoToolOffers {
    param([object[]]$Findings)
    $offers = New-Object System.Collections.ArrayList
    $hasMal = $false
    $hasWin = $false
    $hasDef = $false
    $hasSec = $false
    foreach ($f in @($Findings)) {
        $cat = [string]$f.Category
        $txt = ([string]$f.Problem + ' ' + [string]$f.Recommendation).ToLowerInvariant()
        if (($script:KiRoMalwareCategories -contains $cat) -or ($txt -match 'malware|virus|telegram|trojan')) { $hasMal = $true }
        if (($cat -match 'Windows|Sistem') -or ($txt -match 'dism|sfc|sistemski fajl|component store')) { $hasWin = $true }
        if (($cat -match 'Zastita|Defender') -or ($txt -match 'defender|antivirus|zastit')) { $hasDef = $true }
        if ($txt -match 'security|event log') { $hasSec = $true }
    }
    if ($hasMal) { [void]$offers.Add(@('OTVORI KARANTIN','Q:KARANTIN')) }
    if ($hasWin) { [void]$offers.Add(@('POKRENI DISM / SFC','T:WindowsRepair')) }
    if ($hasDef) { [void]$offers.Add(@('POPRAVI DEFENDER','T:DefenderFix')) }
    if ($hasSec) { [void]$offers.Add(@('OCISTI SECURITY LOG','T:EventLogSecurity')) }
    if ($offers.Count -eq 0) {
        [void]$offers.Add(@('OTVORI KARANTIN','Q:KARANTIN'))
        [void]$offers.Add(@('POKRENI DISM / SFC','T:WindowsRepair'))
        [void]$offers.Add(@('POPRAVI DEFENDER','T:DefenderFix'))
    }
    return @($offers)
}

function Show-KiRoToolOffers {
    param([object[]]$Findings,[string]$Message)
    Hide-KiRoToolOffers
    $offers = Get-KiRoToolOffers -Findings $Findings
    if (@($offers).Count -eq 0) { return }

    # prvo ocistimo dugmad od prethodne ponude (labela ostaje)
    foreach ($c in @($toolWrap.Controls)) {
        if ($c -ne $toolLabel) { $toolWrap.Controls.Remove($c) }
    }

    foreach ($o in @($offers)) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = [string]$o[0]
        $b.Dock = 'Right'
        $b.Width = 182
        $b.Margin = New-Object System.Windows.Forms.Padding(8,0,0,0)
        $b.Font = Fo 'Segoe UI Semibold' 9.5
        Set-FlatButton $b $C.Accent $C.HeadText $C.AccentDk $C.AccentDk ''
        $b.Tag = [string]$o[1]
        $b.Add_Click({ Invoke-KiRoToolOffer ([string]$this.Tag) })
        $toolWrap.Controls.Add($b)
    }
    $toolWrap.Controls.SetChildIndex($toolLabel,0)

    $toolLabel.Text = $Message
    $toolLabel.ForeColor = Col $C.Warn
    $summaryLabel.Visible = $false
    $toolWrap.Visible = $true

    if (-not $script:OffersTimer) {
        $script:OffersTimer = New-Object System.Windows.Forms.Timer
        $script:OffersTimer.Interval = 45000
        $script:OffersTimer.Add_Tick({
            $script:OffersTimer.Stop()
            Hide-KiRoToolOffers
            if (-not $script:JobState) { $summaryLabel.Visible = $true }
        })
    }
    $script:OffersTimer.Stop()
    $script:OffersTimer.Start()
}

function Invoke-KiRoToolOffer {
    param([string]$Tag)
    Hide-KiRoToolOffers
    if (-not $script:JobState) { $summaryLabel.Visible = $true }
    if ($Tag -like 'Q:*') {
        Show-KiRoQuarantine
        return
    }
    if ($Tag -like 'T:*') {
        Start-KiRoJob -Mode 'Tool' -Action ($Tag.Substring(2))
    }
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
Set-Tip $btnRepair 'Popravlja SAMO stavke sa kucicom. Prvo pita DA/NE, pa pravi Safety Snapshot i radi u pozadini. Pokvareni unosi se prebacuju u backup, ne brise se trajno. Ako oznacena stavka ne moze automatski, u traci se odmah nudi odgovarajuci alat.'
Set-Tip $btnTools 'Dodatni moduli: MALWARE/TELEGRAM otvara prozor KARANTIN, dubinska provera ide u tabelu, Windows popravka i Defender popravka rade u pozadini. Tu su i SNAPSHOT, UNDO i LOGOVI.'
Set-Tip $btnPlugins 'Pluginovi: dodatni modulski skenovi iz foldera Plugins/. Otvara prozor sa ucitanim pluginima i dugme za pokretanje svih plugin skenova.'
Set-Tip $btnConfirmYes 'Potvrdjuje popravku oznacenih stavki. Prvo se pravi Safety Snapshot, pa popravka ide u pozadini - traka pokazuje napredak stavku po stavku.'
Set-Tip $btnConfirmNo 'Otkazuje popravku. Nista se ne menja i nista se ne brise.'

function Show-KiRoPluginsForm {
    if ($script:Plugins.Count -eq 0) {
        Set-KiRoResult 'Nema ucitanih plugina. Dodaj .ps1 fajl u folder Plugins/.' 'Info'
        return
    }
    $pf = New-Object System.Windows.Forms.Form
    $pf.Text = 'KiRo v4.2 - Pluginovi'
    $pf.Size = New-Object System.Drawing.Size(660,440)
    $pf.MinimumSize = New-Object System.Drawing.Size(520,320)
    $pf.StartPosition = 'CenterParent'
    $pf.BackColor = Col $C.Bg
    $pf.Font = Fo 'Segoe UI' 9.5
    $pf.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    $head = New-Object System.Windows.Forms.Label
    $head.Dock = 'Top'
    $head.Height = 46
    $head.Padding = New-Object System.Windows.Forms.Padding(14,10,14,4)
    $head.Text = ('Ucitano plugina: ' + $script:Plugins.Count + '.  Svaki je modul u folderu Plugins/ koji moze da doda nalaze u glavnu tabelu.')
    $head.ForeColor = Col $C.Muted
    $pf.Controls.Add($head)

    $pg = New-Object System.Windows.Forms.DataGridView
    $pg.Dock = 'Fill'
    $pg.ReadOnly = $true
    $pg.AllowUserToAddRows = $false
    $pg.AllowUserToDeleteRows = $false
    $pg.AutoSizeColumnsMode = 'Fill'
    $pg.BackgroundColor = Col $C.Card
    $pg.BorderStyle = 'FixedSingle'
    $pg.ColumnHeadersDefaultCellStyle.BackColor = Col $C.GridHead
    $null = $pg.Columns.Add('cName','Naziv')
    $null = $pg.Columns.Add('cAuth','Autor')
    $null = $pg.Columns.Add('cDesc','Opis')
    $null = $pg.Columns.Add('cRep','Popravka')
    foreach ($p in @($script:Plugins)) {
        [void]$pg.Rows.Add($p.Name, $p.Author, $p.Description, (if ($p.HasRepair) { 'DA' } else { 'NE' }))
    }

    $btnRun = New-TopButton 'POKRENI SVE PLUGINE' 190 $C.Accent $C.HeadText $C.AccentDk $C.AccentDk ''
    $btnRun.Dock = 'Bottom'
    $btnRun.Margin = New-Object System.Windows.Forms.Padding(0)
    $btnRun.Add_Click({
        try {
            $n = Invoke-KiRoPluginScans
            Populate-KiRoGrid
            Set-KiRoResult ('' + $n + ' plugin sken(a) pokrenuto. Nalazi su dodati u glavnu tabelu.') 'Ok'
            try { $pf.Close() } catch {}
        } catch {
            Set-KiRoResult ('Greska u plugin skeniranju: ' + $_.Exception.Message) 'Error'
        }
    })

    $pf.Controls.Add($btnRun)
    $pf.Controls.Add($pg)

    $script:PluginsForm = $pf
    $pf.ShowDialog($form) | Out-Null
}

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
$btnPlugins.Add_Click({ Show-KiRoPluginsForm })

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
