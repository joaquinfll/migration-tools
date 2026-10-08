#Requires -Version 5.1
<#
.SYNOPSIS
    Post-migration validation for a Windows VM on KVM / OpenShift Virtualization.

.DESCRIPTION
    PowerShell reimplementation of post-migration-windows.yml.
    Run locally on the target VM as Administrator after virt-v2v conversion.
    Every check runs regardless of individual failures; a consolidated report
    is printed at the end. Exit code 0 = all checks passed, 1 = one or more failed.

.PARAMETER ExpectedHostname
    Optional inventory hostname (short name, without domain) for the hostname match check.
    When omitted, the hostname check is skipped.

.PARAMETER ExpectedIp
    Optional single IPv4 address that must still be present after migration.
    When omitted, the Static IP lost check is skipped.

.PARAMETER ExpectedIps
    Optional list of IPv4 addresses that must still be present after migration.
    When omitted, the Static IPs lost check is skipped.

.PARAMETER ExpectedFirmwareUuid
    Optional SMBIOS/firmware UUID from the source VMware VM.
    When omitted, the Firmware UUID mismatch check is skipped.

.EXAMPLE
    .\Invoke-PostMigrationCheck.ps1

.EXAMPLE
    .\Invoke-PostMigrationCheck.ps1 -ExpectedHostname winvm -JsonOutput C:\Temp\post-migration-report.json

.EXAMPLE
    .\Invoke-PostMigrationCheck.ps1 -ExpectedIp 10.0.1.50 -ExpectedFirmwareUuid '4235A1B2-C3D4-5678-9ABC-DEF012345678'

.EXAMPLE
    .\Invoke-PostMigrationCheck.ps1 -ExpectedIps 10.0.1.50,10.0.1.51
#>
[CmdletBinding()]
param(
    [string]$ExpectedHostname,

    [string]$ExpectedIp,

    [string[]]$ExpectedIps,

    [string]$ExpectedFirmwareUuid,

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
    Assert-MigrationPlatform -Expected KVM
} catch {
    Write-Error $_
    exit 1
}

$results = @()

Write-MigrationInfo (Get-WindowsOsCaption)

# ============ CRITICAL: VMware drivers must be absent ============

$vmwareActiveDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceName -match 'PVSCSI|VMXNET' -and $_.Status -eq 'OK' } |
    Select-Object -ExpandProperty DeviceName -Unique)
$vmwareDriverDetail = $vmwareActiveDrivers -join ', '

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'VMware drivers active' -Passed (
    $vmwareActiveDrivers.Count -eq 0
) -Message "VMware PVSCSI/VMXNET drivers still active: $vmwareDriverDetail"

# ============ CRITICAL: virtio-net (NetKVM) driver must be loaded ============

$virtioNics = @(Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -match 'Red Hat VirtIO' })

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'virtio-net (NetKVM)' -Passed (
    $virtioNics.Count -gt 0
) -Message 'No Red Hat VirtIO network adapter found -- VM has no virtio NIC'

$nicDriverLines = @(Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
    "$($_.Name): $($_.InterfaceDescription) [$($_.Status)]"
})
if ($nicDriverLines) {
    Write-MigrationInfo "NIC drivers:`n$($nicDriverLines -join "`n")"
}

$nicLines = @(Get-NicInventory)
Write-MigrationInfo "NICs (excluding loopback): $($nicLines.Count)"
if ($nicLines) {
    Write-MigrationInfo "NIC details:`n$($nicLines -join "`n")"
}
if ($nicLines.Count -gt 1) {
    Write-MigrationWarning "$($nicLines.Count) NICs detected -- ensure all are mapped to target networks in KubeVirt VM spec"
}

# ============ CRITICAL: virtio storage driver must be loaded ============

$virtioStorageDrivers = @(Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceName -match 'VirtIO SCSI|VirtIO Block|Red Hat VirtIO SCSI' } |
    Select-Object -ExpandProperty DeviceName -Unique)

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'virtio storage driver' -Passed (
    $virtioStorageDrivers.Count -gt 0
) -Message 'VirtIO SCSI or Block storage driver not found -- VM cannot access disk via virtio'

