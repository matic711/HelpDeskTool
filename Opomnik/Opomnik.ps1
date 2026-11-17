<#
.SYNOPSIS
    Opomnik - preprost opomnik za dnevna opravila.
.DESCRIPTION
    Vpišeš opravila in uro. Ob tisti uri se prikaže VELIKO rdeče okno z opomnikom
    (privzeto spodaj desno), ki je vedno na vrhu, utripa in se ne zapre samo od sebe -
    klikniti moraš "OPRAVLJENO" ali ga odložiti (5 min / 15 min / 1 uro).

    Ne prekrije celega zaslona in ne vzame fokusa: če tipkaš ali si na klicu,
    lahko normalno nadaljuješ. Okno lahko z miško povlečeš drugam.

    Program teče v ozadju, ikona je v sistemski vrstici (spodaj desno ob uri).
    Podatki se shranjujejo v %APPDATA%\Opomnik\opomnik.json
.NOTES
    Zagon: dvoklik na Opomnik.bat
    ali:   powershell -ExecutionPolicy Bypass -File .\Opomnik.ps1
    -Tray  zažene program skrito v sistemski vrstici (uporablja samodejni zagon ob prijavi)
#>
param([switch]$Tray)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Samo en primerek programa naenkrat. Če že teče, mu sporočimo, naj pokaže
# svoje okno, in končamo (da ne bi dobil vsakega opomnika dvakrat).
# ---------------------------------------------------------------------------
$createdNew = $false
$script:Mutex     = [System.Threading.Mutex]::new($true, 'Local\Opomnik_TaskReminder_Mutex', [ref]$createdNew)
$script:ShowEvent = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, 'Local\Opomnik_TaskReminder_Show')
if (-not $createdNew) {
    [void]$script:ShowEvent.Set()
    exit
}

[System.Windows.Forms.Application]::EnableVisualStyles()
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
} catch { }

# ---------------------------------------------------------------------------
# Nastavitve in stanje
# ---------------------------------------------------------------------------
$script:ScriptPath = $PSCommandPath
$script:DataDir    = Join-Path $env:APPDATA 'Opomnik'
$script:DataFile   = Join-Path $script:DataDir 'opomnik.json'
$script:LogFile    = Join-Path $script:DataDir 'napake.log'
$script:StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Opomnik.lnk'
$script:DateFmt    = 'yyyy-MM-dd HH:mm'
$script:Inv        = [System.Globalization.CultureInfo]::InvariantCulture

# kje na zaslonu se pokaže opomnik
$script:PositionNames = [ordered]@{
    BottomRight = 'spodaj desno'
    TopRight    = 'zgoraj desno'
    TopCenter   = 'zgoraj na sredini'
    Center      = 'na sredini zaslona'
}

$script:Tasks    = New-Object System.Collections.ArrayList
$script:Settings = [pscustomobject]@{ Sound = $true; Position = 'BottomRight' }

$script:AlertForm       = $null
$script:AlertTask       = $null
$script:AlertIsTest     = $false
$script:AlertAllowClose = $false
$script:AlertShownAt    = [datetime]::MinValue
$script:AlertTicks      = 0
$script:Player          = $null
$script:LastSound       = [datetime]::MinValue
$script:DragOffset      = $null
$script:ReallyExit      = $false
$script:TrayHintShown   = $false
$script:LastDay         = (Get-Date).Date

$script:ColorA = [System.Drawing.Color]::FromArgb(183, 28, 28)
$script:ColorB = [System.Drawing.Color]::FromArgb(211, 47, 47)
$script:Pink   = [System.Drawing.Color]::FromArgb(255, 205, 210)

# ---------------------------------------------------------------------------
# Pomožne funkcije
# ---------------------------------------------------------------------------
function Write-ErrorLog([string]$Message) {
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        Add-Content -Path $script:LogFile -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    } catch { }
}

