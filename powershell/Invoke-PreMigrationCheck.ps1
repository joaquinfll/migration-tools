#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-migration checks for a Windows VM still on VMware vSphere.

.DESCRIPTION
    PowerShell reimplementation of pre-migration-windows.yml.
    Run locally on the target VM as Administrator before virt-v2v conversion.
    Every check runs regardless of individual failures; a consolidated report
    is printed at the end. Exit code 0 = all checks passed, 1 = one or more failed.

.EXAMPLE
    .\Invoke-PreMigrationCheck.ps1

.EXAMPLE
    .\Invoke-PreMigrationCheck.ps1 -JsonOutput C:\Temp\pre-migration-report.json
#>
[CmdletBinding()]
param(
    [string]$JsonOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'MigrationChecks.Common.psm1'
Import-Module $modulePath -Force

if (-not (Test-Administrator)) {
    Write-Error 'This script must be run as Administrator.'
    exit 1
}

try {
    Assert-MigrationPlatform -Expected VMware
} catch {
    Write-Error $_
    exit 1
}

$results = @()

Write-MigrationInfo (Get-WindowsOsCaption)

# ============ CRITICAL: BitLocker encryption ============

$bitlockerVolumes = @()
try {
    $bitlockerVolumes = @(Get-BitLockerVolume -ErrorAction SilentlyContinue |
        Where-Object { $_.VolumeStatus -ne 'FullyDecrypted' })
} catch {
    # BitLocker cmdlet unavailable on some SKUs — treat as no encrypted volumes.
}

$bitlockerDetail = ($bitlockerVolumes | ForEach-Object { $_.MountPoint }) -join ', '
$results += New-MigrationCheckResult -Severity CRITICAL -Name 'BitLocker' -Passed (
    $bitlockerVolumes.Count -eq 0
) -Message "BitLocker encrypted volumes detected — virt-v2v cannot read encrypted volumes: $bitlockerDetail"

# ============ CRITICAL: Dynamic disks ============

$dynamicDisks = @(Get-Disk -ErrorAction SilentlyContinue |
    Where-Object { $_.PartitionStyle -eq 'Dynamic' })
$dynamicDetail = $(if ($dynamicDisks) {
    'Disk(s): ' + (($dynamicDisks.Number | ForEach-Object { $_.ToString() }) -join ', ')
} else { '' })

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'Dynamic disks' -Passed (
    $dynamicDisks.Count -eq 0
) -Message "Dynamic disks detected — virt-v2v only supports Basic disk layout: $dynamicDetail"

# ============ CRITICAL: ReFS volumes ============

$refsVolumes = @(Get-Volume -ErrorAction SilentlyContinue |
    Where-Object { $_.FileSystem -eq 'ReFS' })
$refsDetail = ($refsVolumes | ForEach-Object { $_.DriveLetter } | Where-Object { $_ }) -join ', '

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'ReFS volumes' -Passed (
    $refsVolumes.Count -eq 0
) -Message "ReFS volumes detected — virt-v2v has no ReFS support: $refsDetail"

# ============ CRITICAL: Windows version compatibility ============

$ntVersion = Get-WindowsNtVersion
Write-MigrationInfo "Windows version: $ntVersion"
$results += New-MigrationCheckResult -Severity CRITICAL -Name 'Windows version' -Passed (
    $ntVersion -ge [Version]'6.1'
) -Message 'Windows version is below minimum (6.1 / Windows 7 / Server 2008 R2) supported by virt-v2v'

# ============ CRITICAL: Secure Boot ============

$secureBootState = 'unavailable'
try {
    $secureBootState = $(if (Confirm-SecureBootUEFI -ErrorAction Stop) { 'enabled' } else { 'disabled' })
} catch [System.PlatformNotSupportedException] {
} catch [System.UnauthorizedAccessException] {
}

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'Secure Boot' -Passed (
    $secureBootState -ne 'enabled'
) -Message 'Secure Boot is enabled — virtio drivers must be signed for the target platform'

# ============ CRITICAL: Pending reboot ============

$rebootPending = $false
$rebootKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
)
foreach ($key in $rebootKeys) {
    if (Test-Path $key) { $rebootPending = $true }
}
$pfro = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
    -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
