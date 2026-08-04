<#
.SYNOPSIS
    HelpDesk Tool - konzolni meni za resevanje osnovnih Windows tezav.
.DESCRIPTION
    En sam .ps1 file, ki se sam-povisa (elevate) na administratorja,
    prikaze stevilcni meni in ob izbiri izvede ustrezen popravek.
    Vsaka akcija se zabelezi v log datoteko.
.NOTES
    Zagon: desni klik -> "Run with PowerShell"
    ali iz PowerShella:  .\HelpDeskTool.ps1
    ali z enim ukazom (ce je file na deljeni mapi / spletnem streznikom):
      powershell -ExecutionPolicy Bypass -File "\\server\it\HelpDeskTool.ps1"
      powershell -ExecutionPolicy Bypass -Command "irm https://internal.example.com/HelpDeskTool.ps1 | iex"
#>

# ---------------------------------------------------------------------------
# ce ga distribuiras kot "irm <URL> | iex" enovrsticnik, vpisi svoj URL tukaj
# (ce ga poganjas samo kot lokalno .ps1 datoteko, to ni potrebno)
# ---------------------------------------------------------------------------
$ScriptUrl = "https://RAW-URL-TO/HelpDeskTool.ps1"

# ---------------------------------------------------------------------------
# Self-elevate na administratorja, ce se ni.
# Ce je bil skript zagnan kot datoteka ($PSCommandPath obstaja), ga znova
# zazenemo iz iste datoteke. Ce je bil zagnan preko "irm | iex" (ni file
# path), ga znova poberemo iz $ScriptUrl v povisanem oknu.
# ---------------------------------------------------------------------------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($PSCommandPath) {
        Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    } else {
        Start-Process powershell.exe "-NoProfile -Command `"irm '$ScriptUrl' | iex`"" -Verb RunAs
    }
    exit
}

$LogFile = "$env:TEMP\HelpDeskTool_$(Get-Date -Format 'yyyyMMdd').log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'HH:mm:ss'
    "$timestamp - $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Pause-Menu {
    Write-Host ""
    Read-Host "Pritisni ENTER za nadaljevanje"
}

function Show-Header {
    Clear-Host
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host "        HELP DESK TOOL - Windows diagnostika      " -ForegroundColor Cyan
    Write-Host "=================================================" -ForegroundColor Cyan
    Write-Host " Racunalnik: $env:COMPUTERNAME   Uporabnik: $env:USERNAME" -ForegroundColor DarkGray
    Write-Host " Log: $LogFile" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Posamezne funkcije popravkov
# ---------------------------------------------------------------------------

function Fix-Network {
    Show-Header
    Write-Host "Popravljam omrezne nastavitve (DNS/IP/Winsock)..." -ForegroundColor Yellow
    Write-Log "Fix-Network: started"
    try {
        ipconfig /flushdns | Out-Null
        ipconfig /release   | Out-Null
        ipconfig /renew     | Out-Null
        netsh winsock reset | Out-Null
        netsh int ip reset  | Out-Null
        Write-Host "Koncano. Priporocam RESTART racunalnika, da se spremembe uveljavijo." -ForegroundColor Green
        Write-Log "Fix-Network: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Fix-Network: ERROR $_"
    }
    Pause-Menu
}

function Reset-WindowsUpdate {
    Show-Header
    Write-Host "Ponastavljam Windows Update komponente..." -ForegroundColor Yellow
    Write-Log "Reset-WindowsUpdate: started"
    try {
        Stop-Service -Name wuauserv, cryptsvc, bits, msiserver -Force -ErrorAction SilentlyContinue
        $sd = "$env:windir\SoftwareDistribution"
        $cr = "$env:windir\System32\catroot2"
        if (Test-Path $sd) { Rename-Item $sd "$sd.old_$(Get-Date -Format yyyyMMddHHmmss)" -ErrorAction SilentlyContinue }
        if (Test-Path $cr) { Rename-Item $cr "$cr.old_$(Get-Date -Format yyyyMMddHHmmss)" -ErrorAction SilentlyContinue }
        Start-Service -Name wuauserv, cryptsvc, bits, msiserver -ErrorAction SilentlyContinue
        Write-Host "Windows Update ponastavljen. Poskusi znova z Windows Update." -ForegroundColor Green
        Write-Log "Reset-WindowsUpdate: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Reset-WindowsUpdate: ERROR $_"
    }
    Pause-Menu
}

function Reset-PrintSpooler {
    Show-Header
    Write-Host "Ponastavljam tiskalno vrsto (Print Spooler)..." -ForegroundColor Yellow
    Write-Log "Reset-PrintSpooler: started"
    try {
        Stop-Service -Name Spooler -Force
        Remove-Item "$env:windir\System32\spool\PRINTERS\*" -Force -ErrorAction SilentlyContinue
        Start-Service -Name Spooler
        Write-Host "Tiskalna vrsta ponastavljena." -ForegroundColor Green
        Write-Log "Reset-PrintSpooler: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Reset-PrintSpooler: ERROR $_"
    }
    Pause-Menu
}

function Restart-Explorer {
    Show-Header
    Write-Host "Ponovno zaganjam Windows Explorer (taskbar/ikone)..." -ForegroundColor Yellow
    Write-Log "Restart-Explorer: started"
    try {
        Stop-Process -Name explorer -Force
        Start-Sleep -Seconds 2
        Start-Process explorer.exe
        Write-Host "Explorer ponovno zagnan." -ForegroundColor Green
        Write-Log "Restart-Explorer: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Restart-Explorer: ERROR $_"
    }
    Pause-Menu
}

function Clear-TempFiles {
    Show-Header
    Write-Host "Cistim zacasne datoteke..." -ForegroundColor Yellow
    Write-Log "Clear-TempFiles: started"
    try {
        $paths = @("$env:TEMP\*", "$env:windir\Temp\*", "$env:windir\Prefetch\*")
        foreach ($p in $paths) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "Zacasne datoteke pocisceno." -ForegroundColor Green
        Write-Log "Clear-TempFiles: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Clear-TempFiles: ERROR $_"
    }
    Pause-Menu
}

function Fix-Audio {
    Show-Header
    Write-Host "Ponovno zaganjam zvocne storitve..." -ForegroundColor Yellow
    Write-Log "Fix-Audio: started"
    try {
        Restart-Service -Name Audiosrv -Force -ErrorAction Stop
        Restart-Service -Name AudioEndpointBuilder -Force -ErrorAction Stop
        Write-Host "Zvocne storitve ponovno zagnane." -ForegroundColor Green
        Write-Log "Fix-Audio: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Fix-Audio: ERROR $_"
    }
    Pause-Menu
}

function Run-SystemScan {
    Show-Header
    Write-Host "Zaganjam SFC in DISM pregled (lahko traja 10-20 min)..." -ForegroundColor Yellow
    Write-Log "Run-SystemScan: started"
    try {
        Write-Host "`n--- DISM RestoreHealth ---" -ForegroundColor DarkCyan
        DISM /Online /Cleanup-Image /RestoreHealth
        Write-Host "`n--- SFC /scannow ---" -ForegroundColor DarkCyan
        sfc /scannow
        Write-Host "Pregled koncan. Preveri izpis zgoraj za rezultat." -ForegroundColor Green
        Write-Log "Run-SystemScan: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Run-SystemScan: ERROR $_"
    }
    Pause-Menu
}