function ConvertTo-Date([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    return [datetime]::ParseExact($Text, $script:DateFmt, $script:Inv)
}

function ConvertFrom-Date([datetime]$Date) {
    return $Date.ToString($script:DateFmt, $script:Inv)
}

# PowerShell 7 lahko datume v JSON-u že sam pretvori v [datetime] - sprejmemo oboje.
function Read-DateValue($Value) {
    if ($Value -is [datetime]) { return $Value }
    return ConvertTo-Date ([string]$Value)
}

function Format-Day([datetime]$Date) {
    $diff = ($Date.Date - (Get-Date).Date).Days
    if ($diff -eq 0)  { return 'danes' }
    if ($diff -eq 1)  { return 'jutri' }
    if ($diff -eq -1) { return 'včeraj' }
    return $Date.ToString('d. M. yyyy')
}

function Format-When([datetime]$Date) {
    return (Format-Day $Date) + ' ' + $Date.ToString('HH:mm')
}

function Format-Duration([int]$Minutes) {
    if ($Minutes -lt 60) { return "$Minutes min" }
    if ($Minutes -lt 1440) {
        $h = [Math]::Floor($Minutes / 60)
        $m = $Minutes % 60
        if ($m -eq 0) { return "$h h" }
        return "$h h $m min"
    }
    return "$([Math]::Floor($Minutes / 1440)) d"
}

# Kdaj naj se opomnik prikaže (če je bil odložen, šteje čas odloga).
function Get-AlertTime($Task) {
    if ($Task.SnoozeUntil) { return ConvertTo-Date $Task.SnoozeUntil }
    return ConvertTo-Date $Task.Due
}

function Get-NextDueTask {
    $now = Get-Date
    return $script:Tasks |
        Where-Object { -not $_.Done -and (Get-AlertTime $_) -le $now } |
        Sort-Object { Get-AlertTime $_ } |
        Select-Object -First 1
}

function Get-SelectedIds {
    return @($script:ListView.SelectedItems | ForEach-Object { [string]$_.Tag })
}

# ---------------------------------------------------------------------------
# Shranjevanje / nalaganje (JSON v %APPDATA%\Opomnik)
# ---------------------------------------------------------------------------
function Load-Data {
    $script:Tasks.Clear()
    if (-not (Test-Path $script:DataFile)) { return }
    try {
        $raw = [System.IO.File]::ReadAllText($script:DataFile)
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $data = $raw | ConvertFrom-Json
        if ($null -ne $data.Settings) {
            if ($null -ne $data.Settings.Sound) { $script:Settings.Sound = [bool]$data.Settings.Sound }
            $pos = [string]$data.Settings.Position
            if ($pos -and $script:PositionNames.Contains($pos)) { $script:Settings.Position = $pos }
        }
        # opravljena opravila, starejša od 7 dni, pospravimo
        $cutoff = (Get-Date).Date.AddDays(-7)
        foreach ($t in @($data.Tasks)) {
            try {
                if ($null -eq $t) { continue }
                $due = Read-DateValue $t.Due
                if ($null -eq $due) { continue }
                if ([bool]$t.Done -and $due -lt $cutoff) { continue }
                $snooze = ''
                if ($t.SnoozeUntil) { $snooze = ConvertFrom-Date (Read-DateValue $t.SnoozeUntil) }
                $id = [string]$t.Id
                if (-not $id) { $id = [guid]::NewGuid().ToString() }
                [void]$script:Tasks.Add([pscustomobject]@{
                    Id          = $id
                    Due         = (ConvertFrom-Date $due)
                    Text        = [string]$t.Text
                    Done        = [bool]$t.Done
                    SnoozeUntil = $snooze
                })
            } catch {
                Write-ErrorLog "Neveljavno opravilo v datoteki preskočeno: $_"
            }
        }
    } catch {
        Write-ErrorLog "Datoteke ni bilo mogoče prebrati: $_"
        Copy-Item -Path $script:DataFile -Destination "$($script:DataFile).pokvarjen" -Force -ErrorAction SilentlyContinue
    }
}

function Save-Data {
    try {
        if (-not (Test-Path $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }
        # JSON sestavimo ročno po kosih - tako se izognemo čudnostim
        # ConvertTo-Json pri tabelah v Windows PowerShell 5.1.
        $settingsJson = ConvertTo-Json -InputObject $script:Settings -Compress
        $taskJson = @($script:Tasks | ForEach-Object {
            ConvertTo-Json -InputObject ([pscustomobject]@{
                Id          = [string]$_.Id
                Due         = [string]$_.Due
                Text        = [string]$_.Text
                Done        = [bool]$_.Done
                SnoozeUntil = [string]$_.SnoozeUntil
            }) -Compress
        })
        $json = '{"Settings":' + $settingsJson + ',"Tasks":[' + ($taskJson -join ',') + ']}'
        [System.IO.File]::WriteAllText($script:DataFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-ErrorLog "Shranjevanje ni uspelo: $_"
    }
}

# ---------------------------------------------------------------------------
# Samodejni zagon ob prijavi v Windows (bližnjica v mapi Startup)
# ---------------------------------------------------------------------------
function Set-Autostart([bool]$Enable) {
    if ($Enable) {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($script:StartupLnk)
        $lnk.TargetPath       = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($script:ScriptPath)`" -Tray"
        $lnk.WorkingDirectory = Split-Path -Parent $script:ScriptPath
        $lnk.WindowStyle      = 7   # minimizirano
        $lnk.Description      = 'Opomnik za opravila'
        $lnk.Save()
    } elseif (Test-Path $script:StartupLnk) {
        Remove-Item -Path $script:StartupLnk -Force
    }
}

# ---------------------------------------------------------------------------
# Ikona (rdeč krog s klicajem)
# ---------------------------------------------------------------------------
function New-AppIcon {
    try {
        $bmp = New-Object System.Drawing.Bitmap(32, 32)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.TextRenderingHint = 'AntiAliasGridFit'
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush($script:ColorB)
        $g.FillEllipse($brush, 1, 1, 30, 30)
        $font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
        $sf = New-Object System.Drawing.StringFormat
        $sf.Alignment = 'Center'
        $sf.LineAlignment = 'Center'
        $g.DrawString('!', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF(0, 0, 32, 32)), $sf)
        $g.Dispose()
        $brush.Dispose()
        $font.Dispose()
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } catch {
        return [System.Drawing.SystemIcons]::Information
    }
}

# ---------------------------------------------------------------------------
# OKNO Z OPOMNIKOM
# Posebna vrsta okna, ki je vedno na vrhu, a se pokaže BREZ kraje fokusa -
# tipkanje gre naprej v program, v katerem delaš.
# Če tega ni mogoče pripraviti, se uporabi navadno okno (ki ob prikazu vzame fokus).
# ---------------------------------------------------------------------------
$script:NoActivate = $false
try {
    if (-not ('OpomnikPopupForm' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class OpomnikPopupForm : Form
{
    // show the window without stealing keyboard focus
    protected override bool ShowWithoutActivation { get { return true; } }

    protected override CreateParams CreateParams
    {
        get
        {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000;     // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080;     // WS_EX_TOOLWINDOW (not in Alt+Tab)
            cp.ExStyle |= 0x00000008;     // WS_EX_TOPMOST
            cp.ClassStyle |= 0x00020000;  // CS_DROPSHADOW
            return cp;
        }
    }

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    // bring back on top (HWND_TOPMOST) without activating
    public void KeepOnTop()
    {
        if (IsHandleCreated)
            SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0040);
    }
}
'@
    }
    $script:NoActivate = $true
} catch {
    Write-ErrorLog "Posebnega okna ni bilo mogoče pripraviti, uporabim navadno: $_"
}

# Okno lahko z miško povlečeš kamorkoli.
$script:DragDown = {
    param($s, $e)
    if ($e.Button -eq 'Left') {
        $frm = $s.FindForm()
        $p = [System.Windows.Forms.Cursor]::Position
        $script:DragOffset = New-Object System.Drawing.Point(($p.X - $frm.Left), ($p.Y - $frm.Top))
    }
}
$script:DragMove = {
    param($s, $e)
    if ($null -ne $script:DragOffset -and $e.Button -eq 'Left') {
        $frm = $s.FindForm()
        $p = [System.Windows.Forms.Cursor]::Position
        $frm.Location = New-Object System.Drawing.Point(($p.X - $script:DragOffset.X), ($p.Y - $script:DragOffset.Y))
    }
}
$script:DragUp = { $script:DragOffset = $null }

function Add-DragHandlers($Control) {
    $Control.Add_MouseDown($script:DragDown)
    $Control.Add_MouseMove($script:DragMove)
    $Control.Add_MouseUp($script:DragUp)
}

# Največja pisava, pri kateri se besedilo še prilega v okvir.
function Get-FittingFont([string]$Text, [int]$MaxWidth, [int]$MaxHeight, [int]$StartSize, [int]$MinSize) {
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak
    $size = $StartSize
    while ($size -gt $MinSize) {
        $font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold)
        $measured = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $font, (New-Object System.Drawing.Size($MaxWidth, 0)), $flags)
        if ($measured.Height -le $MaxHeight -and $measured.Width -le $MaxWidth) { return $font }
        $font.Dispose()
        $size -= 2
    }
    return New-Object System.Drawing.Font('Segoe UI', $MinSize, [System.Drawing.FontStyle]::Bold)
}

function New-AlertLabel([string]$Text, $Font, $Color) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text        = $Text
    $lbl.Font        = $Font
    $lbl.ForeColor   = $Color
    $lbl.BackColor   = [System.Drawing.Color]::Transparent
    $lbl.TextAlign   = 'MiddleLeft'
    $lbl.AutoSize    = $false
    $lbl.UseMnemonic = $false
    Add-DragHandlers $lbl
    return $lbl
}

function New-AlertButton([string]$Text, $Font, $BackColor, $ForeColor) {
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = $Text
    $btn.Font      = $Font
    $btn.BackColor = $BackColor
    $btn.ForeColor = $ForeColor
    $btn.FlatStyle = 'Flat'
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $btn.Enabled   = $false   # vklopi se po 1 s (da ga ne potrdiš po nesreči)
    return $btn
}

function New-AlertForm([string]$TaskText, [string]$Head) {
    $W = 590
    $H = 300
    $white = [System.Drawing.Color]::White

    if ($script:NoActivate) {
        # "vedno na vrhu" je že vgrajeno v OpomnikPopupForm (TopMost tu ne sme biti
        # nastavljen, ker bi okno ob prikazu vzelo fokus)
        $f = New-Object OpomnikPopupForm
    } else {
        $f = New-Object System.Windows.Forms.Form
        $f.TopMost = $true
    }
    $f.Text            = 'Opomnik'
    $f.FormBorderStyle = 'None'
    $f.StartPosition   = 'Manual'
    $f.ShowInTaskbar   = $false
    $f.ClientSize      = New-Object System.Drawing.Size($W, $H)
    $f.BackColor       = $script:ColorA
    $f.Icon            = $script:AppIcon
    $f.Cursor          = [System.Windows.Forms.Cursors]::SizeAll
    Add-DragHandlers $f

    # Alt+F4 ne deluje - zapre se samo z gumbom
    $f.Add_FormClosing({
        param($s, $e)
        if (-not $script:AlertAllowClose -and $e.CloseReason -ne 'WindowsShutDown') { $e.Cancel = $true }
    })

    # svetel rob okoli okna
    $f.Add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen($script:Pink, 4)
        $e.Graphics.DrawRectangle($pen, 2, 2, $s.ClientSize.Width - 4, $s.ClientSize.Height - 4)
        $pen.Dispose()
    })

    # zgornja vrstica: OPOMNIK · danes 14:30 · zamuda ...
    $lbl = New-AlertLabel $Head (New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)) $script:Pink
    $lbl.SetBounds(20, 14, $W - 40, 26)
    $f.Controls.Add($lbl)

    # besedilo opravila - čim večje
    $font = Get-FittingFont -Text $TaskText -MaxWidth ($W - 50) -MaxHeight 134 -StartSize 30 -MinSize 12
    $lbl = New-AlertLabel $TaskText $font $white
    $lbl.SetBounds(20, 44, $W - 40, 140)
    $f.Controls.Add($lbl)

    # gumb OPRAVLJENO
    $btn = New-AlertButton 'OPRAVLJENO' (New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)) $white $script:ColorA
    $btn.FlatAppearance.BorderSize = 0
    $btn.SetBounds(20, 198, 250, 82)
    $btn.Add_Click({ Close-Alert 'done' })
    $f.Controls.Add($btn)

    # gumbi za odlog
    $lbl = New-AlertLabel 'Odloži za:' (New-Object System.Drawing.Font('Segoe UI', 9)) $script:Pink
    $lbl.SetBounds(290, 196, 280, 22)
    $f.Controls.Add($lbl)

    $x = 290
    foreach ($opt in @(@(5, '5 min'), @(15, '15 min'), @(60, '1 uro'))) {
        $btn = New-AlertButton $opt[1] (New-Object System.Drawing.Font('Segoe UI', 12)) ([System.Drawing.Color]::FromArgb(127, 0, 0)) $white
        $btn.Tag = $opt[0]
        $btn.FlatAppearance.BorderColor = $script:Pink
        $btn.FlatAppearance.BorderSize  = 2
        $btn.SetBounds($x, 220, 88, 60)
        $btn.Add_Click({ param($s, $e) Close-Alert 'snooze' ([int]$s.Tag) })
        $f.Controls.Add($btn)
        $x += 96
    }

    return $f
}

function Set-AlertPosition($Form) {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $m = 16
    $w = $Form.Width
    $h = $Form.Height
    switch ($script:Settings.Position) {
        'TopRight'  { $x = $wa.Right - $w - $m;                     $y = $wa.Top + $m }
        'TopCenter' { $x = $wa.Left + [int](($wa.Width - $w) / 2); $y = $wa.Top + $m }
        'Center'    { $x = $wa.Left + [int](($wa.Width - $w) / 2); $y = $wa.Top + [int](($wa.Height - $h) / 2) }
        default     { $x = $wa.Right - $w - $m;                     $y = $wa.Bottom - $h - $m }
    }
    $Form.Location = New-Object System.Drawing.Point($x, $y)
}

# Kratek zvonec (ne dolg alarm - da ne moti, če si na klicu).
function Play-AlertSound {
    $script:LastSound = Get-Date
    if (-not $script:Settings.Sound) { return }
    try {
        if ($null -eq $script:Player) {
            foreach ($name in @('Windows Notify Calendar.wav', 'Windows Notify System Generic.wav', 'Alarm01.wav')) {
                $wav = Join-Path $env:WINDIR "Media\$name"
                if (Test-Path $wav) { $script:Player = New-Object System.Media.SoundPlayer($wav); break }
            }
        }
        if ($null -ne $script:Player) { $script:Player.Play() } else { [System.Media.SystemSounds]::Exclamation.Play() }
    } catch { }
}

function Stop-AlertSound {
    try { if ($null -ne $script:Player) { $script:Player.Stop() } } catch { }
}

function Show-Alert($Task, [switch]$Test) {
    $script:AlertTask       = $Task
    $script:AlertIsTest     = [bool]$Test
    $script:AlertAllowClose = $false
    $script:AlertShownAt    = Get-Date
    $script:AlertTicks      = 0

    if ($Test) {
        $head = 'OPOMNIK  ·  preizkus'
    } else {
        $now  = Get-Date
        $due  = ConvertTo-Date $Task.Due
        $head = 'OPOMNIK  ·  ' + (Format-When $due)
        $late = [int][Math]::Floor(($now - $due).TotalMinutes)
        if ($late -ge 2) { $head += '  ·  zamuda ' + (Format-Duration $late) }
        $others = @($script:Tasks | Where-Object { -not $_.Done -and $_.Id -ne $Task.Id -and (Get-AlertTime $_) -le $now }).Count
        if ($others -gt 0) { $head += "  ·  še $others v vrsti" }
    }

    try {
        $f = New-AlertForm -TaskText $Task.Text -Head $head
        Set-AlertPosition $f
        $script:AlertForm = $f
        $f.Show()
        Play-AlertSound
        $script:AlertTimer.Start()
    } catch {
        # Rezerva: če okna ni mogoče prikazati, vsaj navadno sporočilo na vrhu.
        Write-ErrorLog "Prikaz opomnika ni uspel: $_"
        if ($null -ne $script:AlertForm) {
            $script:AlertAllowClose = $true
            try { $script:AlertForm.Close() } catch { }
        }
        $script:AlertForm = $null
        [void][System.Windows.Forms.MessageBox]::Show($Task.Text, 'OPOMNIK', 'OK', 'Warning', 'Button1', 'ServiceNotification')
        Close-Alert 'done'
    }
}

function Show-TestAlert {
    if ($null -ne $script:AlertTask) { return }
    $fake = [pscustomobject]@{
        Id          = ''
        Due         = (ConvertFrom-Date (Get-Date))
        Text        = 'Tako izgleda opomnik. Klikni OPRAVLJENO ali ga odloži.'
        Done        = $false
        SnoozeUntil = ''
    }
    Show-Alert $fake -Test
}

# Kliče se 2x na sekundo, dokler je opomnik odprt.
function Update-Alert {
    $f = $script:AlertForm
    if ($null -eq $f) { return }
    $script:AlertTicks++
    $elapsed = ((Get-Date) - $script:AlertShownAt).TotalSeconds

    # gumbi začnejo delovati po 1 sekundi
    if ($elapsed -ge 1) {
        foreach ($c in $f.Controls) {
            if ($c -is [System.Windows.Forms.Button] -and -not $c.Enabled) { $c.Enabled = $true }
        }
    }

    # počasno utripanje (vsako sekundo)
    if ($script:AlertTicks % 2 -eq 0) {
        $color = $script:ColorB
        if ($script:AlertTicks % 4 -eq 0) { $color = $script:ColorA }
        $f.BackColor = $color
    }

    # vsake 3 s: če ga je kaj prekrilo ali skrilo, ga spet postavimo na vrh (brez kraje fokusa)
    if ($script:AlertTicks % 6 -eq 0) {
        if ($f.WindowState -eq 'Minimized') { $f.WindowState = 'Normal' }
        if ($script:NoActivate) { $f.KeepOnTop() }
    }

    # zvonec se ponovi vsaki 2 minuti, dokler ne potrdiš
    if (((Get-Date) - $script:LastSound).TotalSeconds -ge 120) { Play-AlertSound }
}

function Close-Alert([string]$Action, [int]$Minutes = 0) {
    $task = $script:AlertTask
    if ($null -ne $task -and -not $script:AlertIsTest) {
        if ($Action -eq 'done') {
            $task.Done = $true
            $task.SnoozeUntil = ''
        } elseif ($Action -eq 'snooze') {
            $task.SnoozeUntil = ConvertFrom-Date ((Get-Date).AddMinutes($Minutes))
        }
        Save-Data
    }
    $script:AlertTimer.Stop()
    Stop-AlertSound
    if ($null -ne $script:AlertForm) {
        $script:AlertAllowClose = $true
        $script:AlertForm.Close()
        $script:AlertAllowClose = $false
    }
    $script:AlertForm = $null
    $script:AlertTask = $null
    Refresh-List
    Update-Status
}

# Če je opravilo, ki je trenutno na opomniku, medtem izbrisano ali označeno
# kot opravljeno v glavnem oknu, opomnik zapremo.
function Test-AlertObsolete {
    $t = $script:AlertTask
    if ($null -eq $t -or $script:AlertIsTest) { return $false }
    if ($t.Done) { return $true }
    return -not ($script:Tasks | Where-Object { $_.Id -eq $t.Id })
}

# ---------------------------------------------------------------------------
# Glavno okno - seznam opravil
# ---------------------------------------------------------------------------
function Refresh-List {
    $lv = $script:ListView
    $selected = Get-SelectedIds
    $now   = Get-Date
    $today = $now.Date
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        # prikažemo vsa neopravljena + današnja/prihodnja opravljena
        $visible = @($script:Tasks |
            Where-Object { -not $_.Done -or (ConvertTo-Date $_.Due) -ge $today } |
            Sort-Object { ConvertTo-Date $_.Due })
        foreach ($t in $visible) {
            $due  = ConvertTo-Date $t.Due
            $item = New-Object System.Windows.Forms.ListViewItem
            $item.Text = Format-When $due
            $item.Tag  = $t.Id
            [void]$item.SubItems.Add($t.Text)
            if ($t.Done) {
                $status = 'opravljeno'
                $item.ForeColor = [System.Drawing.Color]::Gray
                $item.Font = $script:StrikeFont
            } elseif ($t.SnoozeUntil -and (ConvertTo-Date $t.SnoozeUntil) -gt $now) {
                $status = 'odloženo do ' + (ConvertTo-Date $t.SnoozeUntil).ToString('HH:mm')
                $item.ForeColor = [System.Drawing.Color]::DarkOrange
            } elseif ($due -le $now) {
                $status = 'ZDAJ'
                $item.ForeColor = [System.Drawing.Color]::Firebrick
            } else {
                $status = 'čaka'
            }
            [void]$item.SubItems.Add($status)
            [void]$lv.Items.Add($item)
            if ($selected -contains $t.Id) { $item.Selected = $true }
        }
    } finally {
        $lv.EndUpdate()
    }
}

function Update-Status {
    $now  = Get-Date
    $next = $script:Tasks | Where-Object { -not $_.Done } | Sort-Object { Get-AlertTime $_ } | Select-Object -First 1
    if ($null -ne $next) {
        $at   = Get-AlertTime $next
        $mins = [int][Math]::Ceiling(($at - $now).TotalMinutes)
        $in   = if ($mins -le 0) { 'zdaj' } else { 'čez ' + (Format-Duration $mins) }
        $script:LblStatus.Text = "Naslednji opomnik: $(Format-When $at) - $($next.Text)  ($in)"
        $tip = 'Opomnik - ' + $at.ToString('HH:mm') + ' ' + $next.Text
    } else {
        $script:LblStatus.Text = 'Ni čakajočih opravil.'
        $tip = 'Opomnik - ni čakajočih opravil'
    }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 60) + '...' }
    $script:Tray.Text = $tip
}

function Add-TaskFromInput {
    $text = $script:TxtTask.Text.Trim()
    if (-not $text) { [void]$script:TxtTask.Focus(); return }

    $date = $script:DtDate.Value.Date
    $hour = $script:DtTime.Value.Hour
    $min  = $script:DtTime.Value.Minute

    # "14:30 Pokliči stranko" -> ura se prebere kar iz besedila
    if ($text -match '^(\d{1,2})[:.](\d{2})\s+(.+)$') {
        $hh = [int]$Matches[1]
        $mm = [int]$Matches[2]
        if ($hh -le 23 -and $mm -le 59) {
            $hour = $hh
            $min  = $mm
            $text = $Matches[3].Trim()
        }
    }

    $due = $date.AddHours($hour).AddMinutes($min)
    if ($due -lt (Get-Date).AddMinutes(-1)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Čas $(Format-When $due) je že mimo, zato se bo opomnik prikazal takoj.`n`nDodam vseeno?",
            'Opomnik', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
    }

    [void]$script:Tasks.Add([pscustomobject]@{
        Id          = [guid]::NewGuid().ToString()
        Due         = (ConvertFrom-Date $due)
        Text        = $text
        Done        = $false
        SnoozeUntil = ''
    })
    Save-Data
    Refresh-List
    Update-Status
    $script:TxtTask.Clear()
    [void]$script:TxtTask.Focus()
}

function Switch-SelectedDone {
    $ids = Get-SelectedIds
    $sel = @($script:Tasks | Where-Object { $ids -contains $_.Id })
    if ($sel.Count -eq 0) { return }
    # če so vsa izbrana že opravljena, jih vrnemo nazaj med čakajoča
    $allDone = -not ($sel | Where-Object { -not $_.Done })
    foreach ($t in $sel) {
        $t.Done = -not $allDone
        $t.SnoozeUntil = ''
    }
    Save-Data
    if (Test-AlertObsolete) { Close-Alert 'none' }
    Refresh-List
    Update-Status
}

function Remove-SelectedTasks {
    $ids = Get-SelectedIds
    if ($ids.Count -eq 0) { return }
    $word = if ($ids.Count -eq 1) { 'izbrano opravilo' } else { "izbrana opravila ($($ids.Count))" }
    $answer = [System.Windows.Forms.MessageBox]::Show("Izbrišem ${word}?", 'Opomnik', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    for ($i = $script:Tasks.Count - 1; $i -ge 0; $i--) {
        if ($ids -contains $script:Tasks[$i].Id) { $script:Tasks.RemoveAt($i) }
    }
    Save-Data
    if (Test-AlertObsolete) { Close-Alert 'none' }
    Refresh-List
    Update-Status
}

function Show-MainWindow {
    $f = $script:MainForm
    $f.Show()
    if ($f.WindowState -eq 'Minimized') { $f.WindowState = 'Normal' }
    # kratek "TopMost" trik, da okno zares pride v ospredje
    $f.TopMost = $true
    $f.TopMost = $false
    $f.Activate()
    Refresh-List
    Update-Status
}

function Exit-App {
    $pending = @($script:Tasks | Where-Object { -not $_.Done }).Count
    if ($pending -gt 0) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Neopravljenih opravil: $pending.`nČe zapreš Opomnik, te ne bo več opominjal.`n`nRes zaprem?",
            'Opomnik', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    $script:ReallyExit = $true
    $script:CheckTimer.Stop()
    if ($null -ne $script:AlertTask) { Close-Alert 'none' }
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    $script:MainForm.Close()
    $script:AppContext.ExitThread()
}

# ---------------------------------------------------------------------------
# Sestavimo okno
# ---------------------------------------------------------------------------
Load-Data
if ($script:ScriptPath -and (Test-Path $script:StartupLnk)) {
    # če je bila mapa premaknjena, posodobimo bližnjico za samodejni zagon
    try { Set-Autostart $true } catch { Write-ErrorLog "Autostart: $_" }
}

$script:AppIcon = New-AppIcon

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Opomnik'
$form.Icon          = $script:AppIcon
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 10)
$form.ClientSize    = New-Object System.Drawing.Size(660, 550)
$form.MinimumSize   = New-Object System.Drawing.Size(580, 450)
$script:MainForm    = $form
$script:StrikeFont  = New-Object System.Drawing.Font($form.Font, [System.Drawing.FontStyle]::Strikeout)

# --- vrstica 1: dan + ura
$lbl = New-Object System.Windows.Forms.Label
$lbl.Text     = 'Dan:'
$lbl.AutoSize = $true
$lbl.Location = New-Object System.Drawing.Point(12, 16)
$form.Controls.Add($lbl)

$dtDate = New-Object System.Windows.Forms.DateTimePicker
$dtDate.Format   = 'Short'
$dtDate.Location = New-Object System.Drawing.Point(52, 12)
$dtDate.Width    = 130
$form.Controls.Add($dtDate)
$script:DtDate = $dtDate

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text     = 'Ura:'
$lbl.AutoSize = $true
$lbl.Location = New-Object System.Drawing.Point(200, 16)
$form.Controls.Add($lbl)

$dtTime = New-Object System.Windows.Forms.DateTimePicker
$dtTime.Format       = 'Custom'
$dtTime.CustomFormat = 'HH:mm'
$dtTime.ShowUpDown   = $true
$dtTime.Location     = New-Object System.Drawing.Point(238, 12)
$dtTime.Width        = 80
$start = (Get-Date).AddMinutes(30)
$dtTime.Value = $start.Date.AddHours($start.Hour).AddMinutes([Math]::Ceiling($start.Minute / 5) * 5)
$form.Controls.Add($dtTime)
$script:DtTime = $dtTime

# --- vrstica 2: besedilo + Dodaj
$txtTask = New-Object System.Windows.Forms.TextBox
$txtTask.Location = New-Object System.Drawing.Point(12, 50)
$txtTask.Width    = 520
$txtTask.Anchor   = 'Top, Left, Right'
$form.Controls.Add($txtTask)
$script:TxtTask = $txtTask

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text     = 'Dodaj'
$btnAdd.Location = New-Object System.Drawing.Point(542, 48)
$btnAdd.Size     = New-Object System.Drawing.Size(106, 30)
$btnAdd.Anchor   = 'Top, Right'
$btnAdd.Add_Click({ Add-TaskFromInput })
$form.Controls.Add($btnAdd)
$form.AcceptButton = $btnAdd

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text      = 'Namig: napišeš lahko kar "14:30 Pokliči stranko" in ura se nastavi sama. Enter = dodaj.'
$lbl.AutoSize  = $true
$lbl.ForeColor = [System.Drawing.Color]::Gray
$lbl.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
$lbl.Location  = New-Object System.Drawing.Point(12, 84)
$form.Controls.Add($lbl)

# --- seznam opravil
$lv = New-Object System.Windows.Forms.ListView
$lv.View          = 'Details'
$lv.FullRowSelect = $true
$lv.HideSelection = $false
$lv.MultiSelect   = $true
$lv.Location      = New-Object System.Drawing.Point(12, 108)
$lv.Size          = New-Object System.Drawing.Size(636, 300)
$lv.Anchor        = 'Top, Bottom, Left, Right'
[void]$lv.Columns.Add('Kdaj', 120)
[void]$lv.Columns.Add('Opravilo', 375)
[void]$lv.Columns.Add('Stanje', 120)
$lv.Add_Resize({
    param($s, $e)
    $w = $s.ClientSize.Width - $s.Columns[0].Width - $s.Columns[2].Width - 4
    if ($w -gt 100) { $s.Columns[1].Width = $w }
})
$lv.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'Delete') { Remove-SelectedTasks }
})
$form.Controls.Add($lv)
$script:ListView = $lv

