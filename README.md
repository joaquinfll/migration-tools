# Migration Pre/Post Checks — Playbook Reference

Standalone Ansible playbooks for **Linux and Windows** VM migration from **VMware vSphere** to **KVM / OpenShift Virtualization**.
Each playbook validates the target hypervisor immediately after fact gathering — this **platform guard** hard-fails the play if run on the wrong platform. All other checks use `ignore_errors: true`, failures are collected into a single list, and a consolidated report is printed at the end before the play hard-fails.

---

## Prerequisites

| Requirement | Minimum version |
|---|---|
| ansible-core | 2.14 |
| Python (control node) | 3.9 |
| SSH access | Linux target VM must be reachable over SSH |
| WinRM access | Windows target VM must have WinRM enabled (HTTP port 5985 or HTTPS port 5986) |
| `ansible.windows` collection | ≥ 2.0.0 — required for Windows playbooks only |
| `community.vmware` collection | ≥ 6.2.0 — required for vSphere-only playbooks (`cbt-enable.yml`) |

Install Galaxy collections after cloning:

```bash
ansible-galaxy collection install -r requirements.yml
```

**RHEL 9 and 10** (AppStream — no extra repositories needed):

```bash
sudo dnf install ansible-core
```

**CentOS Stream / AlmaLinux / Rocky Linux** (EPEL required):

```bash
sudo dnf install epel-release
sudo dnf install ansible-core
```

**Ubuntu**:

```bash
sudo apt update
sudo apt install software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt install ansible
```


**Any OS** (pipx — keeps Ansible isolated from system Python):

```bash
pipx install ansible-core
```

All playbooks assert these requirements at runtime via `ansible.builtin.assert` before any checks execute.

**Supported guest OS families:**
- Linux playbooks: `RedHat` (RHEL, CentOS, Fedora) and `Debian` (Ubuntu, Debian).
- Windows playbooks: `Windows` (Windows Server 2008 R2 / Windows 7 and later).

Other OS families will fail the preflight assert.

---

## Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `immutable_files_list` | No | `['/etc/resolv.conf']` | List of file paths to inspect for the `chattr +i` immutable attribute before migration. Supply additional critical config files as needed. |

Override the default at invocation time:

```bash
ansible-playbook -i inventory pre-migration-linux.yml \
  -e '{"immutable_files_list": ["/etc/resolv.conf", "/etc/fstab", "/boot/grub2/grub.cfg"]}'
```

---

## Usage

### Pre-migration (VM still on VMware vSphere)

```bash
# Dry-run — simulate without connecting to the VM
ansible-playbook -i inventory pre-migration-linux.yml --check --diff

# Full run
ansible-playbook -i inventory pre-migration-linux.yml

# Limit to a single host
ansible-playbook -i inventory pre-migration-linux.yml --limit myvm.example.com

# With custom immutable file list
ansible-playbook -i inventory pre-migration-linux.yml \
  -e '{"immutable_files_list": ["/etc/resolv.conf", "/etc/fstab"]}'
```

### Post-migration (VM booted on KVM / OpenShift Virtualization)

```bash
# Dry-run
ansible-playbook -i inventory post-migration-linux.yml --check --diff

# Full run
ansible-playbook -i inventory post-migration-linux.yml

# Limit to a single host
ansible-playbook -i inventory post-migration-linux.yml --limit myvm.example.com
```

### Pre-migration — Windows (VM still on VMware vSphere)

```bash
# Full run against a Windows host group
ansible-playbook -i inventory pre-migration-windows.yml

# Limit to a single host
ansible-playbook -i inventory pre-migration-windows.yml --limit winvm.example.com
```

WinRM inventory example (`inventory.yml`):

```yaml
all:
  hosts:
    winvm.example.com:
      ansible_connection: winrm
      ansible_winrm_transport: ntlm       # or kerberos / credssp
      ansible_winrm_server_cert_validation: ignore
      ansible_user: Administrator
      ansible_password: "{{ vault_win_password }}"
```

### Post-migration — Windows (VM booted on KVM / OpenShift Virtualization)