$diskLines = @(Get-Disk -ErrorAction SilentlyContinue | ForEach-Object {
    "Disk $($_.Number): $([math]::Round($_.Size / 1GB, 1)) GB -- $($_.PartitionStyle)"
})
if ($diskLines) {
    Write-MigrationInfo "Disk details:`n$($diskLines -join "`n")"
}

# ============ CRITICAL: VMware Tools must be uninstalled ============

$vmtoolsPackages = @(Get-Package -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'VMware Tools' })
$vmtoolsPackageDetail = ($vmtoolsPackages | ForEach-Object { $_.Name }) -join ', '

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'VMware Tools package' -Passed (
    $vmtoolsPackages.Count -eq 0
) -Message "VMware Tools is still installed: $vmtoolsPackageDetail"

$vmtoolsState = Get-ServiceState -ServiceName 'VMTools'
Write-MigrationInfo "VMTools service state: $vmtoolsState"

$results += New-MigrationCheckResult -Severity CRITICAL -Name 'VMware Tools service' -Passed (
    $vmtoolsState -ne 'running'
) -Message 'VMware Tools service (VMTools) is still running'

# ============ CRITICAL: C: drive must be accessible ============

$cAccessible = Test-Path 'C:/'
$results += New-MigrationCheckResult -Severity CRITICAL -Name 'C: drive inaccessible' -Passed $cAccessible `
    -Message 'C:\ drive is not accessible -- system volume may be unmounted or corrupt'

# ============ HIGH: QEMU Guest Agent must be installed and running ============

$qgaState = Get-ServiceState -ServiceName 'QEMU-GA'
Write-MigrationInfo "QEMU-GA service state: $qgaState"
$qgaPassed = ($qgaState -eq 'running')

$results += New-MigrationCheckResult -Severity HIGH -Name 'QEMU Guest Agent' -Passed $qgaPassed `
    -Message 'QEMU Guest Agent (QEMU-GA) is not installed or not running'

# ============ HIGH: EDR interference with QEMU Guest Agent ============
# Only evaluated when QEMU-GA check failed, matching the Ansible when: condition.

if (-not $qgaPassed) {
    $edrBlocking = @(Get-RunningServiceName -ServiceNames (Get-EdrServiceName))
    $edrDetail = $edrBlocking -join ', '

    $results += New-MigrationCheckResult -Severity HIGH -Name 'EDR blocking QEMU-GA' -Passed (
        $edrBlocking.Count -eq 0
    ) -Message "EDR/AV service is likely blocking QEMU-GA -- add qemu-ga.exe to the allow-list and reinstall: $edrDetail"
}

# ============ HIGH: No VMware services must be running ============

$vmwareRunningServices = @(Get-Service -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^VMware|^VMTools$|^VMUSBArbService$|^vm3dservice$' -and $_.Status -eq 'Running' })
$vmwareSvcDetail = ($vmwareRunningServices | ForEach-Object { $_.Name }) -join ', '

$results += New-MigrationCheckResult -Severity HIGH -Name 'VMware services running' -Passed (
    $vmwareRunningServices.Count -eq 0
) -Message "VMware services still running: $vmwareSvcDetail"

# ============ HIGH: VMware Tools artifacts must be absent ============

$vmwareToolsDirPresent = Test-Path 'C:/Program Files/VMware/VMware Tools'
$results += New-MigrationCheckResult -Severity HIGH -Name 'VMware Tools directory' -Passed (-not $vmwareToolsDirPresent) `
    -Message 'C:\Program Files\VMware\VMware Tools directory still present'

$vmwareRegistryPresent = Test-Path 'HKLM:\SOFTWARE\VMware, Inc.'
$results += New-MigrationCheckResult -Severity HIGH -Name 'VMware registry keys' -Passed (-not $vmwareRegistryPresent) `
    -Message 'VMware registry keys still present at HKLM:\SOFTWARE\VMware, Inc.'

# ============ HIGH: Windows activation status ============

$activationResult = cscript //NoLogo "$env:SystemRoot\system32\slmgr.vbs" /dli 2>&1 | Out-String
$licensed = $activationResult -match 'License Status: Licensed'

$results += New-MigrationCheckResult -Severity HIGH -Name 'Windows activation' -Passed $licensed `
    -Message 'Windows is not in Licensed state -- re-activation required (KMS UUID change)'

# ============ HIGH: Network connectivity ============

$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Select-Object -First 1
$defaultGateway = $(if ($defaultRoute) { $defaultRoute.NextHop } else { '' })

if ($defaultGateway) {
    Write-MigrationInfo "Default gateway: $defaultGateway"
}

$results += New-MigrationCheckResult -Severity HIGH -Name 'Default route' -Passed (
    [string]::IsNullOrWhiteSpace($defaultGateway) -eq $false
) -Message 'No default route found -- network may be misconfigured'

$ipv4Lines = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
    ForEach-Object { $_.IPAddress })
if ($ipv4Lines) {
    Write-MigrationInfo "IP addresses: $($ipv4Lines -join ', ')"
}