# --- gumbi pod seznamom
$btnDone = New-Object System.Windows.Forms.Button
$btnDone.Text     = 'Opravljeno'
$btnDone.Location = New-Object System.Drawing.Point(12, 418)
$btnDone.Size     = New-Object System.Drawing.Size(120, 32)
$btnDone.Anchor   = 'Bottom, Left'
$btnDone.Add_Click({ Switch-SelectedDone })
$form.Controls.Add($btnDone)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text     = 'Izbriši'
$btnDelete.Location = New-Object System.Drawing.Point(140, 418)
$btnDelete.Size     = New-Object System.Drawing.Size(100, 32)
$btnDelete.Anchor   = 'Bottom, Left'
$btnDelete.Add_Click({ Remove-SelectedTasks })
$form.Controls.Add($btnDelete)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text     = 'Preizkusi opomnik'
$btnTest.Location = New-Object System.Drawing.Point(248, 418)
$btnTest.Size     = New-Object System.Drawing.Size(160, 32)
$btnTest.Anchor   = 'Bottom, Left'
$btnTest.Add_Click({ Show-TestAlert })
$form.Controls.Add($btnTest)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text     = 'Izhod'
$btnExit.Location = New-Object System.Drawing.Point(548, 418)
$btnExit.Size     = New-Object System.Drawing.Size(100, 32)
$btnExit.Anchor   = 'Bottom, Right'
$btnExit.Add_Click({ Exit-App })
$form.Controls.Add($btnExit)