```bash
# Full run
ansible-playbook -i inventory post-migration-windows.yml

# Limit to a single host
ansible-playbook -i inventory post-migration-windows.yml --limit winvm.example.com
```

### vSphere — Enable CBT (`cbt-enable.yml`)

Enables Changed Block Tracking (CBT) on all compatible disks across one or more VMs.
Requires vCenter credentials; does **not** need SSH/WinRM access to the guest VMs.

```bash
# Single VM (default)
ansible-playbook cbt-enable.yml \
  -e vcenter_hostname=vcenter.example.com \
  -e vcenter_username=admin@vsphere.local \
  -e vcenter_password='password'

# Multiple VMs
ansible-playbook cbt-enable.yml \
  -e vcenter_hostname=vcenter.example.com \
  -e vcenter_username=admin@vsphere.local \
  -e vcenter_password='password' \
  -e vm_list='["web-01","web-02","db-01"]'

# Custom datacenter and snapshot name
ansible-playbook cbt-enable.yml \
  -e vcenter_hostname=vcenter.example.com \
  -e vcenter_username=admin@vsphere.local \
  -e vcenter_password='password' \
  -e dc_name='Production-DC' \
  -e snapshot_name='cbt-activation-$(date +%s)'
```

### Lint

```bash
python3 -m pip install --user ansible-lint
ansible-lint pre-migration-linux.yml post-migration-linux.yml \
             pre-migration-windows.yml post-migration-windows.yml \
             cbt-enable.yml
```

---

## Check Catalog

---

## `pre-migration-linux.yml`

Run **before** virt-v2v conversion while the VM is still on VMware vSphere.

### Fact Gathering

| Task | Description |
|------|-------------|
| Gather Facts | Collects OS and hardware facts via `ansible.builtin.setup` |
| Assert VM is running on VMware | **Platform guard** — hard-fails immediately if `VMware` is not present in `product_name` |
| Gather Packages | Collects installed package list via `package_facts` |
| Gather Services | Collects systemd service states via `service_facts` |
| INFO OS | Logs distribution name and version |

### CRITICAL — Boot / Conversion Blockers

| Check | Description |
|-------|-------------|
| Check open-vm-tools package is installed | Fails if `open-vm-tools` package is not installed — virt-v2v needs it for clean driver removal |
| Check open-vm-tools daemon is running | Fails if neither `open-vm-tools.service` nor `vmtoolsd.service` is in running state |
| Check Root Filesystem Is Not BTRFS | Fails if the root (`/`) mount point uses the btrfs filesystem |
| Check No BTRFS Filesystems Mounted | Fails if any mounted filesystem uses btrfs |
| Check GRUB configs use UUID for root disk | Fails if any grub.cfg file references `/dev/sd*`, `/dev/vd*`, or `/dev/xvd*` instead of UUID |
| Check fstab uses UUIDs for mount points | Fails if `/etc/fstab` has non-commented entries using `/dev/sd*` device paths |
| Check GRUB_CMDLINE_LINUX uses UUID | Fails if `/etc/default/grub` contains `root=/dev/sd*` in the kernel command line |
| Check running kernel cmdline uses UUID | Fails if `/proc/cmdline` shows the running kernel was booted with a `/dev/sd*` root device path |
| Check for LUKS encrypted volumes | Fails if any block device has LUKS encryption — passphrase/keyfile availability must be confirmed |
| Check for software RAID arrays | Fails if `/proc/mdstat` shows active mdadm RAID arrays that may desync on device rename |
| Check kernel version is compatible | Fails if kernel version is below 3.10, the minimum for virtio driver support |
| Check EFI System Partition is mounted and healthy | Fails if UEFI system's `/boot/efi` is not mounted as `vfat` |
| Check for ZFS filesystems | Fails if ZFS is loaded or pools exist — virt-v2v cannot convert ZFS volumes |

### HIGH — Post-Migration Failures