$dnsResolved = $null
try {
    $dnsResolved = Resolve-DnsName $env:COMPUTERNAME -ErrorAction Stop |
        Select-Object -First 1 -ExpandProperty IPAddress
} catch {
}

if ($dnsResolved) {
    Write-MigrationInfo "$env:COMPUTERNAME resolves to: $dnsResolved"
}

$results += New-MigrationCheckResult -Severity HIGH -Name 'DNS resolution' -Passed (
    [string]::IsNullOrWhiteSpace($dnsResolved) -eq $false
) -Message 'Hostname does not resolve -- DNS may be broken'

# ============ HIGH: No critical Event Log errors since boot ============

$eventErrorCount = 0
try {
    $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    $eventErrorCount = (Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Level     = 2  # Error
        StartTime = $bootTime
    } -ErrorAction SilentlyContinue | Measure-Object).Count
} catch {
    $eventErrorCount = 0
}

Write-MigrationInfo "System Event Log errors since last boot: $eventErrorCount"

$results += New-MigrationCheckResult -Severity HIGH -Name 'Event log errors' -Passed (
    $eventErrorCount -le 5
) -Message 'More than 5 System Event Log errors detected since last boot'

# ============ MEDIUM: Hostname matches inventory ============

if ($ExpectedHostname) {
    $actualHostname = $env:COMPUTERNAME
    $hostnameMatch = ($actualHostname.ToLower() -eq $ExpectedHostname.Split('.')[0].ToLower())

    $results += New-MigrationCheckResult -Severity MEDIUM -Name 'Hostname mismatch' -Passed $hostnameMatch `
        -Message "Hostname mismatch: computername=$actualHostname expected=$($ExpectedHostname.Split('.')[0])"
}

# ============ MEDIUM: C drive has sufficient free space ============

$cDrive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
$cFreeGb = $(if ($cDrive) { [math]::Round($cDrive.Free / 1GB, 2) } else { 0 })
$cUsedGb = $(if ($cDrive) { [math]::Round($cDrive.Used / 1GB, 1) } else { 0 })

Write-MigrationInfo "C: drive -- Used: $cUsedGb GB  Free: $cFreeGb GB"

$results += New-MigrationCheckResult -Severity MEDIUM -Name 'C: drive space' -Passed (
    $cFreeGb -ge 1
) -Message 'C: drive has less than 1 GB free post-migration'

# ============ MEDIUM: Time sync is active ============

$w32TimeState = Get-ServiceState -ServiceName 'W32Time'
Write-MigrationInfo "W32Time state: $w32TimeState"

$results += New-MigrationCheckResult -Severity MEDIUM -Name 'Time sync (W32Time)' -Passed (
    $w32TimeState -eq 'running'
) -Message 'Windows Time service is not running -- clock drift will break Kerberos and TLS'

# ============ MEDIUM: No VMware entries in BCD ============

$bcdOutput = bcdedit /enum all 2>&1 | Out-String
$bcdVmwareEntries = $bcdOutput -match 'vmware'

$results += New-MigrationCheckResult -Severity MEDIUM -Name 'BCD VMware artifacts' -Passed (-not $bcdVmwareEntries) `
    -Message 'VMware entries found in BCD store -- boot configuration may be contaminated'

# ============ LOW: virtio-serial device for QEMU Guest Agent channel ============

$virtioSerialDevices = @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'VirtIO Serial|QEMU.*Serial' })

$results += New-MigrationCheckResult -Severity LOW -Name 'virtio-serial channel' -Passed (
    $virtioSerialDevices.Count -gt 0
) -Message 'VirtIO serial device not found -- QEMU Guest Agent communication channel may not function'

# ============ LOW: RDP still enabled ============

$rdpValue = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections
$rdpEnabled = ($rdpValue -eq 0)

$results += New-MigrationCheckResult -Severity LOW -Name 'RDP disabled' -Passed $rdpEnabled `
    -Message 'RDP is disabled -- remote access is not available'

# ============ HIGH: Static IP preserved after migration ============
# LESSON LEARNED: ~90% of IP loss cases occurred when VMs were powered off
# before migration — VMware Tools cannot report guest network details to MTV
# when the VM is off. Always leave VMs powered on (stop application services only)
# and let MTV manage the power state.

if ($ExpectedIp) {
    $ipFound = $ipv4Lines -contains $ExpectedIp
    $results += New-MigrationCheckResult -Severity HIGH -Name 'Static IP lost' -Passed $ipFound `
        -Message "Expected IP not found after migration — source VM may have been powered off before migration. Expected: $ExpectedIp"
}