if ($pfro) { $rebootPending = $true }

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'Pending reboot' -Passed (-not $rebootPending) `
    -Message 'System has a pending reboot — resolve before migration to avoid inconsistent disk state'

# ============ CRITICAL: BCD store integrity ============

$bcdOutput = bcdedit /enum all 2>&1 | Out-String
$bcdFailed = $LASTEXITCODE -ne 0
$bcdDetail = $(if ($bcdFailed) { "BCD error: $bcdOutput" } else { '' })

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'BCD store' -Passed (-not $bcdFailed) `
    -Message 'BCD store integrity check failed — boot configuration may be corrupt' -Detail $bcdDetail

# ============ HIGH: VMware Tools installed ============

$vmtoolsSvc = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
$results += New-MigrationCheckResult -Severity HIGH -Name 'VMware Tools absent' -Passed (
    $null -ne $vmtoolsSvc
) -Message 'VMware Tools is not installed — virt-v2v cannot perform clean driver removal'

$vmtoolsState = Get-ServiceState -ServiceName 'VMTools'
Write-MigrationInfo "VMTools state: $vmtoolsState"
$results += New-MigrationCheckResult -Severity HIGH -Name 'VMware Tools service' -Passed (
    $vmtoolsState -eq 'running'
) -Message 'VMware Tools service (VMTools) is not in running state'

$vmwareDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceName -match 'VMware' } |
    Select-Object -ExpandProperty DeviceName -Unique)
$driverText = $(if ($vmwareDrivers) { $vmwareDrivers -join ', ' } else { 'none' })
Write-MigrationInfo "VMware drivers present: $driverText"

# ============ HIGH: Windows activation type (informational) ============

$activationResult = cscript //NoLogo "$env:SystemRoot\system32\slmgr.vbs" /dli 2>&1 | Out-String
$activationType = $(if ($activationResult -match 'KMS') {
    'KMS'
} elseif ($activationResult -match 'MAK|Retail|OEM') {
    'MAK/Retail/OEM'
} else {
    'Unknown'
})

if ($activationType -eq 'KMS') {
    Write-MigrationInfo "Activation type: KMS — KMS will require re-activation after migration (hypervisor UUID changes)"
}

# ============ HIGH: VMware NSX / vShield agent ============

$nsxServices = @(Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'vsepflt|vnetflt|nsx|VShield' })
$nsxDetail = ($nsxServices | ForEach-Object { $_.Name }) -join ', '

$results += New-MigrationCheckResult -Severity HIGH -Name 'NSX/vShield agent' -Passed (
    $nsxServices.Count -eq 0
) -Message "VMware NSX or vShield agent detected — will break network on KVM: $nsxDetail"

# ============ HIGH: VMware Horizon / VDI agent ============

$horizonPackages = @(Get-Package -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'Horizon|VMware View|ViewAgent' })
$horizonDetail = ($horizonPackages | ForEach-Object { $_.Name }) -join ', '

$results += New-MigrationCheckResult -Severity HIGH -Name 'Horizon/VDI agent' -Passed (
    $horizonPackages.Count -eq 0
) -Message "VMware Horizon or View agent detected — non-functional on KVM: $horizonDetail"

# ============ HIGH: EDR / AV agent detection ============

$edrRunning = @(Get-RunningServiceName -ServiceNames (Get-EdrServiceName))
$edrDetail = $edrRunning -join ', '

$results += New-MigrationCheckResult -Severity HIGH -Name 'EDR/AV agent' -Passed (
    $edrRunning.Count -eq 0
) -Message "EDR/AV service running — may block virt-v2v conversion and QEMU-GA install post-migration. Add qemu-ga.exe to EDR allow-list before migrating: $edrDetail"