| Check | Description |
|-------|-------------|
| Package ubuntu-minimal Is Present | Fails if `ubuntu-minimal` is absent on Ubuntu systems |
| Check for NFS/CIFS mounts in fstab | Fails if fstab contains NFS or CIFS mounts that may not exist in the target environment |
| Check for multipath configuration | Fails if multipath is active — WWID-based naming may break if disk topology changes |
| Check for GRUB password protection | Fails if GRUB is password-protected — boot may fail if password is not preserved |
| Check for VMware legacy tools daemon | Fails if `/usr/bin/vmware-toolsd` exists — conflicts with `open-vm-tools` |
| Check for immutable files | Fails if any file in `immutable_files_list` has the immutable attribute set |
| Check for OverlayFS mounts | Fails if OverlayFS mounts are active — cannot be block-copied by virt-v2v |
| Check FIPS mode | Fails if FIPS mode is enabled — initramfs rebuild may break the FIPS integrity chain |
| Check for NSX or vShield agent packages | Fails if VMware NSX or vShield packages are installed — hypervisor-coupled, fail on KVM |
| Check for VMware Horizon or VDI agent packages | Fails if VMware Horizon or View agent is installed — non-functional on KVM |
| Check for running database services | Fails if MySQL, MariaDB, PostgreSQL, Oracle, or MongoDB are running without a quiesce plan |
| Check qemu-guest-agent is available in repos (RHEL) | Fails if `qemu-guest-agent` is not available in configured yum repositories |
| Check qemu-guest-agent is available in repos (Debian) | Fails if `qemu-guest-agent` is not available in configured apt repositories |
| Check for EDR or AV agent packages | Fails if EDR/AV packages are detected (CrowdStrike, Carbon Black, SentinelOne, etc.) — may block virt-v2v conversion and qemu-guest-agent install post-migration |
| Check for EDR or AV agent services | Fails if EDR/AV services are running — add qemu-guest-agent to EDR allow-list before migrating |

### MEDIUM — Post-Migration Degradation

| Check | Description |
|-------|-------------|
| Check for bonding configurations | Fails if bond/slave network config is found (RHEL) — breaks after MAC address changes |
| Check for bridge configurations | Fails if bridge config is found (Debian) — breaks after MAC address changes |
| Check for hardware-specific udev rules | Fails if udev rules reference specific hardware IDs, MACs, or VMware/e1000 drivers |
| Check for network config conflicts | Fails if NetworkManager and ifupdown are both active simultaneously (RHEL) |
| Check NTP is configured | Fails if no NTP or chrony service is active — clock drift causes auth failures post-migration |
| Check for LVM thin provisioning | Fails if LVM thin-provisioned logical volumes are present — can cause conversion issues |
| Check cloud-init datasource configuration | Fails if cloud-init is configured with a hypervisor-specific datasource (NoCloud, ConfigDrive, Ec2) |
| Check for persistent net rules | Fails if `70-persistent-net.rules` exists — hardcodes MAC-to-interface bindings |
| Check for hardware-dependent systemd units | Fails if systemd units have `After=/dev/` or `Requires=/dev/` dependencies |
| Check Netplan configuration is valid | Fails if `netplan info` returns non-zero exit code (Ubuntu only) |
| Check root filesystem free space | Fails if root filesystem has less than 1 GB free — virt-v2v needs space for conversion |
| Check for hardcoded MAC addresses in ifcfg files | Fails if `HWADDR=` entries are found in RHEL network config — breaks after MAC change |
| Check for hardcoded MAC addresses in Debian network config | Fails if `hwaddress` or `mac-address` entries found in Debian network config |
| Check dracut is configured to include virtio modules | Fails if no dracut config references virtio — future initramfs rebuilds may omit virtio drivers (RHEL only) |
| Check for huge pages configuration | Fails if huge pages are reserved — NUMA topology may differ on the KVM host |
| Check AppArmor profiles for /dev/sd* references | Fails if AppArmor profiles reference `/dev/sd*` — may deny access to `/dev/vd*` post-migration |
| Check auditd rules for /dev/sd* references | Fails if auditd rules reference `/dev/sd*` — will fail silently after device rename |
| Check for real-time kernel | Fails if an RT kernel is in use — virtio driver compatibility may be affected |
| Check for VMware-integrated backup agent packages | Fails if hypervisor-coupled backup agents are installed — lose vSphere snapshot integration |
| Check for SR-IOV or PCI passthrough devices | Fails if SR-IOV or VFIO passthrough is in use — not portable without KubeVirt device plugin |