if ($PSBoundParameters.ContainsKey('ExpectedIps') -and $null -ne $ExpectedIps) {
    $expectedIpList = @($ExpectedIps)
    if ($expectedIpList.Count -gt 0) {
        $missingIps = @($expectedIpList | Where-Object { $ipv4Lines -notcontains $_ })
        $missingDetail = $missingIps -join ', '
        $results += New-MigrationCheckResult -Severity HIGH -Name 'Static IPs lost' -Passed (
            $missingIps.Count -eq 0
        ) -Message "One or more expected IPs missing after migration. Missing: $missingDetail"
    }
}

# ============ HIGH: Firmware UUID preserved for licence-bound applications ============
# LESSON LEARNED: Some application licences are tied to the VM's firmware/SMBIOS UUID.
# Fix: update spec.template.spec.domain.firmware.uuid in the KubeVirt VM YAML, then restart.

$currentUuid = ''
try {
    $csp = Get-CimInstance -ClassName Win32_ComputerSystemProduct -ErrorAction Stop
    if ($csp -and $csp.UUID) {
        $currentUuid = [string]$csp.UUID
    }
} catch {
    try {
        $csp = Get-WmiObject -Class Win32_ComputerSystemProduct -ErrorAction Stop
        if ($csp -and $csp.UUID) {
            $currentUuid = [string]$csp.UUID
        }
    } catch {
    }
}

if (-not [string]::IsNullOrWhiteSpace($currentUuid)) {
    Write-MigrationInfo "Current SMBIOS UUID: $($currentUuid.Trim().ToUpperInvariant())"
}

if ($ExpectedFirmwareUuid -and -not [string]::IsNullOrWhiteSpace($currentUuid)) {
    $uuidMatch = ($currentUuid.Trim().ToUpperInvariant() -eq $ExpectedFirmwareUuid.Trim().ToUpperInvariant())
    $results += New-MigrationCheckResult -Severity HIGH -Name 'Firmware UUID mismatch' -Passed $uuidMatch `
        -Message ("SMBIOS UUID does not match source VMware UUID — licence-bound applications may break. " +
            "Current: $($currentUuid.Trim().ToUpperInvariant()), Expected: $($ExpectedFirmwareUuid.Trim().ToUpperInvariant()). " +
            "Fix: update spec.template.spec.domain.firmware.uuid in the KubeVirt VM YAML, then restart the VM.")
}

# ============ HIGH: All volumes writable (not read-only) ============
# LESSON LEARNED: If the VMware Snapshot Provider (VSS) is disabled during warm
# migration, virt-v2v may leave volumes read-only after conversion.

$ro = @()
$fixedVolumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object {
    $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem
})
foreach ($vol in $fixedVolumes) {
    $testFile = "$($vol.DriveLetter):\.migration_write_test_$(Get-Random)"
    try {
        [IO.File]::WriteAllText($testFile, 'test')
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
    } catch {
        $ro += "$($vol.DriveLetter):"
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
    }
}
$roDetail = $ro -join ', '

$results += New-MigrationCheckResult -Severity HIGH -Name 'Read-only volumes' -Passed (
    $ro.Count -eq 0
) -Message "One or more volumes are read-only — may indicate failed filesystem quiescing during conversion (enable VMware Snapshot Provider before migration): $roDetail"

# ============ MEDIUM: Default gateway reachable via ICMP ============
# LESSON LEARNED: Incorrect CUDN VLAN configuration can prevent gateway
# connectivity even when IP settings appear correct inside the guest OS.

$gwPingDetail = ''
$gwReachable = $false
if ($defaultGateway) {
    try {
        $gwReachable = [bool](Test-Connection -ComputerName $defaultGateway -Count 2 -Quiet -ErrorAction SilentlyContinue)
    } catch {
        $gwReachable = $false
    }
    if (-not $gwReachable) {
        $gwPingDetail = "unreachable: $defaultGateway"
    }
} else {
    $gwPingDetail = 'no gateway'
}

$results += New-MigrationCheckResult -Severity MEDIUM -Name 'Gateway unreachable' -Passed $gwReachable `
    -Message "Default gateway is not reachable via ICMP ping — check CUDN VLAN configuration (vlan.mode/vlan.access.id in NAD YAML): $gwPingDetail"

# ============ AGGREGATION ============

if ($JsonOutput) {
    Export-MigrationCheckReport -Results $results -Path $JsonOutput
    Write-MigrationInfo "JSON report written to $JsonOutput"
}

$exitCode = Write-MigrationCheckReport -Results $results -FailureSummary @'
Windows post-migration validation failed. One or more checks reported issues above.
The VM may not be operating correctly on KVM/OpenShift Virtualization.
Please review and remediate all failures before putting the VM into production.
'@

exit $exitCode