# ============ HIGH: Running databases ============

$dbRunning = @(Get-RunningServiceName -ServiceNames (Get-PreMigrationDatabaseServiceName))
$dbDetail = $dbRunning -join ', '
if ($dbRunning.Count -gt 0) {
    Write-MigrationInfo "Database service(s) running: $dbDetail"
}

$results += New-MigrationCheckResult -Severity HIGH -Name 'Running databases' -Passed (
    $dbRunning.Count -eq 0
) -Message 'Database services are running without a quiesce plan — risk of data corruption'

# ============ HIGH: C: drive free space ============

$cDrive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
$cFreeGb = $(if ($cDrive) { [math]::Round($cDrive.Free / 1GB, 2) } else { 0 })
Write-MigrationInfo "C: free space: $cFreeGb GB"

$results += New-MigrationCheckResult -Severity HIGH -Name 'C: drive space' -Passed (
    $cFreeGb -ge 2
) -Message "C: drive has less than 2 GB free — insufficient for virt-v2v conversion workspace"

# ============ HIGH: VSS health ============

$vssSvc = Get-Service -Name VSS -ErrorAction SilentlyContinue
$vssDisabled = $vssSvc -and $vssSvc.StartType -eq 'Disabled'

$results += New-MigrationCheckResult -Severity HIGH -Name 'VSS service disabled' -Passed (-not $vssDisabled) `
    -Message 'VSS service StartType is Disabled — virt-v2v cannot take a shadow copy snapshot'

$vssOut = vssadmin list writers 2>&1 | Out-String
$vssBad = @()
$blocks = $vssOut -split '(?=Writer name:)'
foreach ($block in $blocks) {
    $name = $(if ($block -match "Writer name:\s*'?(.+?)'?\r?\n") { $Matches[1].Trim() } else { $null })
    $err = $(if ($block -match 'Last error:\s*(.+?)\r?\n') { $Matches[1].Trim() } else { $null })
    if ($name -and $err -and $err -notmatch '^No error') {
        $vssBad += "$name ($err)"
    }
}
$vssBadDetail = $vssBad -join '; '

$vssWriterSummary = vssadmin list writers 2>&1 |
    Select-String -Pattern 'Writer name:|State:|Last error:'
if ($vssWriterSummary) {
    Write-MigrationInfo "VSS writer summary:`n$($vssWriterSummary -join "`n")"
}

$results += New-MigrationCheckResult -Severity HIGH -Name 'VSS writers' -Passed (
    $vssBad.Count -eq 0
) -Message "One or more VSS writers are in a non-stable state: $vssBadDetail"

$vssProviders = vssadmin list providers 2>&1 | Out-String
$vssProviderMissing = $vssProviders -notmatch 'Microsoft Software Shadow Copy provider'

$results += New-MigrationCheckResult -Severity HIGH -Name 'VSS provider missing' -Passed (-not $vssProviderMissing) `
    -Message 'Microsoft Software Shadow Copy provider is not registered — shadow copy creation will fail'

# ============ MEDIUM: Hyper-V role ============

$hypervInstalled = $false
try {
    $hv = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
    $hypervInstalled = $hv -and $hv.InstallState -eq 'Installed'
} catch {
    # Client SKUs or Server Core without ServerManager — check optional feature name.
    $optional = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All `
        -ErrorAction SilentlyContinue
    if ($optional -and $optional.State -eq 'Enabled') {
        $hypervInstalled = $true
    }
}