function Reset-Outlook {
    Show-Header
    Write-Host "Ponastavljam Outlook (zapiram Outlook in brisem cache)..." -ForegroundColor Yellow
    Write-Log "Reset-Outlook: started"
    try {
        Stop-Process -Name OUTLOOK -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $rc = "$env:LOCALAPPDATA\Microsoft\Outlook\RoamCache"
        if (Test-Path $rc) { Remove-Item "$rc\*" -Force -ErrorAction SilentlyContinue }
        Write-Host "Outlook cache pocisceno. Ponovno odpri Outlook." -ForegroundColor Green
        Write-Host "Opomba: OST/PST datoteke niso bile odstranjene, samo roaming cache." -ForegroundColor DarkGray
        Write-Log "Reset-Outlook: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Reset-Outlook: ERROR $_"
    }
    Pause-Menu
}

function Reset-Store {
    Show-Header
    Write-Host "Ponastavljam Microsoft Store..." -ForegroundColor Yellow
    Write-Log "Reset-Store: started"
    try {
        Start-Process "wsreset.exe" -Wait
        Write-Host "Microsoft Store ponastavljen." -ForegroundColor Green
        Write-Log "Reset-Store: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Reset-Store: ERROR $_"
    }
    Pause-Menu
}

function Update-GroupPolicy {
    Show-Header
    Write-Host "Osvezujem Group Policy nastavitve..." -ForegroundColor Yellow
    Write-Log "Update-GroupPolicy: started"
    try {
        gpupdate /force
        Write-Log "Update-GroupPolicy: completed OK"
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
        Write-Log "Update-GroupPolicy: ERROR $_"
    }
    Pause-Menu
}

