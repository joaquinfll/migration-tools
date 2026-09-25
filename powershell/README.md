# Windows Migration Checks — PowerShell

Standalone PowerShell reimplementation of the Windows Ansible playbooks.

Run these scripts **locally on the Windows VM** as Administrator. No Ansible or WinRM is required.

## Requirements

| Requirement | Notes |
|---|---|
| Windows Server 2008 R2 / Windows 7 or later | Same minimum as virt-v2v |
| PowerShell 5.1+ | Built into supported Windows releases |
| Administrator | Required for BitLocker, BCD, VSS, Secure Boot, and service checks |

## Files

| File | Purpose |
|---|---|
| `MigrationChecks.Common.psm1` | Shared helpers (reporting, service state, NIC inventory) |
| `Invoke-PreMigrationCheck.ps1` | Pre-migration checks (VM still on VMware) |
| `Invoke-PostMigrationCheck.ps1` | Post-migration validation (VM on KVM) |

## Usage

Copy the `powershell` directory to the target VM, then run from an elevated PowerShell session:

### Pre-migration (before virt-v2v)

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\Scripts\migration-tools\powershell
.\Invoke-PreMigrationCheck.ps1
```

Optional JSON report:

```powershell
.\Invoke-PreMigrationCheck.ps1 -JsonOutput C:\Temp\pre-migration-report.json
```

### Post-migration (after boot on KVM)

```powershell
.\Invoke-PostMigrationCheck.ps1
```

With inventory hostname validation and JSON output:

```powershell
.\Invoke-PostMigrationCheck.ps1 -ExpectedHostname winvm -JsonOutput C:\Temp\post-migration-report.json
```

Validate preserved IP(s) and firmware UUID (optional; skipped when omitted):

```powershell
.\Invoke-PostMigrationCheck.ps1 -ExpectedIp 10.0.1.50

.\Invoke-PostMigrationCheck.ps1 -ExpectedIps 10.0.1.50,10.0.1.51

.\Invoke-PostMigrationCheck.ps1 `
  -ExpectedHostname winvm `
  -ExpectedIp 10.0.1.50 `
  -ExpectedFirmwareUuid '4235A1B2-C3D4-5678-9ABC-DEF012345678' `
  -JsonOutput C:\Temp\post-migration-report.json
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | All checks passed |
| `1` | One or more checks failed (see console output) |

Optional `-JsonOutput` writes the same consolidated report to a JSON file (exit code is unchanged).

## Check parity

These scripts mirror the same **guest-local** checks, severities, and failure aggregation as:

- `pre-migration-windows.yml`
- `post-migration-windows.yml`

Informational tasks (disk/NIC inventory, domain membership, activation type warnings, pending updates, current SMBIOS UUID) are logged but do not fail the run unless the Ansible playbook also treats them as failures.

The post-migration **EDR blocking QEMU-GA** check runs only when the QEMU-GA service check fails, matching the Ansible `when:` condition.

### Ansible-only checks (not in these scripts)

These playbook tasks use `delegate_to: localhost` and tools that are not available on the Windows guest, so they remain Ansible-only:

| Check | Why guest scripts cannot run it |
|---|---|
| Target namespace ResourceQuota | Requires `oc` and `target_namespace` on the control node |
| Pre-existing vCenter snapshots | Requires `govc` and `vcenter_*` credentials on the control node |

Run the Ansible playbooks from a host with those tools when you need ResourceQuota or vCenter snapshot validation.

## Lint

Run [PSScriptAnalyzer](https://github.com/PowerShell/PSScriptAnalyzer) against the scripts:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path .\powershell -Recurse -Settings PSGallery
```

On macOS/Linux (portable PowerShell):

```bash
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./powershell -Recurse -Settings PSGallery"
```