# --- nastavitve
$chkSound = New-Object System.Windows.Forms.CheckBox
$chkSound.Text     = 'Zvok ob opomniku'
$chkSound.AutoSize = $true
$chkSound.Location = New-Object System.Drawing.Point(14, 460)
$chkSound.Anchor   = 'Bottom, Left'
$chkSound.Checked  = [bool]$script:Settings.Sound
$chkSound.Add_Click({
    param($s, $e)
    $script:Settings.Sound = $s.Checked
    Save-Data
})
$form.Controls.Add($chkSound)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text     = 'Zaženi ob prijavi v Windows'
$chkAuto.AutoSize = $true
$chkAuto.Location = New-Object System.Drawing.Point(200, 460)
$chkAuto.Anchor   = 'Bottom, Left'
$chkAuto.Checked  = (Test-Path $script:StartupLnk)
if (-not $script:ScriptPath) { $chkAuto.Enabled = $false }
$chkAuto.Add_Click({
    param($s, $e)
    try {
        Set-Autostart $s.Checked
    } catch {
        Write-ErrorLog "Autostart: $_"
        [void][System.Windows.Forms.MessageBox]::Show("Samodejnega zagona ni bilo mogoče nastaviti:`n$_", 'Opomnik')
    }
    $s.Checked = (Test-Path $script:StartupLnk)
})
$form.Controls.Add($chkAuto)

