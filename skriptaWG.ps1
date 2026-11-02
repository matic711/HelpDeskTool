[CmdletBinding()]
param(
  # Pot do WireGuard .conf datoteke (opcijsko).
  # Ce je ne podas, skripta poisce .conf v isti mapi, kjer je skripta:
  #   ena  -> vzame to, vec -> ponudi izbiro, nobena -> vprasa za pot.
  [ValidateScript({ Test-Path $_ -PathType Leaf })]
  [string]$ConfigPath,

  # Opcijsko - ce ga ne podas, te skripta na zacetku vprasa za mail
  # (in predlaga trenutno prijavljenega uporabnika).
  # Lokalno: "PC\user" ali "user"
  # Entra:   "ime.priimek@podjetje.si" ali "AzureAD\ime.priimek@podjetje.si"
  [string]$User,

  # Ustvari VPN_ON/VPN_OFF na namizju uporabnika (opcijsko)
  [switch]$CreateDesktopButtons,

  # Odstrani in ponovno namesti tunel service (opcijsko)
  [switch]$ForceReinstallTunnel,

  # Dodaj tudi servisne pravice (Start/Stop/Query) na WireGuardTunnel$...
  # (priporočeno)
  [switch]$GrantServiceAcl = $true
)

# ---- Self-elevate: ce skripta ni zagnana kot admin, se sama ponovno zazene kot admin ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
  [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
  $cmd = "& '" + ($PSCommandPath -replace "'", "''") + "'"
  foreach ($kv in $PSBoundParameters.GetEnumerator()) {
    if ($kv.Value -is [System.Management.Automation.SwitchParameter]) {
      $cmd += " -$($kv.Key):`$$($kv.Value.IsPresent.ToString().ToLower())"
    } else {
      $val = [string]$kv.Value
      # admin okno se zazene v System32, zato relativno pot spremenimo v polno
      if ($kv.Key -eq 'ConfigPath') { $val = (Resolve-Path -LiteralPath $val).ProviderPath }
      $cmd += " -$($kv.Key) '" + ($val -replace "'", "''") + "'"
    }
  }
  try {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmd`""
  } catch {
    Write-Host "Skripta potrebuje admin pravice (UAC je bil zavrnjen)." -ForegroundColor Red
    Read-Host "Pritisni Enter za izhod" | Out-Null
  }
  exit
}

$ErrorActionPreference = "Stop"

function Find-WireGuardExe {
  $pf  = $env:ProgramFiles
  $pfx = ${env:ProgramFiles(x86)}

  $candidates = @()
  if ($pf)  { $candidates += (Join-Path $pf  "WireGuard\wireguard.exe") }
  if ($pfx) { $candidates += (Join-Path $pfx "WireGuard\wireguard.exe") }

  foreach ($p in $candidates) {
    if ($p -and (Test-Path $p -PathType Leaf)) { return $p }
  }

  $cmd = Get-Command "wireguard.exe" -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source -PathType Leaf)) { return $cmd.Source }

  throw "wireguard.exe ni najden. Namesti WireGuard for Windows."
}

function Enable-LimitedOperatorUI {
  reg add "HKLM\SOFTWARE\WireGuard" /v LimitedOperatorUI /t REG_DWORD /d 1 /f | Out-Null
  reg add "HKLM\SOFTWARE\WOW6432Node\WireGuard" /v LimitedOperatorUI /t REG_DWORD /d 1 /f | Out-Null
}

# Poisce .conf v mapi skripte. Ena -> vzame jo, vec -> izbira, nobena -> vprasa za pot.
function Select-ConfigFile {
  $confs = @()
  if ($PSScriptRoot) {
    $confs = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.conf -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -eq '.conf' })
  }

  if ($confs.Count -eq 1) {
    Write-Host "Najden config: $($confs[0].FullName)" -ForegroundColor Green
    return $confs[0].FullName
  }

  if ($confs.Count -gt 1) {
    Write-Host "V mapi je vec .conf datotek:"
    for ($i = 0; $i -lt $confs.Count; $i++) {
      Write-Host ("  [{0}] {1}" -f ($i + 1), $confs[$i].Name)
    }
    while ($true) {
      $sel = Read-Host "Izberi stevilko"
      $n = 0
      if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $confs.Count) {
        return $confs[$n - 1].FullName
      }
      Write-Host "Neveljavna izbira." -ForegroundColor Yellow
    }
  }

  Write-Host "V mapi skripte ni nobene .conf datoteke." -ForegroundColor Yellow
  while ($true) {
    $p = Read-Host "Vpisi pot do .conf datoteke (lahko jo povleces v to okno)"
    if ($p) { $p = $p.Trim().Trim('"').Trim("'") }
    if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) {
      return (Resolve-Path -LiteralPath $p).ProviderPath
    }
    Write-Host "Datoteke ne najdem: $p" -ForegroundColor Yellow
  }
}

# Tunel-servis bere .conf iz te poti ob vsakem zagonu -> ne sme biti na USB/omreznem disku.
function Test-ConfigLocation([string]$Path) {
  $risky = $false
  if ($Path -like '\\*') {
    $risky = $true
  } else {
    try {
      $drive = New-Object System.IO.DriveInfo ([IO.Path]::GetPathRoot($Path))
      if ($drive.DriveType -eq [IO.DriveType]::Removable -or $drive.DriveType -eq [IO.DriveType]::Network) { $risky = $true }
    } catch { }
  }

  if ($risky) {
    Write-Warning "Config je na USB ali omreznem disku. Tunel ga bere ob vsakem zagonu, zato VPN ne bo delal, ko disk odstranis. Kopiraj mapo na lokalni disk (npr. C:\WG) in zazeni znova."
    $ans = Read-Host "Vseeno nadaljujem? [d/N]"
    if ($ans -notmatch '^[DdYy]') { throw "Prekinjeno." }
  }
}

function Resolve-UserSid([string]$InputUser) {
  $candidates = @()
  $candidates += $InputUser

  # UPN -> AzureAD\UPN
  if ($InputUser -match ".+@.+" -and $InputUser -notmatch "^[^\\]+\\") {
    $candidates += "AzureAD\$InputUser"
  }

  # user -> COMPUTER\user
  if ($InputUser -notmatch "^[^\\]+\\") {
    $candidates += "$env:COMPUTERNAME\$InputUser"
  }

  foreach ($c in ($candidates | Select-Object -Unique)) {
    try {
      $sidObj = (New-Object System.Security.Principal.NTAccount($c)).
        Translate([System.Security.Principal.SecurityIdentifier])
      return [PSCustomObject]@{ Account = $c; SidObj = $sidObj; Sid = $sidObj.Value }
    } catch { }
  }

  throw "Uporabnika ne morem prevesti v SID. Naj se vsaj 1x prijavi na ta računalnik. Poskušeno: $($candidates -join ', ')"
}

# Predlog za mail: trenutno prijavljen uporabnik (lastnik explorer.exe).
# Za Entra (AzureAD) uporabnike prebere mail (UPN) iz IdentityStore cache.
function Get-LoggedOnUserSuggestion {
  try {
    $proc = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
    if (-not $proc) { return $null }

    $sid = (Invoke-CimMethod -InputObject $proc -MethodName GetOwnerSid -ErrorAction Stop).Sid
    if ($sid) {
      $key = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$sid\IdentityCache\$sid"
      $upn = (Get-ItemProperty -Path $key -Name UserName -ErrorAction SilentlyContinue).UserName
      if ($upn -and $upn -match '@') { return $upn }
    }

    $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction Stop
    if ($owner.User -and $owner.Domain -and $owner.Domain -ne 'AzureAD') {
      return "$($owner.Domain)\$($owner.User)"
    }
  } catch { }
  return $null
}

# Vprasa za mail (Enter = predlog), ga takoj preveri (SID) in ob napaki vprasa znova,
# da ni treba ponovno zaganjati skripte zaradi tipkarske napake.
function Read-TargetUser([string]$Suggestion) {
  while ($true) {
    if ($Suggestion) {
      $in = Read-Host "Mail uporabnika [Enter = $Suggestion]"
      if ([string]::IsNullOrWhiteSpace($in)) { $in = $Suggestion }
    } else {
      $in = Read-Host "Vpisi mail uporabnika (npr. ime.priimek@podjetje.si)"
    }
    if ($in) { $in = $in.Trim() }

    if ([string]::IsNullOrWhiteSpace($in)) {
      Write-Host "Mail ne sme biti prazen." -ForegroundColor Yellow
      continue
    }

    if ($in -match '@' -and $in -notmatch '^(AzureAD\\)?[^@\s\\]+@[^@\s\\]+\.[^@\s\\]+$') {
      Write-Host "'$in' ni veljaven mail. Poskusi znova." -ForegroundColor Yellow
      continue
    }

    try {
      $resolved = Resolve-UserSid -InputUser $in
    } catch {
      Write-Host $_.Exception.Message -ForegroundColor Yellow
      Write-Host "Poskusi znova (ali Ctrl+C za prekinitev)." -ForegroundColor Yellow
      continue
    }

    Write-Host "Najden uporabnik: $($resolved.Account)  (SID: $($resolved.Sid))" -ForegroundColor Green
    $ok = Read-Host "Nadaljujem? [D/n]"
    if ([string]::IsNullOrWhiteSpace($ok) -or $ok -match '^[DdYy]') {
      return [PSCustomObject]@{ Input = $in; Resolved = $resolved }
    }
  }
}

# Namizje izbranega uporabnika (uposteva tudi OneDrive preusmeritev namizja).
function Get-UserDesktopPath([string]$Sid) {
  $profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$Sid" -ErrorAction SilentlyContinue).ProfileImagePath

  # 1) iz uporabnikovega registra (na voljo, ko je uporabnik prijavljen)
  $raw = $null
  try {
    $usf = Get-Item -Path "Registry::HKEY_USERS\$Sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction Stop
    $raw = $usf.GetValue('Desktop', $null, 'DoNotExpandEnvironmentNames')
  } catch { }

  if ($raw) {
    if ($profilePath) { $raw = $raw -ireplace [regex]::Escape('%USERPROFILE%'), $profilePath }
    $path = [Environment]::ExpandEnvironmentVariables($raw)
    if (Test-Path -LiteralPath $path -PathType Container) { return $path }
  }

  # 2) fallback: <profil>\Desktop
  if ($profilePath) {
    $path = Join-Path $profilePath 'Desktop'
    if (Test-Path -LiteralPath $path -PathType Container) { return $path }
  }

  return $null
}

function Ensure-NetworkConfigOperators([string]$Account) {
  $group = "Network Configuration Operators"
  try {
    net localgroup $group "$Account" /add | Out-Null
    return $true
  } catch {
    # net localgroup včasih vrne non-0 tudi če je že član, zato raje preverimo članstvo
    $members = (net localgroup $group) 2>$null
    if ($members -and ($members -match [regex]::Escape($Account))) { return $false }
    # če ni razvidno, vržemo original error
    throw
  }
}

function Get-TunnelServiceName([string]$TunnelName) {
  $pattern = "WireGuardTunnel`$$TunnelName"
  $svc = Get-Service -Name $pattern -ErrorAction SilentlyContinue
  if (-not $svc) { return $null }
  return $svc.Name
}

# ---- Native API: safe edit of service DACL (no sc sdset / SDDL hacks) ----
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class ServiceSecurityNative
{
    public const int SC_MANAGER_CONNECT = 0x0001;
    public const int READ_CONTROL = 0x00020000;
    public const int WRITE_DAC = 0x00040000;
    public const int DACL_SECURITY_INFORMATION = 0x00000004;

    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr OpenSCManager(string machineName, string databaseName, int dwAccess);

    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr OpenService(IntPtr hSCManager, string lpServiceName, int dwDesiredAccess);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool CloseServiceHandle(IntPtr hSCObject);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool QueryServiceObjectSecurity(IntPtr hService, int dwSecurityInformation, byte[] lpSecurityDescriptor, int cbBufSize, out int pcbBytesNeeded);

    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern bool SetServiceObjectSecurity(IntPtr hService, int dwSecurityInformation, byte[] lpSecurityDescriptor);

    public static byte[] GetServiceSecurityDescriptor(string serviceName)
    {
        IntPtr scm = OpenSCManager(null, null, SC_MANAGER_CONNECT);
        if (scm == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager failed");

        IntPtr svc = OpenService(scm, serviceName, READ_CONTROL);
        if (svc == IntPtr.Zero)
        {
            CloseServiceHandle(scm);
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenService(READ_CONTROL) failed");
        }

        try
        {
            int needed;
            QueryServiceObjectSecurity(svc, DACL_SECURITY_INFORMATION, null, 0, out needed);
            int err = Marshal.GetLastWin32Error();
            if (needed <= 0) throw new Win32Exception(err, "QueryServiceObjectSecurity size query failed");

            byte[] sd = new byte[needed];
            if (!QueryServiceObjectSecurity(svc, DACL_SECURITY_INFORMATION, sd, sd.Length, out needed))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "QueryServiceObjectSecurity failed");

            return sd;
        }
        finally
        {
            CloseServiceHandle(svc);
            CloseServiceHandle(scm);
        }
    }

    public static void SetServiceSecurityDescriptor(string serviceName, byte[] sd)
    {
        IntPtr scm = OpenSCManager(null, null, SC_MANAGER_CONNECT);
        if (scm == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenSCManager failed");

        IntPtr svc = OpenService(scm, serviceName, READ_CONTROL | WRITE_DAC);
        if (svc == IntPtr.Zero)
        {
            CloseServiceHandle(scm);
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenService(WRITE_DAC) failed");
        }

        try
        {
            if (!SetServiceObjectSecurity(svc, DACL_SECURITY_INFORMATION, sd))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "SetServiceObjectSecurity failed");
        }
        finally
        {
            CloseServiceHandle(svc);
            CloseServiceHandle(scm);
        }
    }
}
"@

function Grant-TunnelServiceRights([string]$ServiceName, [System.Security.Principal.SecurityIdentifier]$SidObj) {
  # SERVICE_QUERY_STATUS  = 0x0004
  # SERVICE_START         = 0x0010
  # SERVICE_STOP          = 0x0020
  # READ_CONTROL          = 0x20000
  $mask = 0x0004 -bor 0x0010 -bor 0x0020 -bor 0x20000

  $sdBytes = [ServiceSecurityNative]::GetServiceSecurityDescriptor($ServiceName)
  $csd = New-Object System.Security.AccessControl.CommonSecurityDescriptor $false, $false, $sdBytes, 0
  $acl = [System.Security.AccessControl.DiscretionaryAcl]$csd.DiscretionaryAcl

  $acl.AddAccess(
    [System.Security.AccessControl.AccessControlType]::Allow,
    $SidObj,
    $mask,
    [System.Security.AccessControl.InheritanceFlags]::None,
    [System.Security.AccessControl.PropagationFlags]::None
  )

  $csd.DiscretionaryAcl = $acl
  $outBytes = New-Object byte[] ($csd.BinaryLength)
  $csd.GetBinaryForm($outBytes, 0)

  [ServiceSecurityNative]::SetServiceSecurityDescriptor($ServiceName, $outBytes)
}

# ---------------- MAIN ----------------

try {
  $wgExe = Find-WireGuardExe

  # 0a) Config: ce ni podan z -ConfigPath, ga poiscemo v mapi skripte
  if (-not $ConfigPath) { $ConfigPath = Select-ConfigFile }
  $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
  Test-ConfigLocation -Path $ConfigPath
  $tunnelName = [IO.Path]::GetFileNameWithoutExtension($ConfigPath)
  Write-Host ""

  # 0b) Uporabnik: ce ni podan z -User, ga vprasamo za mail
  if ([string]::IsNullOrWhiteSpace($User)) {
    $answer = Read-TargetUser -Suggestion (Get-LoggedOnUserSuggestion)
    $User = $answer.Input
    $res  = $answer.Resolved
    Write-Host ""
  } else {
    # Resolve SID + canonical account
    $res = Resolve-UserSid -InputUser $User
  }

  Write-Host "ConfigPath   : $ConfigPath"
  Write-Host "TunnelName   : $tunnelName"
  Write-Host "User (input) : $User"
  Write-Host "WireGuard EXE: $wgExe"
  Write-Host ""

  Write-Host "User (resolved): $($res.Account)"
  Write-Host "User SID       : $($res.Sid)"

  # 1) Ensure NCO membership (ključni del za GUI)
  Write-Host "Ensuring user is in 'Network Configuration Operators'..."
  $added = Ensure-NetworkConfigOperators -Account $res.Account
  if ($added) { Write-Host "User added to Network Configuration Operators." } else { Write-Host "User already in Network Configuration Operators." }

  # 2) Enable LimitedOperatorUI (GUI allow)
  Write-Host "Enabling LimitedOperatorUI..."
  Enable-LimitedOperatorUI

  # 3) Install tunnel service (if missing)
  if ($ForceReinstallTunnel) {
    Write-Host "ForceReinstallTunnel: uninstall + install"
    try { & "$wgExe" /uninstalltunnelservice "$tunnelName" | Out-Null } catch { }
    Start-Sleep -Milliseconds 500
  }

  $serviceName = Get-TunnelServiceName -TunnelName $tunnelName
  if (-not $serviceName) {
    Write-Host "Installing tunnel service..."
    & "$wgExe" /installtunnelservice "$ConfigPath" | Out-Null
    Start-Sleep -Seconds 1
    $serviceName = Get-TunnelServiceName -TunnelName $tunnelName
  }

  if (-not $serviceName) { throw "Tunel-servisa ne najdem. Preveri .conf in ime tunela." }

  Write-Host "Tunnel service: $serviceName"

  # 4) Manual startup (ni always-on)
  Set-Service -Name $serviceName -StartupType Manual

  # 5) Optional: grant service ACL (da deluje sc start/stop, gumbi, ipd.)
  if ($GrantServiceAcl) {
    Write-Host "Granting Start/Stop/Query rights on tunnel service..."
    Grant-TunnelServiceRights -ServiceName $serviceName -SidObj $res.SidObj
    Write-Host "Tunnel service rights updated."
  }

  # 6) Optional: gumbi na namizju izbranega uporabnika
  if ($CreateDesktopButtons) {
    $UserDesktop = Get-UserDesktopPath -Sid $res.Sid
    if ($UserDesktop) {
      Set-Content (Join-Path $UserDesktop "VPN_ON.bat")  "sc start `"$serviceName`"" -Encoding ASCII
      Set-Content (Join-Path $UserDesktop "VPN_OFF.bat") "sc stop `"$serviceName`""  -Encoding ASCII
      Write-Host "Created VPN_ON/VPN_OFF on $UserDesktop"
    } else {
      Write-Warning "Namizja za $($res.Account) ne najdem - gumbov VPN_ON/VPN_OFF nisem ustvaril."
    }
  }

  # 7) Restart manager (prebere LimitedOperatorUI)
  try {
    Restart-Service WireGuardManager -Force
    Write-Host "WireGuardManager restarted."
  } catch {
    Write-Host "WireGuardManager restart skipped."
  }

  Write-Host ""
  Write-Host "DONE." -ForegroundColor Green
  Write-Host "Test kot uporabnik (po restartu):"
  Write-Host "  whoami /groups | findstr /i `"Network Configuration Operators`""
  Write-Host "  sc start `"$serviceName`""
  Write-Host "  sc stop  `"$serviceName`""
  Write-Host ""

  # 8) Restart racunalnika (potreben, da se osvezi group membership v tokenu)
  $rb = Read-Host "Za delovanje je potreben restart. Ponovno zazenem racunalnik zdaj? (neshranjeno delo se izgubi) [d/N]"
  if ($rb -match '^[DdYy]') { Restart-Computer -Force }
}
catch {
  Write-Host ""
  Write-Host "NAPAKA: $($_.Exception.Message)" -ForegroundColor Red
  Read-Host "Pritisni Enter za izhod" | Out-Null
  exit 1
}
