#!/usr/bin/env bash
set -uo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./bootstrap.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

KVM_LOG="/var/log/cape-install/kvm-qemu.log"
BASE_LOG="/var/log/cape-install/cape.log"

# Wait for apt or dpkg locks. Fresh Ubuntu VMs often run unattended-upgrades
# on first boot, which holds the lock for several minutes.
wait_for_apt() {
  local waited=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
        || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 \
        || pgrep -x unattended-upgr >/dev/null 2>&1; do
    if (( waited == 0 )); then
      echo "[bootstrap] Waiting for apt lock."
    fi
    sleep 5
    waited=$(( waited + 5 ))
    if (( waited > 900 )); then
      echo "[bootstrap] Timed out waiting for apt lock after 900s." >&2
      exit 1
    fi
  done
}

# Render a fixed-width progress bar string.
_progress_bar() {
  local filled=$1 total=$2 i out=""
  for (( i=0; i<total; i++ )); do
    (( i < filled )) && out="${out}#" || out="${out}-"
  done
  printf '%s' "$out"
}

# Watch both installer log files and print phase headers as they appear.
# Prints a separate line for each log so the user knows which stage is running.
_watch_logs() {
  local kvm_line=0
  local base_line=0

  while true; do
    sleep 3

    # kvm-qemu.sh log
    if [[ -f "$KVM_LOG" ]]; then
      local cur
      cur=$(wc -l < "$KVM_LOG" 2>/dev/null || echo 0)
      if (( cur > kvm_line )); then
        while IFS= read -r line; do
          # Header lines look like: ======= Some Phase =======  or  ### Phase ###
          if [[ "$line" =~ ^[[:space:]]*(={3,}|\#{3,})[[:space:]]+(.*[^[:space:]])[[:space:]]+(={3,}|\#{3,})[[:space:]]*$ ]]; then
            echo "  [kvm-qemu] ${BASH_REMATCH[2]}"
          fi
        done < <(sed -n "$(( kvm_line + 1 )),\$p" "$KVM_LOG" 2>/dev/null)
        kvm_line=$cur
      fi
    fi

    # cape2.sh log
    if [[ -f "$BASE_LOG" ]]; then
      local cur
      cur=$(wc -l < "$BASE_LOG" 2>/dev/null || echo 0)
      if (( cur > base_line )); then
        while IFS= read -r line; do
          if [[ "$line" =~ ^[[:space:]]*(={3,}|\#{3,})[[:space:]]+(.*[^[:space:]])[[:space:]]+(={3,}|\#{3,})[[:space:]]*$ ]]; then
            echo "  [cape2]    ${BASH_REMATCH[2]}"
          fi
        done < <(sed -n "$(( base_line + 1 )),\$p" "$BASE_LOG" 2>/dev/null)
        base_line=$cur
      fi
    fi

    # Elapsed time counter so the terminal does not look frozen
    # while the installers run without printing headers
    printf "\r  [bootstrap] running... elapsed %s" "$(date -u -d "@$(( $(date +%s) - START_TIME ))" +%H:%M:%S 2>/dev/null || echo '?')"
  done
}

# ----- main flow -----

wait_for_apt
apt-get update -qq

wait_for_apt
apt-get install -y ansible python3-apt

ansible-galaxy collection install community.general

echo ""
echo "[bootstrap] Starting CAPEv2 deployment."
echo "[bootstrap] kvm-qemu log: $KVM_LOG"
echo "[bootstrap] cape2    log: $BASE_LOG"
echo ""

START_TIME=$(date +%s)
export START_TIME

_watch_logs &
WATCHER_PID=$!

ansible-playbook -i localhost, -c local playbook.yml
PLAYBOOK_EXIT=$?

kill "$WATCHER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true
printf "\n"

if (( PLAYBOOK_EXIT != 0 )); then
  echo "[bootstrap] Deployment failed (exit $PLAYBOOK_EXIT)."
  echo "[bootstrap] kvm-qemu log: $KVM_LOG"
  echo "[bootstrap] cape2    log: $BASE_LOG"
  exit "$PLAYBOOK_EXIT"
fi