$lbl = New-Object System.Windows.Forms.Label
$lbl.Text     = 'Kje se pokaže opomnik:'
$lbl.AutoSize = $true
$lbl.Location = New-Object System.Drawing.Point(12, 492)
$lbl.Anchor   = 'Bottom, Left'
$form.Controls.Add($lbl)

$cmbPos = New-Object System.Windows.Forms.ComboBox
$cmbPos.DropDownStyle = 'DropDownList'
$cmbPos.Location      = New-Object System.Drawing.Point(180, 488)
$cmbPos.Width         = 180
$cmbPos.Anchor        = 'Bottom, Left'
foreach ($k in $script:PositionNames.Keys) { [void]$cmbPos.Items.Add($script:PositionNames[$k]) }
$idx = [array]::IndexOf(@($script:PositionNames.Keys), $script:Settings.Position)
if ($idx -lt 0) { $idx = 0 }
$cmbPos.SelectedIndex = $idx
$cmbPos.Add_SelectedIndexChanged({
    param($s, $e)
    $script:Settings.Position = @($script:PositionNames.Keys)[$s.SelectedIndex]
    Save-Data
    if ($null -ne $script:AlertForm) { Set-AlertPosition $script:AlertForm }
})
$form.Controls.Add($cmbPos)

# --- statusna vrstica
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize    = $false
$lblStatus.UseMnemonic = $false
$lblStatus.Location    = New-Object System.Drawing.Point(12, 522)
$lblStatus.Size        = New-Object System.Drawing.Size(636, 24)
$lblStatus.Anchor      = 'Bottom, Left, Right'
$lblStatus.Font        = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblStatus)
$script:LblStatus = $lblStatus

