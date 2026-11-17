<#
.SYNOPSIS
    Opomnik - preprost opomnik za dnevna opravila.
.DESCRIPTION
    Vpišeš opravila in uro. Ob tisti uri se čez CEL zaslon (na vseh monitorjih)
    prikaže velik rdeč opomnik z zvokom. Ne da se ga zapreti z Alt+F4 ali Esc -
    klikniti moraš "OPRAVLJENO" ali ga odložiti (5 min / 15 min / 1 uro).

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

$script:Tasks    = New-Object System.Collections.ArrayList
$script:Settings = [pscustomobject]@{ Sound = $true }

$script:AlertForms      = @()
$script:AlertTask       = $null
$script:AlertIsTest     = $false
$script:AlertAllowClose = $false
$script:AlertShownAt    = [datetime]::MinValue
$script:AlertTicks      = 0
$script:Player          = $null
$script:SoundMode       = 'none'
$script:LastSound       = [datetime]::MinValue
$script:ReallyExit      = $false
$script:TrayHintShown   = $false
$script:LastDay         = (Get-Date).Date

$script:ColorA = [System.Drawing.Color]::FromArgb(183, 28, 28)
$script:ColorB = [System.Drawing.Color]::FromArgb(211, 47, 47)

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
        if ($null -ne $data.Settings -and $null -ne $data.Settings.Sound) {
            $script:Settings.Sound = [bool]$data.Settings.Sound
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
# VELIK OPOMNIK čez cel zaslon
# ---------------------------------------------------------------------------

# Največja pisava, pri kateri se besedilo še prilega v okvir.
function Get-FittingFont([string]$Text, [int]$MaxWidth, [int]$MaxHeight, [int]$StartSize) {
    $flags = [System.Windows.Forms.TextFormatFlags]::WordBreak
    $size = $StartSize
    while ($size -gt 18) {
        $font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold)
        $measured = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $font, (New-Object System.Drawing.Size($MaxWidth, 0)), $flags)
        if ($measured.Height -le $MaxHeight -and $measured.Width -le $MaxWidth) { return $font }
        $font.Dispose()
        $size -= 4
    }
    return New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
}

function New-AlertLabel([string]$Text, $Font, $Color) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text        = $Text
    $lbl.Font        = $Font
    $lbl.ForeColor   = $Color
    $lbl.BackColor   = [System.Drawing.Color]::Transparent
    $lbl.TextAlign   = 'MiddleCenter'
    $lbl.AutoSize    = $false
    $lbl.UseMnemonic = $false
    return $lbl
}

