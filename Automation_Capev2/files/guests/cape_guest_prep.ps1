<#
.SYNOPSIS
    Prepares a Windows 10/11 guest VM for use as a CAPE malware analysis target.

.DESCRIPTION
    Based on the official CAPE v2.5 guest preparation documentation.
    Performs these steps:
      - Downloads and installs x86 Python (required by the CAPE agent)
      - Installs Pillow for screenshot capture during analysis
      - Places agent.pyw and creates a scheduled task that runs it at logon
        with highest privileges
      - Disables Windows Defender, Tamper Protection, SmartScreen
      - Disables Windows Firewall on all profiles
      - Disables Windows Update automatic downloads
      - Disables UAC
      - Disables Windows Error Reporting
      - Reduces network noise: NCSI probes, LLMNR, Teredo
      - Disables telemetry and the DiagTrack service
      - Sets the power plan to high performance with no sleep or display timeout

.PARAMETER CapeHostIP
    IP address of the CAPE host. If provided, the script downloads agent.py
    via HTTP from that host. You must first start a temporary file server there:
        python3 -m http.server 9000 --directory /opt/CAPEv2/agent/
    If empty, the script looks for agent.pyw or agent.py next to itself.

.PARAMETER AgentServerPort
    Port of the temporary file server on the CAPE host. Default: 9000.

.PARAMETER PythonVersion
    x86 Python version to install. Must be 3.10 to 3.12. Default: 3.11.9.

.PARAMETER AgentDest
    Destination path for agent.pyw on this guest. Default: C:\Windows\agent.pyw.

.PARAMETER TaskName
    Scheduled task name. Pick something that does not reference CAPE or sandbox
    to avoid triggering anti-VM checks in analysed samples. Default: pizza.

.PARAMETER AutoLogonUser
    If set, configures Windows AutoLogon for this username. Requires
    -AutoLogonPassword. Leave empty to skip AutoLogon configuration.

.PARAMETER AutoLogonPassword
    Plain-text password for AutoLogon. Only used when -AutoLogonUser is set.

.PARAMETER NoReboot
    Skip the reboot at the end of the script.

