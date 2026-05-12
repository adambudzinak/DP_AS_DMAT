# Cuckoo3 Ansible deployment wrapper

Drives the official [Cuckoo3](https://github.com/cert-ee/cuckoo3) quickstart
non-interactively on Ubuntu 22.04 and adds a service unit, firewall rules,
a final summary and a post-install report.

## 🚀 Usage

Run the deployment with:

```bash
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```
After installation, open the web interface URL printed in the final summary.

## Requirements

* Ubuntu 22.04 LTS
* 4+ CPU cores with VT-x or AMD-V, 8 GB RAM, 80 GB disk
* Internet access during installation
* If reusing an ISO, the file in the path you configure


While the playbook runs, `bootstrap.sh` prints quickstart phase headers
as they appear. If VMCloak starts an ISO download, a progress bar shows
the downloaded size, transfer rate and elapsed time. The percentage is
estimated against a 5500 MB reference size, so it is approximate.


## What the playbook does

1. Verifies the host runs Ubuntu 22.04 or newer.
2. Generates a one-time bootstrap password and stores it in
   `/root/.cuckoo3_bootstrap_password` (mode 0600).
3. Installs apt dependencies.
4. Optionally copies a pre-downloaded Windows ISO into place so VMCloak
   skips the download. See the next section.
5. Copies the bundled `quickstart.sh`, removes its trailing foreground
   `cuckoo` run, and drives the rest with `expect`.
6. Removes the analysis user from the `sudo` group.
7. Installs `cuckoo-core.service`, restarts it, waits for the node info
   dump, and restarts `cuckoo-web.service` so sample uploads work.
8. Sets UFW to deny incoming by default, allows SSH, and allows port 80
   from RFC 1918 source addresses.
9. Records the deployed Cuckoo3 and VMCloak commit hashes.
10. Writes a deployment report and places a copy on the sudo user's Desktop.
11. Prints a final summary with the web interface URL.

The quickstart itself installs Python 3.10, VMCloak, the Cuckoo3 source,
the virtualenv, nginx, and `cuckoo-web.service`. The wrapper does not
touch any of that.

## Skipping the Windows ISO download

VMCloak downloads a Windows 10 x64 ISO during installation. It is around
5.5 GB and can take 10 to 30 minutes depending on the connection. If you
already have an ISO, the playbook can reuse it:

1. Save your ISO at a known path, for example:

   ```
   /home/youruser/Downloads/win10x64.iso
   ```

2. Edit `playbook.yml` and set:

   ```yaml
   cuckoo_existing_iso: /home/youruser/Downloads/win10x64.iso
   ```

3. Run `sudo ./bootstrap.sh` as usual.

The playbook copies the file to `/home/cuckoo/win10x64.iso` before the
quickstart runs. VMCloak finds it there and skips the download.

The ISO must match what VMCloak expects: a Windows 10 x64 installation
image. Other Windows builds may not work without adjusting VMCloak
configuration.

## Files

```
playbook.yml            Ansible play
bootstrap.sh            Installs Ansible and runs the play
files/quickstart.sh     Bundled upstream quickstart from cert-ee
README.md
```

## Variables

All variables sit at the top of `playbook.yml` under `vars:`.

| Variable | Default | Description |
|---|---|---|
| `cuckoo_username` | `cuckoo` | Linux user that owns the install |
| `cuckoo_password_store` | `/root/.cuckoo3_bootstrap_password` | File holding the generated password |
| `cuckoo_create_user` | `true` | Whether the quickstart should create the user |
| `cuckoo_create_default_vms` | `true` | Whether VMCloak should create default VMs |
| `cuckoo_static_root` | `/opt/cuckoo3/static` | Cuckoo web static-asset root |
| `cuckoo_install_marker` | `/opt/cuckoo3/.quickstart_done` | Idempotency marker |
| `cuckoo_existing_iso` | `""` (empty) | Path to a local Windows ISO to reuse |
| `cuckoo_limit_web_to_rfc1918` | `true` | Restrict web port 80 to RFC 1918 sources |

## Idempotency

The quickstart task uses `creates: {{ cuckoo_install_marker }}` as a guard.
Re-running the playbook after a successful install skips the quickstart
and re-applies the post-install steps.

To force a full re-run:

```bash
sudo rm /opt/cuckoo3/.quickstart_done
sudo ansible-playbook -i localhost, -c local playbook.yml
```

## Limitations

The `expect` driver matches prompts by their literal text. If a prompt
changes upstream the task will time out at 3600 s. The last prompt is
visible in `/var/log/cuckoo3-quickstart.log`. The fix is to update the
matching pattern in `playbook.yml`.

The quickstart pulls Cuckoo3 from `main` and VMCloak from
`bugfix/write_input_format`. These references move over time, so two
runs on different days can install different code. The deployed commit
hashes are recorded in the deployment report.

## Output files

| Path | Content |
|---|---|
| `/root/CUCKOO3_DEPLOYMENT.txt` | Deployment report (system info, services, commits) |
| `~/Desktop/CUCKOO3_DEPLOYMENT.txt` or `~/CUCKOO3_DEPLOYMENT.txt` | Copy for the sudo user |
| `/root/.cuckoo3_bootstrap_password` | Generated password, mode 0600 |
| `/var/log/cuckoo3-quickstart.log` | Full quickstart output |
| `/opt/cuckoo3/.quickstart_done` | Install marker |

## Licence

MIT.