function New-AlertForm($Screen, [string]$TaskText, [string]$When) {
    $b = $Screen.Bounds
    $w = $b.Width
    $h = $b.Height
    $white = [System.Drawing.Color]::White
    $pink  = [System.Drawing.Color]::FromArgb(255, 205, 210)

    $f = New-Object System.Windows.Forms.Form
    $f.Text            = 'Opomnik'
    $f.FormBorderStyle = 'None'
    $f.StartPosition   = 'Manual'
    $f.Bounds          = $b
    $f.TopMost         = $true
    $f.ShowInTaskbar   = $false
    $f.BackColor       = $script:ColorA
    $f.Icon            = $script:AppIcon

    # Alt+F4 / zapiranje ne deluje - zapre se samo z gumbom
    $f.Add_FormClosing({
        param($s, $e)
        if (-not $script:AlertAllowClose -and $e.CloseReason -ne 'WindowsShutDown') { $e.Cancel = $true }
    })

    # naslov
    $lbl = New-AlertLabel 'OPOMNIK' (New-Object System.Drawing.Font('Segoe UI', 24, [System.Drawing.FontStyle]::Bold)) $pink
    $lbl.SetBounds(0, [int]($h * 0.07), $w, [int]($h * 0.08))
    $f.Controls.Add($lbl)

    # besedilo opravila - čim večje
    $textW = [int]($w * 0.9)
    $textH = [int]($h * 0.36)
    $startSize = [int][Math]::Min(90, $h / 12)
    $font = Get-FittingFont -Text $TaskText -MaxWidth ($textW - 20) -MaxHeight ($textH - 10) -StartSize $startSize
    $lbl = New-AlertLabel $TaskText $font $white
    $lbl.SetBounds([int](($w - $textW) / 2), [int]($h * 0.16), $textW, $textH)
    $f.Controls.Add($lbl)

    # kdaj je bilo predvideno
    $lbl = New-AlertLabel $When (New-Object System.Drawing.Font('Segoe UI', 20)) $pink
    $lbl.SetBounds(0, [int]($h * 0.53), $w, [int]($h * 0.08))
    $f.Controls.Add($lbl)

    # gumb OPRAVLJENO
    $doneW = [int][Math]::Min(620, $w * 0.45)
    $doneH = [int][Math]::Max(90, $h * 0.11)
    $doneY = [int]($h * 0.63)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text      = 'OPRAVLJENO'
    $btn.Font      = New-Object System.Drawing.Font('Segoe UI', 28, [System.Drawing.FontStyle]::Bold)
    $btn.BackColor = $white
    $btn.ForeColor = $script:ColorA
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 0
    $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $btn.Enabled   = $false   # vklopi se po 2 s (da ga ne potrdiš po nesreči med tipkanjem)
    $btn.SetBounds([int](($w - $doneW) / 2), $doneY, $doneW, $doneH)
    $btn.Add_Click({ Close-Alert 'done' })
    $f.Controls.Add($btn)

    # gumbi za odlog
    $snoozeOptions = @(
        @(5,  'Odloži 5 min'),
        @(15, 'Odloži 15 min'),
        @(60, 'Odloži 1 uro')
    )
    $snW = 230
    $snH = [int][Math]::Max(48, $h * 0.06)
    $gap = 24
    $snY = $doneY + $doneH + [int]($h * 0.04)
    $x = [int](($w - ($snoozeOptions.Count * $snW + ($snoozeOptions.Count - 1) * $gap)) / 2)
    foreach ($opt in $snoozeOptions) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text      = $opt[1]
        $btn.Tag       = $opt[0]
        $btn.Font      = New-Object System.Drawing.Font('Segoe UI', 14)
        $btn.BackColor = [System.Drawing.Color]::FromArgb(127, 0, 0)
        $btn.ForeColor = $white
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderColor = $pink
        $btn.FlatAppearance.BorderSize  = 2
        $btn.Cursor    = [System.Windows.Forms.Cursors]::Hand
        $btn.Enabled   = $false
        $btn.SetBounds($x, $snY, $snW, $snH)
        $btn.Add_Click({ param($s, $e) Close-Alert 'snooze' ([int]$s.Tag) })
        $f.Controls.Add($btn)
        $x += $snW + $gap
    }

    $lbl = New-AlertLabel 'To okno se ne zapre, dokler ne izbereš ene od možnosti.' (New-Object System.Drawing.Font('Segoe UI', 11)) $pink
    $lbl.SetBounds(0, [int]($h * 0.92), $w, [int]($h * 0.05))
    $f.Controls.Add($lbl)

    return $f
}

function Start-AlertSound {
    $script:SoundMode = 'none'
    $script:LastSound = [datetime]::MinValue
    if (-not $script:Settings.Sound) { return }
    try {
        if ($null -eq $script:Player) {
            $wav = Join-Path $env:WINDIR 'Media\Alarm01.wav'
            if (Test-Path $wav) { $script:Player = New-Object System.Media.SoundPlayer($wav) }
        }
        if ($null -ne $script:Player) {
            $script:Player.PlayLooping()
            $script:SoundMode = 'loop'
        } else {
            $script:SoundMode = 'beep'
        }
    } catch {
        $script:SoundMode = 'beep'
    }
}

function Stop-AlertSound {
    try { if ($null -ne $script:Player) { $script:Player.Stop() } } catch { }
    $script:SoundMode = 'none'
}