.EXAMPLE
    # Run with local agent.pyw next to the script
    .\cape_guest_prep.ps1

    # Download agent from CAPE host, configure AutoLogon
    .\cape_guest_prep.ps1 -CapeHostIP 192.168.122.1 `
        -AutoLogonUser "analyst" -AutoLogonPassword "P@ssw0rd"

    # Custom Python version, no reboot
    .\cape_guest_prep.ps1 -PythonVersion 3.12.0 -NoReboot

.NOTES
    Run from an elevated (Run as Administrator) PowerShell prompt.
    After the script and reboot, verify the agent is reachable from the host:
        curl http://<GUEST_IP>:8000
    If it responds, save a KVM snapshot:
        virsh snapshot-create-as --domain cuckoo1 --name clean --disk-only=false
#>

#Requires -RunAsAdministrator

param(
    [string] $CapeHostIP        = "",
    [int]    $AgentServerPort   = 9000,
    [string] $PythonVersion     = "3.11.9",
    [string] $AgentDest         = "C:\Windows\agent.pyw",
    [string] $TaskName          = "pizza",
    [string] $AutoLogonUser     = "",
    [string] $AutoLogonPassword = "",
    [switch] $NoReboot
)

$ErrorActionPreference = "Continue"

# ---- Helpers ----------------------------------------------------------------

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host ">>> $Text" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Text)
    Write-Host "    [OK]  $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "    [!!]  $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Text)
    Write-Host "    [ERR] $Text" -ForegroundColor Red
}

function Set-RegDWord {
    param([string]$Path, [string]$Name, [int]$Value)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord -Force
}

# ---- Python -----------------------------------------------------------------

Write-Step "Python $PythonVersion x86 installation"

$pyUrl  = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion.exe"
$pyInst = "$env:TEMP\python-$PythonVersion-x86.exe"

Write-Host "    Downloading from $pyUrl ..."
try {
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($pyUrl, $pyInst)
    Write-OK "Downloaded to $pyInst"
} catch {
    Write-Fail "Download failed: $_"
    Write-Fail "Place python-$PythonVersion.exe (x86) at $pyInst manually, then re-run."
    exit 1
}

Write-Host "    Installing (silent, all users, add to PATH) ..."
$installArgs = "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0"
Start-Process -FilePath $pyInst -ArgumentList $installArgs -Wait -NoNewWindow
Write-OK "Python $PythonVersion installed."

# Remove the WindowsApps entry from the system PATH. It can shadow python.exe
# on Windows 10/11 and redirect the call to the Store stub.
$syspath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
$cleaned = ($syspath -split ";" | Where-Object { $_ -notmatch "WindowsApps" }) -join ";"
[System.Environment]::SetEnvironmentVariable("PATH", $cleaned, "Machine")

# Refresh the current session so pip works immediately
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("PATH", "User")

Write-Host "    Installing Pillow ..."
$pyExe = ((Get-Command python.exe -ErrorAction SilentlyContinue) | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
if (-not $pyExe) { $pyExe = "python" }

& $pyExe -m pip install --upgrade pip --quiet 2>&1 | Out-Null
& $pyExe -m pip install Pillow --quiet
Write-OK "Pillow installed."

# ---- Agent ------------------------------------------------------------------

Write-Step "CAPE agent"

if ($CapeHostIP -ne "") {
    # Serve agent from the host before running this script:
    #   python3 -m http.server 9000 --directory /opt/CAPEv2/agent/
    $agentUrl = "http://${CapeHostIP}:${AgentServerPort}/agent.py"
    Write-Host "    Downloading from $agentUrl ..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($agentUrl, $AgentDest)
        Write-OK "Downloaded agent to $AgentDest"
    } catch {
        Write-Fail "Could not fetch $agentUrl : $_"
        Write-Fail "Verify the file server is running on the CAPE host:"
        Write-Fail "  python3 -m http.server $AgentServerPort --directory /opt/CAPEv2/agent/"
        exit 1
    }
} else {
    # Look for agent.pyw or agent.py next to this script
    $localPyw = Join-Path $PSScriptRoot "agent.pyw"
    $localPy  = Join-Path $PSScriptRoot "agent.py"

    if (Test-Path $localPyw) {
        Copy-Item $localPyw $AgentDest -Force
        Write-OK "Copied $localPyw to $AgentDest"
    } elseif (Test-Path $localPy) {
        Copy-Item $localPy $AgentDest -Force
        Write-OK "Copied $localPy to $AgentDest"
    } else {
        Write-Fail "No agent found next to this script and -CapeHostIP was not given."
        Write-Fail "Either place agent.pyw at $AgentDest or pass -CapeHostIP."
        exit 1
    }
}

# Rename to .pyw to suppress the Python console window.
# An open cmd window interferes with human.py and breaks behavioral analysis.
if ($AgentDest -notmatch "\.pyw$") {
    $newDest = [System.IO.Path]::ChangeExtension($AgentDest, ".pyw")
    Move-Item $AgentDest $newDest -Force
    $AgentDest = $newDest
    Write-OK "Renamed to $AgentDest (.pyw suppresses the console window)."
}

# ---- Scheduled task ---------------------------------------------------------

Write-Step "Scheduled task '$TaskName'"

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# Prefer the just-installed Python interpreter; fall back to Windows py.exe launcher
$pyPath = ((Get-Command python.exe -ErrorAction SilentlyContinue) | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
if (-not $pyPath -or -not (Test-Path $pyPath)) {
    $pyPath = "C:\Windows\py.exe"
}

$action    = New-ScheduledTaskAction -Execute $pyPath -Argument "`"$AgentDest`""
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0)  # No timeout
$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -RunLevel Highest `
    -LogonType ServiceAccount

Register-ScheduledTask -TaskName $TaskName `
    -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Force | Out-Null