### LOW — Operational Concerns

| Check | Description |
|-------|-------------|
| Check virtio drivers are in initramfs (RHEL) | Fails if `virtio_blk`, `virtio_scsi`, or `virtio_net` are missing from the RHEL initramfs — virt-v2v will inject them during conversion |
| Check virtio drivers are in initramfs (Debian) | Fails if virtio drivers are missing from the Debian/Ubuntu initrd — virt-v2v will inject them during conversion |
| Check Secure Boot state | Fails if Secure Boot is enabled — verify virtio drivers are signed for the target (distro-shipped modules are already signed) |
| Check partition table type | Fails if primary disk uses MBR partition table instead of GPT |
| Check for problematic cron entries | Fails if cron jobs reference `/dev/sd*`, NFS mounts, or external hostnames |
| Check for Docker host device mounts | Fails if running Docker containers have `/dev/` bind mounts |
| Check for legacy network interface naming | Fails if interfaces use legacy `eth0`-style names instead of predictable names |
| Check swap uses UUID in fstab | Fails if swap entry in `/etc/fstab` uses a `/dev/sd*` path instead of UUID |
| Check Docker storage driver | Fails if Docker uses `devicemapper` storage driver on top of LVM |
| Check for syslog forwarding | Fails if rsyslog is configured to forward logs to an external host |
| Check timezone is set to UTC | Fails if system timezone is not UTC or Etc/UTC |
| Check root filesystem resize capability | Fails if root filesystem is ext2 or ext3 — may not support online resize |
| Check GRUB video configuration | Fails if GRUB has `GRUB_GFXMODE` or `GRUB_GFXPAYLOAD` — incompatible with KVM display |
| Check resolv.conf is managed | Fails if `/etc/resolv.conf` is not managed by NetworkManager or dhclient |
| Check for running Podman containers | Fails if Podman containers are running — stop before migration for filesystem consistency |
| Check for running Docker containers | Fails if Docker containers are running — stop before migration for filesystem consistency |
| Check for virt-who VMware configuration | Fails if virt-who is configured for VMware — RHEL subscription needs re-registration post-migration |
| Check for non-standard MTU configuration | Fails if any interface has a non-standard MTU — may cause fragmentation on OVN overlay (MTU 1400) |
| Check cloud-init VMwareGuestInfo datasource is configured | Fails if cloud-init does not have `VMwareGuestInfo` datasource — network may not initialize on first boot in OpenShift Virtualization |

### Informational Only

| Task | Description |
|------|-------------|
| INFO Boot mode | Logs whether system uses UEFI or BIOS/Legacy boot |
| INFO SELinux mode | Logs current SELinux status and mode |
| INFO SELinux autorelabel notification | Notes that virt-v2v handles SELinux relabeling automatically during conversion when SELinux is enforcing |
| INFO Non-virtio network drivers | Logs e1000, vmxnet, or igb adapters detected via lspci |
| INFO Hypervisor-specific kernel modules | Logs vmxnet, vmware, lpfc, qla2xxx, or bnx2 modules currently loaded |
| INFO VMware Tools kernel module conflicts | Logs vmxnet, pvscsi, or vmhgfs modules loaded alongside `open-vm-tools` |
| INFO Network interface count | Logs number of non-loopback interfaces |
| INFO NIC details | Logs each interface's MAC, IP, driver, and MTU |
| Warn if multiple NICs detected | Warns if more than 1 NIC is present — each must be mapped in KubeVirt VM spec |
| INFO Static IP files found | Logs paths to static IP configuration files found |
| INFO Huge pages total | Logs total huge pages reserved |
| INFO MTU values | Logs interfaces with non-standard MTU values |

---

## `post-migration-linux.yml`

Run **after** virt-v2v conversion once the VM has booted on KVM / OpenShift Virtualization.

### Fact Gathering

| Task | Description |
|------|-------------|
| Gather Facts | Collects OS and hardware facts via `ansible.builtin.setup` |
| Assert VM is running on KVM (not VMware) | **Platform guard** — hard-fails immediately if `VMware` is still present in `product_name` |
| Gather Packages | Collects installed package list via `package_facts` |
| Gather Services | Collects systemd service states via `service_facts` |
| INFO OS | Logs distribution, version, and kernel |

