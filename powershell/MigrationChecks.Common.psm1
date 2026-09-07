# Shared helpers for Windows migration pre/post check scripts.
# Mirrors the aggregation pattern used in pre-migration-windows.yml and post-migration-windows.yml.

Set-StrictMode -Version Latest

$Script:EdrServiceNames = @(
    'CSFalconService'
    'CbDefense'
    'CarbonBlack'
    'SentinelAgent'
    'CylanceSvc'
    'SophosMcsAgent'
    'TmCCSF'
    'WinDefend'
)

$Script:PreMigrationDatabaseServices = @(
    'MSSQLSERVER'
    'MSExchangeIS'
    'MySQL'
    'OracleServiceORCL'
    'MongoDB'
)

$Script:InfoMessages = [System.Collections.Generic.List[PSCustomObject]]::new()

function New-MigrationCheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('CRITICAL', 'HIGH', 'MEDIUM', 'LOW')]
        [string]$Severity,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Passed,

        [string]$Message,

        [string]$Detail
    )

    [PSCustomObject]@{
        Severity = $Severity
        Label    = "[$Severity] $Name"
        Name     = $Name
        Passed   = $Passed
        Message  = $(if (-not $Passed) { if ($Message) { $Message } else { $Name } } else { $null })
        Detail   = $(if (-not $Passed) { $Detail } else { $null })
    }
}

function Write-MigrationInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $Script:InfoMessages.Add([PSCustomObject]@{ Level = 'INFO'; Text = $Message })
    Write-Host "INFO: $Message" -ForegroundColor Cyan
}

function Write-MigrationWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    $Script:InfoMessages.Add([PSCustomObject]@{ Level = 'WARNING'; Text = $Message })
    Write-Host "WARNING: $Message" -ForegroundColor Yellow
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-MigrationPlatform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('VMware', 'KVM')]
        [string]$Expected
    )

    try {
        $manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Manufacturer
    } catch {
        throw "Cannot determine platform: failed to query Win32_ComputerSystem. $_"
    }

    $isVmware = $manufacturer -match 'VMware'

    if ($Expected -eq 'VMware' -and -not $isVmware) {
        throw @"
Pre-migration checks are meant to be run on machines still running on VMware vSphere.
Detected platform: $manufacturer.
"@
    }

    if ($Expected -eq 'KVM' -and $isVmware) {
        throw @"
Post-migration checks are meant to be run on machines running on KVM/OpenShift Virtualization.
Detected platform: $manufacturer (still VMware).
"@
    }
}

function Get-WindowsNtVersion {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return [Version]$os.Version
}

function Get-WindowsOsCaption {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    return "$($os.Caption) $($os.Version)"
}

function Get-RunningServiceName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$ServiceNames
    )

    $running = @()
    foreach ($name in $ServiceNames) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $running += $name
        }
    }
    return $running
}

function Get-ServiceState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        return 'absent'
    }
    return $svc.Status.ToString().ToLower()
}

function Get-NicInventory {
    $lines = @()
    $nics = Get-NetAdapter -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceType -ne 24 }

    foreach ($nic in $nics) {
        $ip = Get-NetIPAddress -InterfaceIndex $nic.IfIndex -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
            Select-Object -First 1 -ExpandProperty IPAddress

        $ipText = $(if ($ip) { $ip } else { 'no-ip' })
        $lines += "$($nic.Name): mac=$($nic.MacAddress) ip=$ipText mtu=$($nic.ActiveMaximumTransmissionUnit) [$($nic.InterfaceDescription)]"
    }

    return $lines
}

function Write-MigrationCheckReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string]$FailureSummary
    )

    $failures = @($Results | Where-Object { -not $_.Passed })

    if ($failures.Count -eq 0) {
        Write-Host ''
        Write-Host 'All migration checks passed.' -ForegroundColor Green
        return 0
    }

    Write-Host ''
    Write-Host 'Failed migration checks:' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "$($failure.Label): $($failure.Message)" -ForegroundColor Red
    }

    Write-Host ''
    Write-Host $FailureSummary -ForegroundColor Red
    return 1
}

function Export-MigrationCheckReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $payload = [PSCustomObject]@{
        Timestamp = (Get-Date).ToString('o')
        Hostname  = $env:COMPUTERNAME
        Passed    = @($Results | Where-Object { $_.Passed }).Count
        Failed    = @($Results | Where-Object { -not $_.Passed }).Count
        Messages  = @($Script:InfoMessages)
        Results   = $Results
    }

    $payload | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

function Get-EdrServiceName {
    return @($Script:EdrServiceNames)
}

function Get-PreMigrationDatabaseServiceName {
    return @($Script:PreMigrationDatabaseServices)
}

Export-ModuleMember -Function @(
    'New-MigrationCheckResult'
    'Write-MigrationInfo'
    'Write-MigrationWarning'
    'Test-Administrator'
    'Assert-MigrationPlatform'
    'Get-WindowsNtVersion'
    'Get-WindowsOsCaption'
    'Get-RunningServiceName'
    'Get-ServiceState'
    'Get-NicInventory'
    'Write-MigrationCheckReport'
    'Export-MigrationCheckReport'
    'Get-EdrServiceName'
    'Get-PreMigrationDatabaseServiceName'
)
