#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./bootstrap.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# Wait for apt/dpkg locks - common on fresh Ubuntu VMs with auto-updates running
wait_for_apt() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
        || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
        || pgrep -x unattended-upgr >/dev/null 2>&1; do
    if (( waited == 0 )); then
      echo "Waiting for apt lock..."
    fi
    sleep 5
    waited=$(( waited + 5 ))
    if (( waited > 900 )); then
      echo "Timed out waiting for apt lock after 900s" >&2
      exit 1
    fi
  done
}

wait_for_apt
apt-get update -qq

wait_for_apt
apt-get install -y ansible python3-apt

# community.general provides the ufw module used in the playbook
ansible-galaxy collection install -q community.general

ansible-playbook -i localhost, -c local playbook.yml

echo
if [[ -f /root/CUCKOO3_DEPLOYMENT.txt ]]; then
  echo "Deployment report: /root/CUCKOO3_DEPLOYMENT.txt"
fi
if [[ -f /root/.cuckoo3_bootstrap_password ]]; then
  echo "Bootstrap password: /root/.cuckoo3_bootstrap_password"
fi