### CRITICAL — Must Pass Before VM Is Considered Migrated

| Check | Description |
|-------|-------------|
| Check VMware kernel modules are not loaded | Fails if any VMware kernel module (vmxnet, pvscsi, vmmemctl, vmci, vmw_vsock, vmw_balloon) is still loaded |
| Check virtio_blk or virtio_scsi driver is loaded | Fails if neither `virtio_blk` nor `virtio_scsi` is loaded — VM cannot access its disk |
| Check virtio_net driver is loaded | Fails if `virtio_net` is not loaded — VM has no functional network driver |
| Check root disk is virtio (vda/vdb or virtio-scsi) | Fails if all disk devices are still `/dev/sd*` instead of `/dev/vd*` |
| Check primary NIC uses virtio_net driver | Fails if any non-loopback interface is not driven by `virtio_net` |
| Check open-vm-tools package is removed | Fails if `open-vm-tools` is still installed |
| Check vmtoolsd service is not running | Fails if `open-vm-tools.service` or `vmtoolsd.service` is still in running state |
| Check fstab has no stale /dev/sd* references | Fails if `/etc/fstab` still contains `/dev/sd*` or `/dev/xvd*` device paths |

### HIGH — Post-Migration Operational Readiness

| Check | Description |
|-------|-------------|
| Check qemu-guest-agent is installed | Fails if `qemu-guest-agent` package is not present — required for OCP-V lifecycle management |
| Check qemu-guest-agent service is running | Fails if `qemu-guest-agent.service` is not in running state |
| Check VMware Tools binary is absent | Fails if `/usr/bin/vmware-toolsd` still exists on disk |
| Check VMware Tools config directory is absent | Fails if `/etc/vmware-tools` directory still exists |
| Check VMware ProgramData directory is absent | Fails if `/usr/lib/vmware-tools` still exists |
| Check for remaining VMware packages (RHEL) | Fails if any VMware or open-vm-tools RPM packages are still installed |
| Check for remaining VMware packages (Debian) | Fails if any VMware or open-vm-tools Debian packages are still installed |
| Check for leftover VMware udev rules | Fails if any udev rules in `/etc/udev/rules.d/` reference vmware, vmxnet, or pvscsi |
| Check persistent net rules are absent | Fails if `70-persistent-net.rules` still exists — hardcoded MAC bindings break new interface names |
| Check FQDN resolves | Fails if `getent hosts $(hostname -f)` returns no result — DNS is broken |
| Check NTP/chrony service is running | Fails if no NTP or chrony service is active — clock drift breaks TLS and Kerberos |
| Check cloud-init status | Fails if cloud-init is installed but did not complete with `status: done` |
| Check SELinux autorelabel file is consumed | Fails if `/.autorelabel` still exists — SELinux relabeling did not run on first boot |

### MEDIUM — Operational Quality

| Check | Description |
|-------|-------------|
| Check hostname matches inventory | Fails if `ansible_hostname` does not match the inventory hostname short name |
| Check SSH host keys exist | Fails if no SSH host keys are present in `/etc/ssh/` |
| Check root filesystem free space post-migration | Fails if root filesystem has less than 1 GB free after conversion |
| Check GRUB config has no VMware-specific kernel args | Fails if grub.cfg still contains vmware, open-vm-tools, or vmxnet references |
| Check virtio_balloon driver is loaded | Fails if `virtio_balloon` is not loaded — memory ballooning is inactive |
| Check default route exists | Fails if `ip route show default` returns no route — network is misconfigured |

### LOW — Platform Integration

| Check | Description |
|-------|-------------|
| Check virtio-serial device exists for qemu-guest-agent | Fails if `/dev/virtio-ports/` is absent — qemu-guest-agent cannot communicate with the hypervisor |
| Check for leftover VMware snapshot/delta files | Fails if any `.vmdk` files are found on disk outside `/proc`, `/sys`, or `/dev` |
| Check dmesg for KVM or virtio errors | Fails if dmesg contains error, fail, panic, or oops messages related to KVM or virtio |

