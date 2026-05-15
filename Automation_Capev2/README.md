# CAPEv2 Ansible deployment wrapper

Drives the official [CAPEv2](https://github.com/kevoreilly/CAPEv2) installer
scripts (`kvm-qemu.sh` and `cape2.sh`) non-interactively on Ubuntu 22.04 or
24.04 and adds systemd units, a UFW ruleset, idempotency markers, a
post-install report and bundled scripts for the analysis guests.

## 🚀 Usage

Run the deployment with:

```bash
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

After the playbook finishes, reboot the host and open the web interface
URL printed in the final summary.

## Requirements

* Ubuntu 22.04 or 24.04 LTS
* 4+ CPU cores with VT-x or AMD-V enabled in the BIOS, 8 GB RAM, 80+ GB disk
* Internet access during installation
* For guest VM creation, a Windows 10 or Windows 11 ISO in
  `/var/lib/libvirt/images/iso/`

While the playbook runs, `bootstrap.sh` tails both installer logs and
prints phase headers from each one as they appear. Between headers an
elapsed-time counter keeps refreshing so the terminal does not look
frozen. Expected total runtime is 30 to 90 minutes, mostly determined by
how long the libvirt and QEMU source build takes on the host.

## What the playbook does

1. Verifies the host runs Ubuntu 22.04 or newer.
2. Checks for conflicting custom libvirt installs under `/usr/local`.
3. Generates a one-time bootstrap password and stores it in
   `/root/.cape_bootstrap_password` (mode 0600).
4. Installs apt baseline including KVM, QEMU and Python build deps.
5. Creates the `cape` user and adds it to the `libvirt` and `kvm` groups.
6. Clones CAPEv2 to `/opt/CAPEv2`.
7. Runs `kvm-qemu.sh all cape` inside tmux; logs to
   `/var/log/cape-install/kvm-qemu.log`.
8. Runs `cape2.sh base` inside tmux; logs to `/var/log/cape-install/cape.log`.
9. Repairs the Poetry virtualenv if `cape2.sh` left it incomplete, and
   installs the runtime and helper Python packages.
10. Installs systemd units for `cape`, `cape-processor` and `cape-web`,
    plus `cape-rooter` if `cape2.sh` placed its unit on disk.
11. Sets UFW to deny incoming by default, allows SSH, and allows port 8000
    from RFC 1918 source addresses.
12. Writes a deployment report and places a copy on the sudo user's Desktop.

What the wrapper does not do: automate guest VM creation, deploy the CAPE
agent inside a guest, or override any of the files in
`/opt/CAPEv2/conf/`. Those steps are covered further down.

## Do not touch apt libvirt or QEMU after the install

`kvm-qemu.sh` purges Ubuntu's apt libvirt and QEMU packages and rebuilds
libvirt 11.x and QEMU 9.x from source. The source builds are then held
via `apt-mark hold`. The CAPE documentation is blunt about why:

> We advise against modifying or updating any package installed by the
> script. By using package managers like apt there are high chances your
> KVM/libvirt/CAPE installation will break and you will most likely end
> up riding the lanes of dependency hell.

This playbook keeps to that rule. After `kvm-qemu.sh` runs, the playbook
does not reinstall apt libvirt, QEMU, virtinst or virt-manager, does not
call `apt-mark unhold` on those packages, and does not switch libvirtd
from split daemons to monolithic mode.

If `virsh` or `virt-install` does not work right after the playbook
finishes, the fix is almost always a reboot. The kernel can still hold
references to the apt KVM modules even after udev is reloaded.

## CAPE repository version

The deployment clones CAPEv2 from my fork:

```yaml
cape_repo_url: "https://github.com/adambudzinak/CAPEv2.git"
cape_repo_version: master

# To use the current upstream CAPEv2 version instead, replace the fork URL
# with the original repository URL below. This may install a newer, untested
# version if upstream master has changed.
# cape_repo_url: "https://github.com/kevoreilly/CAPEv2.git"

```



The fork is used as the repository source, while its `master` branch currently
tracks the upstream CAPEv2 code. On 2026-05-14, the checked CAPEv2 commit was:

```text
Commit dd36c30
Author/committer: kevoreilly
Message: Disguise auxiliary module: ensure launch_background_processes()
launches 64-bit processes on both bitnesses of Python
```

The playbook intentionally uses `master` from my fork:

```yaml
cape_repo_version: master
```

This is acceptable for this deployment because, at the time of validation,
the fork's `master` branch pointed to the tested upstream commit shown above.

To verify the current commit before running the playbook:

```bash
git ls-remote https://github.com/adambudzinak/CAPEv2.git refs/heads/master
```

The returned commit value should begin with the verified commit value above:
`dd36c30`. If the fork is synchronized with upstream later, `master` may move to
a newer commit. In that case, the deployment should be tested again before
updating this section.


## Files

```
Automation_CAPEv2/
├── bootstrap.sh                Entry point; installs Ansible, runs the play
├── playbook.yml                Ansible play with the deployment logic
├── README.md
└── files/
    └── guests/
        ├── win10.sh                virt-install for a Windows 10 guest
        ├── win11.sh                virt-install for a Windows 11 guest
        └── cape_guest_prep.ps1     Guest-side hardening + agent install
```

## Variables

All variables sit at the top of `playbook.yml` under `vars:`.

| Variable | Default | Description |
|---|---|---|
| `cape_username` | `cape` | Linux user that owns the install |
| `cape_password_store` | `/root/.cape_bootstrap_password` | File holding the generated password |
| `cape_repo_url` | CAPEv2 GitHub URL | Repository to clone |
| `cape_repo_version` | pinned commit | Branch, tag or commit to clone |
| `cape_kvm_marker` | `/root/.cape_kvm_done` | Marker for the kvm-qemu stage |
| `cape_base_marker` | `/root/.cape_base_done` | Marker for the cape2 stage |
| `cape_installer_retries` | `360` | Max wait per installer stage (360 × 10s ≈ 1 h) |
| `cape_limit_web_to_rfc1918` | `true` | Restrict port 8000 to RFC 1918 sources |

## Re-running the playbook

Each long installer stage is gated by its own marker file. The marker is
written only when the corresponding installer exits with code 0, so a
failed stage gets retried on the next run.

To retry one stage after fixing the underlying problem:

```bash
# Retry the kvm-qemu stage
sudo rm /root/.cape_kvm_done
sudo ./bootstrap.sh

# Retry the cape2 stage
sudo rm /root/.cape_base_done
sudo ./bootstrap.sh

# Force a full re-run of both
sudo rm -f /root/.cape_kvm_done /root/.cape_base_done
sudo ./bootstrap.sh
```

## Common installer failures and fixes

| Symptom in log | Cause | Status |
|---|---|---|
| `aptitude: command not found` | Ubuntu 22.04 ships without aptitude; `kvm-qemu.sh` needs it | Pre-installed by the playbook |
| `xsltproc: not found` during meson setup | libvirt source build needs xsltproc | Pre-installed |
| `glib-2.0 not found` during QEMU build | QEMU source build needs libglib2.0-dev | Pre-installed |
| `pip: No such file or directory` after poetry install | Recent Poetry versions create venvs without pip | Wrapped via `poetry run pip` |

## Guest VM creation

The host deployment ends with the host services running but no analysis
guests. The scripts under `files/guests/` cover creation and preparation.

**Create a Windows 10 guest (VM name `cape-win10`):**

```bash
# Put win10.iso and virtio-win.iso in /var/lib/libvirt/images/iso/ first
sudo bash files/guests/win10.sh
```

**Create a Windows 11 guest (VM name `cape-win11`):**

```bash
# Put win11.iso in /var/lib/libvirt/images/iso/ first
sudo bash files/guests/win11.sh
```

**Prepare the guest from inside Windows:**

Serve the CAPE agent over HTTP from the host:

```bash
cd /opt/CAPEv2/agent
python3 -m http.server 8008 --bind 192.168.122.1
```

Then run the prep script from an elevated PowerShell inside the guest:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\cape_guest_prep.ps1 -CapeHostIP 192.168.122.1 -AgentServerPort 8008
```

The script installs x86 Python, places the agent at `C:\Windows\agent.pyw`,
registers a SYSTEM-level scheduled task that runs the agent at logon, and
turns off Defender, SmartScreen, the firewall, Windows Update, UAC,
error reporting, NCSI probes, LLMNR, Teredo and telemetry.

After the script reboots the guest, verify the agent from the host
(`curl http://<GUEST_IP>:8000/`) and snapshot it:

```bash
virsh -c qemu:///system shutdown cape-win10
virsh -c qemu:///system snapshot-create-as cape-win10 clean \
       "Clean CAPE Win10 guest" --disk-only --atomic
```

Then list the guest in `/opt/CAPEv2/custom/conf/kvm.conf` and restart the
CAPE services. The deployment report contains a template `kvm.conf`
section to copy from.

## Note on CAHI

[CAHI](https://github.com/CAPESandbox/CAHI) (CAPE Auto-Hardened Installer)
is the official Ansible-based companion project from the CAPESandbox team.
It ports `cape2.sh` and `kvm-qemu.sh` into Ansible roles and adds OS
hardening on top.

At the time of writing CAHI is pre-alpha. Its README says outright,
*"DO NOT RUN this against any production systems."* Its supported
scenarios are container-based (Docker, Podman) or Vagrant-provisioned
VMs, which does not fit a deployment onto an existing bare-metal Ubuntu
host. This wrapper therefore keeps the script-based install path
(`kvm-qemu.sh` + `cape2.sh`) and borrows the orchestration patterns
from CAHI's role layout. When CAHI stabilises and gains direct
bare-metal support, it should replace this wrapper.

## Output files

| Path | Content |
|---|---|
| `/root/CAPE_DEPLOYMENT.txt` | Deployment report |
| `~/Desktop/CAPE_DEPLOYMENT.txt` or `~/CAPE_DEPLOYMENT.txt` | Copy for the sudo user |
| `/root/.cape_bootstrap_password` | Generated password, mode 0600 |
| `/var/log/cape-install/kvm-qemu.log` | Full `kvm-qemu.sh` output |
| `/var/log/cape-install/cape.log` | Full `cape2.sh` output |
| `/root/.cape_kvm_done` | kvm stage marker |
| `/root/.cape_base_done` | cape2 stage marker |

## License

MIT. See `LICENSE`.