$results += New-MigrationCheckResult -Severity MEDIUM -Name 'Hyper-V role' -Passed (-not $hypervInstalled) `
    -Message 'Hyper-V role is installed — conflicts with KVM unless nested virtualization is explicitly configured'

# ============ MEDIUM: Static IP configuration (informational) ============

$staticIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.PrefixOrigin -eq 'Manual' })
$staticIpText = ($staticIps | ForEach-Object { $_.IPAddress }) -join ', '
if ($staticIpText) {
    Write-MigrationInfo "Static IPs found: $staticIpText — verify NIC mapping in KubeVirt VM spec"
}

# ============ MEDIUM: Partition table type (MBR) ============

$mbrDisks = @(Get-Disk -ErrorAction SilentlyContinue |
    Where-Object { $_.PartitionStyle -eq 'MBR' })
$mbrDetail = $(if ($mbrDisks) {
    'MBR disks: ' + (($mbrDisks.Number | ForEach-Object { $_.ToString() }) -join ', ')
} else { '' })

$results += New-MigrationCheckResult -Severity MEDIUM -Name 'Partition table (MBR)' -Passed (
    $mbrDisks.Count -eq 0
) -Message "MBR partition table detected — $mbrDetail"

# ============ MEDIUM: Pending Windows updates (informational) ============

try {
    $updateSession = New-Object -ComObject Microsoft.Update.Session
    $pendingUpdates = ($updateSession.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')).Updates.Count
    if ($pendingUpdates -gt 0) {
        Write-MigrationInfo "Pending Windows updates: $pendingUpdates"
    }
} catch {
    Write-MigrationInfo 'Pending Windows updates: unavailable (COM search failed)'
}

# ============ MEDIUM: Domain membership (informational) ============

$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
if ($computerSystem.PartOfDomain) {
    Write-MigrationInfo "Domain: $($computerSystem.Domain)"
} else {
    Write-MigrationInfo "Workgroup: $($computerSystem.Workgroup)"
}

# ============ MEDIUM: Page file configuration (informational) ============

$pageFiles = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue)
$pageFileText = $(if ($pageFiles) { ($pageFiles | ForEach-Object { $_.Name }) -join ', ' } else { 'System managed' })
Write-MigrationInfo "Page file(s): $pageFileText"

# ============ LOW: RDP enabled ============

$rdpValue = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
$rdpEnabled = ($rdpValue -eq 0)

$results += New-MigrationCheckResult -Severity LOW -Name 'RDP disabled' -Passed $rdpEnabled `
    -Message 'RDP is disabled — remote access will not be available after migration'

# ============ INFO: VMware registry keys ============

$vmwareRegistry = $(if (Test-Path 'HKLM:\SOFTWARE\VMware, Inc.') { 'found' } else { 'absent' })
Write-MigrationInfo "VMware registry keys (HKLM:\SOFTWARE\VMware, Inc.): $vmwareRegistry"

# ============ INFO: Disk inventory ============

$diskLines = @(Get-Disk -ErrorAction SilentlyContinue | ForEach-Object {
    "Disk $($_.Number): $([math]::Round($_.Size / 1GB, 1)) GB — $($_.PartitionStyle) — $($_.OperationalStatus)"
})
if ($diskLines) {
    Write-MigrationInfo "Disk inventory:`n$($diskLines -join "`n")"
}

# ============ INFO: NIC inventory ============

$nicLines = @(Get-NicInventory)
Write-MigrationInfo "NICs (excluding loopback): $($nicLines.Count)"
if ($nicLines) {
    Write-MigrationInfo "NIC details:`n$($nicLines -join "`n")"
}
if ($nicLines.Count -gt 1) {
    Write-MigrationWarning "$($nicLines.Count) NICs detected — ensure all are mapped to target networks in KubeVirt VM spec"
}

# ============ AGGREGATION ============

if ($JsonOutput) {
    Export-MigrationCheckReport -Results $results -Path $JsonOutput
    Write-MigrationInfo "JSON report written to $JsonOutput"
}

$exitCode = Write-MigrationCheckReport -Results $results -FailureSummary @'
Windows pre-migration checks failed. One or more checks reported issues above.
Please resolve all failures before proceeding with virt-v2v conversion.
'@

exit $exitCode