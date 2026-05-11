# Cuckoo3 Ansible deployment wrapper

Small Ansible wrapper for the official [Cuckoo3](https://github.com/cert-ee/cuckoo3) quickstart on Ubuntu 22.04.

It runs the quickstart non-interactively, adds a systemd service, applies basic firewall rules, and writes a post-install report.

## What it does

- Checks for Ubuntu 22.04 or newer
- Generates a bootstrap password in `/root/.cuckoo3_bootstrap_password`
- Installs required apt packages
- Runs the bundled `quickstart.sh` through `expect`
- Removes the analysis user from the `sudo` group
- Installs `cuckoo-core.service`
- Configures UFW to allow SSH and private-network access to port 80
- Records deployed Cuckoo3 and VMCloak commit hashes

The upstream quickstart still handles Python 3.10, VMCloak, Cuckoo3, nginx, the virtualenv, and `cuckoo-web.service`.

## Files

```text
playbook.yml            Ansible playbook
bootstrap.sh            Installs Ansible and runs the playbook
files/quickstart.sh     Bundled upstream quickstart
README.md
```

## Requirements

- Ubuntu 22.04 LTS or newer
- 4+ CPU cores with VT-x or AMD-V
- 8 GB RAM
- 80 GB disk
- Internet access during installation

## Usage

```bash
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

Manual run:

```bash
sudo apt install -y ansible python3-apt
sudo ansible-galaxy collection install community.general
sudo ansible-playbook -i localhost, -c local playbook.yml
```

## Variables

Variables are defined under `vars:` in `playbook.yml`.

| Variable | Default |
|---|---|
| `cuckoo_username` | `cuckoo` |
| `cuckoo_password_store` | `/root/.cuckoo3_bootstrap_password` |
| `cuckoo_create_user` | `true` |
| `cuckoo_create_default_vms` | `true` |
| `cuckoo_static_root` | `/opt/cuckoo3/static` |
| `cuckoo_install_marker` | `/opt/cuckoo3/.quickstart_done` |
| `cuckoo_limit_web_to_rfc1918` | `true` |

## Re-running

After a successful install, the playbook skips the quickstart and reapplies the post-install steps.

To force a full run:

```bash
sudo rm /opt/cuckoo3/.quickstart_done
sudo ansible-playbook -i localhost, -c local playbook.yml
```

## Notes

The `expect` task depends on the quickstart prompt text. If upstream prompts change, check `/var/log/cuckoo3-quickstart.log` and update the matching pattern in `playbook.yml`.

The quickstart pulls moving branches, so installed code can differ between runs. Deployed commit hashes are saved in `/root/CUCKOO3_DEPLOYMENT.txt`.

## Output files

| Path | Content |
|---|---|
| `/root/CUCKOO3_DEPLOYMENT.txt` | System info and deployed commit hashes |
| `/root/.cuckoo3_bootstrap_password` | Generated bootstrap password |
| `/var/log/cuckoo3-quickstart.log` | Quickstart log |
| `/opt/cuckoo3/.quickstart_done` | Install marker |

## License

MIT