### Informational Only

| Task | Description |
|------|-------------|
| INFO Hypervisor | Logs hypervisor type detected by `systemd-detect-virt` |
| INFO Detected virtualization type | Logs the raw output of `systemd-detect-virt` |
| INFO Disk devices detected | Logs all non-optical disk device names |
| INFO NIC drivers detected | Logs each interface name and its kernel driver |
| INFO FQDN resolution result | Logs the resolved IP address for the VM's FQDN |
| INFO SELinux mode post-migration | Logs current SELinux mode (Enforcing / Permissive / Disabled) |
| INFO Root filesystem usage | Logs `df -h /` output |
| INFO Filesystem usage detail | Logs full `df -h /` output lines |
| INFO Default route | Logs the active default route |
| INFO IP addresses | Logs all IPv4 addresses assigned to the VM |
| INFO dmesg KVM/virtio messages | Logs any KVM/virtio-related dmesg lines (only when errors are found) |
| INFO Kernel version | Logs the running kernel version |

---

## `pre-migration-windows.yml`

Run **before** virt-v2v conversion while the Windows VM is still on VMware vSphere.
Requires WinRM access and the `ansible.windows` collection.

### Fact Gathering

| Task | Description |
|------|-------------|
| Gather Facts | Collects OS and hardware facts via `ansible.builtin.setup` |
| Assert VM is running on VMware | **Platform guard** — hard-fails immediately if `VMware` is not present in `system_vendor` |
| Gather Services | Collects Windows service states via `ansible.builtin.service_facts` |
| INFO OS | Logs Windows edition and version number |

### CRITICAL — Conversion Blockers

| Check | Description |
|-------|-------------|
| Check BitLocker is not enabled | Fails if any volume is not `FullyDecrypted` — virt-v2v cannot read encrypted NTFS |
| Check no Dynamic disks are present | Fails if any disk has `Dynamic` partition style — virt-v2v supports Basic layout only |
| Check no ReFS volumes are present | Fails if any volume uses the ReFS filesystem — no virt-v2v conversion support |
| Check Windows version is compatible | Fails if Windows version is below 6.1 (Windows 7 / Server 2008 R2) |
| Check no pending reboot | Fails if reboot registry keys are set — converting a system with a pending reboot produces an inconsistent disk |
| Check BCD store integrity | Fails if `bcdedit /enum all` returns non-zero — a corrupt BCD causes immediate boot failure after conversion |

### HIGH — Post-Migration Failures

| Check | Description |
|-------|-------------|
| Check VMware Tools is installed | Fails if `VMTools` service does not exist — virt-v2v needs it present for clean driver removal |
| Check VMware Tools service is running | Fails if `VMTools` service is not in running state |
| Check for NSX or vShield agent services | Fails if `vsepflt`, `vnetflt`, NSX, or vShield services are found — hypervisor-coupled, will break networking on KVM |
| Check for VMware Horizon or View agent | Fails if Horizon or ViewAgent package is installed — non-functional on KVM |
| Check for EDR or AV agent services | Fails if EDR/AV services are running — may block virt-v2v conversion and QEMU-GA install post-migration |
| Check for running database services | Fails if MSSQL, Exchange, MySQL, Oracle, or MongoDB is running without a quiesce plan — risk of data corruption |
| Check C drive has sufficient free space | Fails if C: has less than 2 GB free — virt-v2v needs workspace on the system volume |
| Check VSS service is not disabled | Fails if VSS service StartType is Disabled — virt-v2v cannot take a shadow copy snapshot |
| Check VSS writers are healthy | Fails if any VSS writer is in a failed or error state — snapshot consistency cannot be guaranteed |
| Check VSS provider is registered | Fails if Microsoft Software Shadow Copy provider is not registered — shadow copy creation will fail |

### MEDIUM — Operational Concerns