Write-OK "Task '$TaskName' registered (SYSTEM, highest privileges, at logon)."

# ---- Windows Defender -------------------------------------------------------

Write-Step "Windows Defender and Tamper Protection"

# Tamper Protection blocks Set-MpPreference on Windows 10 21H2+.
# Disable it via registry first. This only works when Tamper Protection
# is not enforced by Intune/MDM. On a fresh local VM it is writable.
Set-RegDWord "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features" "TamperProtection" 4
Write-OK "Tamper Protection disabled via registry."

try {
    Set-MpPreference -DisableRealtimeMonitoring    $true
    Set-MpPreference -DisableBehaviorMonitoring    $true
    Set-MpPreference -DisableIOAVProtection        $true
    Set-MpPreference -DisableScriptScanning        $true
    Set-MpPreference -DisableBlockAtFirstSeen      $true
    Set-MpPreference -SubmitSamplesConsent         2   # Never
    Set-MpPreference -MAPSReporting                0   # Disabled
    Set-MpPreference -SignatureDisableUpdateOnStartupWithoutEngine $true
    Write-OK "Windows Defender real-time protection disabled."
} catch {
    Write-Warn "Set-MpPreference failed, applying registry fallback: $_"
    Set-RegDWord "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" "DisableAntiSpyware" 1
    Set-RegDWord "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" "DisableRealtimeMonitoring" 1
}

# SmartScreen
Set-RegDWord "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" "EnableSmartScreen" 0
Set-RegDWord "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" "SmartScreenEnabled" 0
Write-OK "SmartScreen disabled."

# ---- Windows Firewall -------------------------------------------------------

Write-Step "Windows Firewall"

try {
    netsh advfirewall set allprofiles state off | Out-Null
    Write-OK "Firewall disabled on all profiles."
} catch {
    Write-Warn "netsh failed: $_"
    Set-RegDWord "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\StandardProfile" "EnableFirewall" 0
    Set-RegDWord "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\DomainProfile"   "EnableFirewall" 0
}

# ---- Windows Update ---------------------------------------------------------

Write-Step "Windows Update"

$wuauPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
New-Item -Path $wuauPath -Force | Out-Null
Set-RegDWord $wuauPath "NoAutoUpdate"             1
Set-RegDWord $wuauPath "AUOptions"                1   # Never check for updates
Set-RegDWord $wuauPath "NoAutoRebootWithLoggedOnUsers" 1

Stop-Service -Name wuauserv    -Force -ErrorAction SilentlyContinue
Set-Service  -Name wuauserv    -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service -Name UsoSvc      -Force -ErrorAction SilentlyContinue
Set-Service  -Name UsoSvc      -StartupType Disabled -ErrorAction SilentlyContinue

Write-OK "Windows Update disabled."

# ---- UAC --------------------------------------------------------------------

Write-Step "UAC"

Set-RegDWord "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "EnableLUA"                      0
Set-RegDWord "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "ConsentPromptBehaviorAdmin"     0
Set-RegDWord "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" "PromptOnSecureDesktop"         0
Write-OK "UAC set to never notify (takes effect after reboot)."

# ---- Windows Error Reporting ------------------------------------------------

Write-Step "Windows Error Reporting"

$werPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
New-Item -Path $werPath -Force | Out-Null
Set-RegDWord $werPath "Disabled"              1
Set-RegDWord $werPath "DontSendAdditionalData" 1

Stop-Service -Name WerSvc  -Force -ErrorAction SilentlyContinue
Set-Service  -Name WerSvc  -StartupType Disabled -ErrorAction SilentlyContinue

try {
    Disable-WindowsErrorReporting -ErrorAction SilentlyContinue | Out-Null
} catch {}

Write-OK "Windows Error Reporting disabled."

# ---- Network noise ----------------------------------------------------------

Write-Step "Network noise reduction (NCSI, LLMNR, Teredo)"