# Križec (X) okna ne zapre programa, samo skrije ga v sistemsko vrstico.
$form.Add_FormClosing({
    param($s, $e)
    if ($script:ReallyExit -or $e.CloseReason -eq 'WindowsShutDown' -or $e.CloseReason -eq 'TaskManagerClosing') { return }
    $e.Cancel = $true
    $s.Hide()
    if (-not $script:TrayHintShown) {
        $script:TrayHintShown = $true
        $script:Tray.ShowBalloonTip(5000, 'Opomnik teče naprej v ozadju',
            'Najdeš ga spodaj desno ob uri. Za izhod: desni klik na ikono > Izhod.', 'Info')
    }
})

# ---------------------------------------------------------------------------
# Ikona v sistemski vrstici
# ---------------------------------------------------------------------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $script:AppIcon
$tray.Text = 'Opomnik'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$mi = $menu.Items.Add('Odpri opomnik')
$mi.Font = New-Object System.Drawing.Font($mi.Font, [System.Drawing.FontStyle]::Bold)
$mi.Add_Click({ Show-MainWindow })
$mi = $menu.Items.Add('Preizkusi opomnik')
$mi.Add_Click({ Show-TestAlert })
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$mi = $menu.Items.Add('Izhod')
$mi.Add_Click({ Exit-App })
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({
    param($s, $e)
    if ($e.Button -eq 'Left') { Show-MainWindow }
})
$tray.Visible = $true
$script:Tray = $tray