| Check | Description |
|-------|-------------|
| Check Hyper-V role is not installed | Fails if the Hyper-V Windows Feature is installed — conflicts with KVM unless nested virtualization is enabled |
| Check partition table type | Fails if any disk uses MBR — limited to 2 TB and may cause issues with large disks |
| Check for static IP configuration | Informational — NIC MAC address changes post-migration; static IPs must be re-mapped in the KubeVirt VM spec |
| Check pending Windows updates | Informational — large update queues increase post-migration reboot loop risk |
| INFO Domain membership | Logs whether the VM is domain-joined or in a workgroup |
| INFO Page file configuration | Logs page file location — non-C: page files may become inaccessible if drive order shifts |

### LOW — Operational Readiness

| Check | Description |
|-------|-------------|
| Check Secure Boot state | Fails if Secure Boot is enabled — verify virtio drivers are signed for the target platform (MTV provides signed drivers) |
| Check RDP is enabled | Fails if RDP is disabled — remote access will not be available after migration |
| INFO VMware registry keys | Logs presence of `HKLM:\SOFTWARE\VMware, Inc.` for post-migration cleanup reference |
| INFO Disk inventory | Logs each disk's size, partition style, and operational status |
| INFO NIC inventory | Logs each network adapter's name, description, and link state |

---

## `post-migration-windows.yml`

Run **after** virt-v2v conversion once the Windows VM has booted on KVM / OpenShift Virtualization.
Requires WinRM access and the `ansible.windows` collection.

### Fact Gathering

| Task | Description |
|------|-------------|
| Gather Facts | Collects OS and hardware facts via `ansible.builtin.setup` |
| Assert VM is running on KVM (not VMware) | **Platform guard** — hard-fails immediately if `VMware` is still present in `system_vendor` |
| Gather Services | Collects Windows service states via `ansible.builtin.service_facts` |
| INFO OS | Logs Windows edition, version, and kernel build |

### CRITICAL — Must Pass Before VM Is Considered Migrated