# NCSI - probes connectivity.microsoft.com every time the network state changes.
# These probes appear in PCAP captures and can confuse behavioral analysis.
$ncsiPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetworkConnectivityStatusIndicator"
New-Item -Path $ncsiPath -Force | Out-Null
Set-RegDWord $ncsiPath "NoActiveProbe" 1

# LLMNR - local multicast name resolution. Broadcasts appear in PCAP.
$dnsPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
New-Item -Path $dnsPath -Force | Out-Null
Set-RegDWord $dnsPath "EnableMulticast" 0

# Teredo - IPv6 tunneling. Creates tunnelled traffic in PCAP.
try {
    netsh interface teredo set state disabled | Out-Null
    Write-OK "Teredo disabled."
} catch {
    Write-Warn "netsh teredo disable failed: $_"
}

Write-OK "NCSI and LLMNR disabled."

# ---- Telemetry --------------------------------------------------------------

Write-Step "Telemetry and DiagTrack"

$dcPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
New-Item -Path $dcPath -Force | Out-Null
Set-RegDWord $dcPath "AllowTelemetry" 0

Stop-Service -Name DiagTrack    -Force -ErrorAction SilentlyContinue
Set-Service  -Name DiagTrack    -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service -Name dmwappushservice -Force -ErrorAction SilentlyContinue
Set-Service  -Name dmwappushservice -StartupType Disabled -ErrorAction SilentlyContinue

Write-OK "Telemetry and DiagTrack disabled."

# ---- Power plan -------------------------------------------------------------

Write-Step "Power plan"

powercfg /setactive SCHEME_MIN 2>&1 | Out-Null
powercfg /change monitor-timeout-ac  0 2>&1 | Out-Null
powercfg /change monitor-timeout-dc  0 2>&1 | Out-Null
powercfg /change standby-timeout-ac  0 2>&1 | Out-Null
powercfg /change standby-timeout-dc  0 2>&1 | Out-Null
powercfg /change hibernate-timeout-ac 0 2>&1 | Out-Null
Write-OK "High performance, sleep and display timeout disabled."

# ---- AutoLogon (optional) ---------------------------------------------------

if ($AutoLogonUser -ne "") {
    Write-Step "AutoLogon for '$AutoLogonUser'"
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $regPath -Name "AutoAdminLogon"  -Value "1"
    Set-ItemProperty -Path $regPath -Name "DefaultUserName" -Value $AutoLogonUser
    Set-ItemProperty -Path $regPath -Name "DefaultPassword" -Value $AutoLogonPassword
    Set-ItemProperty -Path $regPath -Name "ForceAutoLogon"  -Value "1"
    Write-OK "AutoLogon configured for $AutoLogonUser."
} else {
    Write-Host ""
    Write-Host "    AutoLogon not configured. To enable it later:" -ForegroundColor DarkGray
    Write-Host "      .\cape_guest_prep.ps1 -AutoLogonUser analyst -AutoLogonPassword YourPassword" -ForegroundColor DarkGray
}

# ---- Summary ----------------------------------------------------------------

$pyVer = (& $pyExe --version 2>&1) -replace "Python ", ""

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  Guest preparation complete." -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Python      : $pyVer (x86)"
Write-Host "  Agent       : $AgentDest"
Write-Host "  Task        : $TaskName (SYSTEM, at logon, highest privileges)"
Write-Host ""
Write-Host "  Before saving the snapshot:" -ForegroundColor Yellow
Write-Host "    1. Reboot and log in once to verify the agent starts."
Write-Host "    2. From the CAPE host, test the agent:"
Write-Host "         curl http://<GUEST_IP>:8000"
Write-Host "       You should see a JSON response with status 'ok'."
Write-Host "    3. If the agent responds, save the snapshot from the host:"
Write-Host "         virsh snapshot-create-as --domain cuckoo1 --name clean"
Write-Host ""

if (-not $NoReboot) {
    Write-Host "  Rebooting in 30 seconds. Press Ctrl+C to cancel." -ForegroundColor Yellow
    Start-Sleep -Seconds 30
    Restart-Computer -Force
}