# ---------------------------------------------------------------------------
# Časovnika
# ---------------------------------------------------------------------------
$script:AlertTimer = New-Object System.Windows.Forms.Timer
$script:AlertTimer.Interval = 500
$script:AlertTimer.Add_Tick({
    try { Update-Alert } catch { Write-ErrorLog "AlertTimer: $_" }
})

# vsaki 2 s preveri, ali je kakšno opravilo na vrsti
$script:CheckTimer = New-Object System.Windows.Forms.Timer
$script:CheckTimer.Interval = 2000
$script:CheckTimer.Add_Tick({
    try {
        # nekdo je še enkrat zagnal Opomnik -> pokaži okno
        if ($script:ShowEvent.WaitOne(0)) { Show-MainWindow }

        # nov dan -> osveži "danes/jutri" v seznamu
        if ((Get-Date).Date -ne $script:LastDay) {
            $script:LastDay = (Get-Date).Date
            $script:DtDate.Value = $script:LastDay
            Refresh-List
        }

        if (Test-AlertObsolete) { Close-Alert 'none' }

        if ($null -eq $script:AlertTask) {
            $next = Get-NextDueTask
            if ($null -ne $next) { Show-Alert $next }
        }
        Update-Status
    } catch {
        Write-ErrorLog "CheckTimer: $_"
    }
})

[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-ErrorLog ('Nepričakovana napaka: ' + $e.Exception.ToString())
})

# ---------------------------------------------------------------------------
# Zagon
# ---------------------------------------------------------------------------
$script:AppContext = New-Object System.Windows.Forms.ApplicationContext
if ($Tray) { Refresh-List; Update-Status } else { Show-MainWindow }
$script:CheckTimer.Start()
[System.Windows.Forms.Application]::Run($script:AppContext)

try { $script:Mutex.ReleaseMutex() } catch { }