function Show-SystemInfo {
    Show-Header
    Write-Host "Osnovni sistemski podatki:" -ForegroundColor Yellow
    Write-Log "Show-SystemInfo: viewed"
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cs = Get-CimInstance Win32_ComputerSystem
        Write-Host "OS:        $($os.Caption) (Build $($os.BuildNumber))"
        Write-Host "Racunalnik:$($cs.Name)   Domena/Workgroup: $($cs.Domain)"
        Write-Host "RAM:       $([math]::Round($cs.TotalPhysicalMemory/1GB,1)) GB"
        Write-Host "Prosto na C:: $([math]::Round((Get-PSDrive C).Free/1GB,1)) GB"
        Write-Host ""
        Write-Host "--- IP konfiguracija ---" -ForegroundColor DarkCyan
        Get-NetIPConfiguration | Format-Table InterfaceAlias, IPv4Address, IPv4DefaultGateway -AutoSize
    } catch {
        Write-Host "Napaka: $_" -ForegroundColor Red
    }
    Pause-Menu
}

function Schedule-DiskCheck {
    Show-Header
    Write-Host "To bo ob naslednjem RESTARTU racunalnika preverilo disk C: za napake." -ForegroundColor Yellow
    $confirm = Read-Host "Nadaljujem? (D/N)"
    if ($confirm -match '^[dD]') {
        Write-Log "Schedule-DiskCheck: scheduled"
        cmd /c "echo Y| chkdsk C: /f /r" | Out-Null
        Write-Host "Disk pregled naravnan za naslednji restart." -ForegroundColor Green
    } else {
        Write-Host "Preklicano." -ForegroundColor DarkGray
    }
    Pause-Menu
}

# ---------------------------------------------------------------------------
# Glavni meni
# ---------------------------------------------------------------------------
do {
    Show-Header
    Write-Host " 1) Popravi omrezje (DNS/IP/Winsock reset)"
    Write-Host " 2) Ponastavi Windows Update"
    Write-Host " 3) Ponastavi tiskalno vrsto (Print Spooler)"
    Write-Host " 4) Ponovno zazeni Windows Explorer (zamrznjen taskbar/ikone)"
    Write-Host " 5) Pocisti zacasne datoteke (temp/prefetch)"
    Write-Host " 6) Popravi zvok (ni zvoka)"
    Write-Host " 7) SFC + DISM pregled sistemskih datotek"
    Write-Host " 8) Ponastavi Outlook cache"
    Write-Host " 9) Ponastavi Microsoft Store"
    Write-Host "10) Osvezi Group Policy (gpupdate /force)"
    Write-Host "11) Prikazi osnovne sistemske podatke"
    Write-Host "12) Naravnaj pregled diska ob restartu (chkdsk)"
    Write-Host ""
    Write-Host " 0) Izhod"
    Write-Host ""
    $choice = Read-Host "Izberi opcijo"

    switch ($choice) {
        '1'  { Fix-Network }
        '2'  { Reset-WindowsUpdate }
        '3'  { Reset-PrintSpooler }
        '4'  { Restart-Explorer }
        '5'  { Clear-TempFiles }
        '6'  { Fix-Audio }
        '7'  { Run-SystemScan }
        '8'  { Reset-Outlook }
        '9'  { Reset-Store }
        '10' { Update-GroupPolicy }
        '11' { Show-SystemInfo }
        '12' { Schedule-DiskCheck }
        '0'  { Write-Log "Session ended by user"; break }
        default { Write-Host "Neveljavna izbira." -ForegroundColor Red; Start-Sleep -Seconds 1 }
    }
} while ($choice -ne '0')