| Check | Description |
|-------|-------------|
| Check VMware PVSCSI and VMXNET drivers are not active | Fails if VMware storage or network drivers are still bound — incomplete or failed conversion |
| Check virtio-net (NetKVM) driver is active | Fails if no Red Hat VirtIO network adapter is detected — VM has no functional virtio NIC |
| Check virtio storage driver is active | Fails if VirtIO SCSI or Block storage driver is not found — VM cannot access its disk via virtio |
| Check VMware Tools package is removed | Fails if VMware Tools package is still installed |
| Check VMware Tools service is not running | Fails if `VMTools` service is still running |
| Check C drive is accessible | Fails if `C:\` path is not reachable — system volume may be unmounted or corrupt |

### HIGH — Post-Migration Operational Readiness

| Check | Description |
|-------|-------------|
| Check QEMU Guest Agent service is running | Fails if `QEMU-GA` service is absent or not running — required for OCP-V IP reporting, snapshot quiesce, and live migration |
| Check no VMware services are running | Fails if any service matching `^VM`, `VMware`, or `vmtools` is in running state |
| Check VMware Tools binary is absent | Fails if `C:\Program Files\VMware\VMware Tools` directory still exists |
| Check VMware registry keys are absent | Fails if `HKLM:\SOFTWARE\VMware, Inc.` registry key still exists |
| Check Windows activation status | Fails if `slmgr.vbs /dli` does not return `License Status: Licensed` — KMS VMs need re-activation after UUID change |
| Check default route exists | Fails if no `0.0.0.0/0` route is found — network is misconfigured |
| Check DNS resolution works | Fails if hostname does not resolve — DNS may be broken |
| Check no excess critical errors in Event Log since boot | Fails if more than 5 System Event Log errors have occurred since last boot |

### MEDIUM — Operational Quality

| Check | Description |
|-------|-------------|
| Check hostname matches inventory | Fails if `ansible_hostname` does not match the inventory short name |
| Check C drive free space post-migration | Fails if C: has less than 1 GB free after conversion |
| Check Windows Time service is running | Fails if `W32Time` is not running — clock drift breaks Kerberos and TLS certificate validation |
| Check BCD store has no VMware-specific entries | Fails if `bcdedit /enum all` output contains `vmware` — boot configuration contamination |

### LOW — Platform Integration

| Check | Description |
|-------|-------------|
| Check virtio-serial device exists for QEMU Guest Agent | Fails if no VirtIO Serial device is found — QEMU Guest Agent communication channel may not function |
| Check RDP is still enabled post-migration | Fails if RDP has been disabled — remote access is unavailable |

### Informational Only

| Task | Description |
|------|-------------|
| INFO NIC driver details | Logs each adapter name, description, and link state |
| INFO Disk details | Logs each disk number, size, and partition style |
| INFO C drive usage | Logs used and free space on the C: volume |
| INFO Event log errors since boot | Logs the count of System errors since last boot |
| INFO Default route | Logs the active default gateway |
| INFO IP addresses | Logs all IPv4 addresses assigned to the VM |
| INFO DNS resolution result | Logs the IP returned for the hostname lookup |
| INFO Windows version | Logs Windows edition, version number, and kernel build |

---

## `cbt-enable.yml`

Enables **Changed Block Tracking (CBT)** on all compatible disks across one or more VMware VMs.
CBT is a prerequisite for the **OpenShift Migration Toolkit for Virtualization (MTV)** and other incremental replication workflows.

This playbook runs entirely against vCenter — **no SSH or WinRM access to guest VMs is needed**.

### How It Works

1. **Discovers disks** — Queries vCenter for each VM's disk inventory via `vmware_guest_disk_info`.
2. **Filters compatible disks** — Excludes disks that cannot use CBT:
   - Independent persistent/non-persistent disks (`independent_*` backing mode)
   - Raw Device Mapping (RDM) disks (`RawDiskMappingVer1` backing type)
3. **Maps controller types** — Translates VMware controller types to VMX config prefixes:
   - `paravirtual`, `lsilogic`, `lsilogic-sas` → `scsi`
   - `sata` → `sata`
   - `nvme` → `nvme`
4. **Applies settings** — Sets `ctkEnabled` globally and per-disk (e.g., `scsi0:0.ctkEnabled`) via `vmware_guest` advanced settings.
5. **Activates via snapshot cycle** — Creates then immediately removes a temporary snapshot to trigger the CBT stun/unstun cycle without a power cycle.

### Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `vcenter_hostname` | Yes | — | vCenter Server hostname or IP |
| `vcenter_username` | Yes | — | vCenter username (e.g., `admin@vsphere.local`) |
| `vcenter_password` | Yes | — | vCenter password |
| `vm_list` | No | `["my-vm"]` | List of VM names to enable CBT on |
| `dc_name` | No | `"my-datacenter"` | vCenter datacenter name |
| `snapshot_name` | No | `"cbt-activation"` | Name of the temporary snapshot created during activation |

### Tasks

| Task | Module | Description |
|------|--------|-------------|
| Get disk info | `vmware_guest_disk_info` | Queries vCenter for each VM's disk inventory (controller type, unit number, backing mode) |
| Filter CBT-compatible disks | `set_fact` + `json_query` | Excludes `independent_*` disk modes and RDM disks; maps controller types to VMX prefixes |
| Build CBT advanced settings | `set_fact` + Jinja2 | Constructs the `advanced_settings` list with global `ctkEnabled` + per-disk entries |
| Apply CBT settings | `vmware_guest` | Writes the advanced settings to the VM's VMX config |
| Create snapshot | `vmware_guest_snapshot` | Creates a temporary snapshot to trigger CBT activation (skipped if no compatible disks) |
| Remove snapshot | `vmware_guest_snapshot` | Removes the temporary snapshot immediately after creation |

### Disk Compatibility

| Disk type | CBT supported | Action |
|---|---|---|
| Persistent (FlatVer2, SparseVer1, EnhancedSparse) | Yes | CBT enabled |
| Dependent persistent/non-persistent | Yes | CBT enabled |
| Independent persistent | No | Skipped |
| Independent non-persistent | No | Skipped |
| RDM (RawDiskMappingVer1) | No | Skipped |

### Notes

- The snapshot activation cycle requires the VM to have snapshot capability enabled. If snapshots are disabled on a VM, the activation tasks will be skipped when no compatible disks are found.
- CBT settings take effect after the snapshot stun/unstun cycle. A VM power cycle is an alternative but more disruptive activation method.
- For VMs with no compatible disks (all disks are independent or RDM), the playbook skips the snapshot cycle entirely.