# Zvok: prvo minuto neprestano, potem enkrat na minuto, dokler ne potrdiš.
function Update-AlertSound([double]$Elapsed) {
    $sinceLast = ((Get-Date) - $script:LastSound).TotalSeconds
    switch ($script:SoundMode) {
        'loop' {
            if ($Elapsed -ge 60) {
                $script:Player.Stop()
                $script:SoundMode = 'reminder'
                $script:LastSound = Get-Date
            }
        }
        'beep' {
            if ($Elapsed -ge 60) {
                $script:SoundMode = 'reminder'
                $script:LastSound = Get-Date
            } elseif ($sinceLast -ge 3) {
                [System.Media.SystemSounds]::Exclamation.Play()
                $script:LastSound = Get-Date
            }
        }
        'reminder' {
            if ($sinceLast -ge 60) {
                if ($null -ne $script:Player) { $script:Player.Play() } else { [System.Media.SystemSounds]::Exclamation.Play() }
                $script:LastSound = Get-Date
            }
        }
    }
}

function Show-Alert($Task, [switch]$Test) {
    $script:AlertTask       = $Task
    $script:AlertIsTest     = [bool]$Test
    $script:AlertAllowClose = $false
    $script:AlertShownAt    = Get-Date
    $script:AlertTicks      = 0
    $script:AlertForms      = @()

    if ($Test) {
        $when = 'To je preizkus - tako bo videti opomnik.'
    } else {
        $due  = ConvertTo-Date $Task.Due
        $when = 'Predvideno ' + (Format-Day $due) + ' ob ' + $due.ToString('HH:mm')
        $late = [int][Math]::Floor(((Get-Date) - $due).TotalMinutes)
        if ($late -ge 2) { $when += '   (zamuda ' + (Format-Duration $late) + ')' }
    }

    try {
        # na vse zaslone, glavni zaslon prvi
        $screens = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { -not $_.Primary }
        foreach ($scr in $screens) {
            $f = New-AlertForm -Screen $scr -TaskText $Task.Text -When $when
            $script:AlertForms += $f
            $f.Show()
        }
        $script:AlertForms[0].Activate()
        Start-AlertSound
        $script:AlertTimer.Start()
    } catch {
        # Rezerva: če velikega okna ni mogoče prikazati, vsaj navadno okno na vrhu.
        Write-ErrorLog "Prikaz opomnika ni uspel: $_"
        $script:AlertAllowClose = $true
        foreach ($f in @($script:AlertForms)) { try { $f.Close() } catch { } }
        $script:AlertForms = @()
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
    if ($script:AlertForms.Count -eq 0) { return }
    $script:AlertTicks++
    $elapsed = ((Get-Date) - $script:AlertShownAt).TotalSeconds

    # gumbi začnejo delovati po 2 sekundah
    if ($elapsed -ge 2) {
        foreach ($f in $script:AlertForms) {
            foreach ($c in $f.Controls) {
                if ($c -is [System.Windows.Forms.Button] -and -not $c.Enabled) { $c.Enabled = $true }
            }
        }
    }

    # počasno utripanje ozadja (vsako sekundo)
    if ($script:AlertTicks % 2 -eq 0) {
        $color = if ($script:AlertTicks % 4 -eq 0) { $script:ColorA } else { $script:ColorB }
        foreach ($f in $script:AlertForms) { $f.BackColor = $color }
    }

    # če ga je kaj prekrilo ali minimiziralo, ga spet postavimo na vrh
    if ($script:AlertTicks % 4 -eq 0 -and $null -eq [System.Windows.Forms.Form]::ActiveForm) {
        foreach ($f in $script:AlertForms) {
            if ($f.WindowState -ne 'Normal') { $f.WindowState = 'Normal' }
            $f.TopMost = $false
            $f.TopMost = $true
        }
        $script:AlertForms[0].Activate()
    }

    Update-AlertSound $elapsed
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
    $script:AlertAllowClose = $true
    foreach ($f in @($script:AlertForms)) { $f.Close() }
    $script:AlertForms      = @()
    $script:AlertTask       = $null
    $script:AlertAllowClose = $false
    Refresh-List
    Update-Status
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
$form.ClientSize    = New-Object System.Drawing.Size(660, 520)
$form.MinimumSize   = New-Object System.Drawing.Size(580, 420)
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

# --- statusna vrstica
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize    = $false
$lblStatus.UseMnemonic = $false
$lblStatus.Location    = New-Object System.Drawing.Point(12, 490)
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
