#!/usr/bin/env bash
set -uo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo ./bootstrap.sh" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

QUICKSTART_LOG="/var/log/cuckoo3-quickstart.log"

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
# Args: filled_count total_width
_progress_bar() {
  local filled=$1
  local total=$2
  local i
  local out=""
  for (( i=0; i<total; i++ )); do
    if (( i < filled )); then
      out="${out}#"
    else
      out="${out}-"
    fi
  done
  printf '%s' "$out"
}

# Watch the quickstart log and print phase headers as they appear.
# When VMCloak starts an ISO download, switch to a separate progress display
# that tracks the file size and reports speed and elapsed time.
_watch_quickstart_log() {
  local log="$QUICKSTART_LOG"
  local last_line=0
  local iso_path=""
  local iso_start=0
  local iso_last_size=0
  local iso_last_time=0

  # Approximate Win10 x64 ISO size in MB. Used only for percentage display.
  local iso_estimate_mb=5500

  while true; do
    sleep 2

    [[ ! -f "$log" ]] && continue

    local current_lines
    current_lines=$(wc -l < "$log" 2>/dev/null || echo 0)

    # Process any new log lines for phase headers and ISO start
    if (( current_lines > last_line )); then
      while IFS= read -r line; do
        # Section header lines look like:  ### Some Phase ###
        if [[ "$line" =~ ^[[:space:]]*\#\#\#[[:space:]]+(.*[^[:space:]])[[:space:]]+\#\#\#[[:space:]]*$ ]]; then
          if [[ -n "$iso_path" ]]; then
            # Finalize the progress line before printing a new phase
            printf "\n"
            iso_path=""
          fi
          echo "  -- ${BASH_REMATCH[1]}"
        fi

        # VMCloak starts an ISO download. Capture path and start time.
        if [[ -z "$iso_path" ]] && [[ "$line" == *"Downloading ISO"* ]]; then
          iso_path=$(echo "$line" | grep -oP '(?<=to )/\S+\.iso' | head -1 || true)
          if [[ -n "$iso_path" ]]; then
            iso_start=$(date +%s)
            iso_last_time=$iso_start
            iso_last_size=0
            printf "\n"
            echo "     Windows ISO download starting."
            echo "     This may take 10 to 30 minutes depending on connection speed."
            echo "     To skip the download on the next run, put the ISO at"
            echo "       /home/<your-user>/Downloads/win10x64.iso"
            echo "     and set cuckoo_existing_iso in playbook.yml. See README."
            printf "\n"
          fi
        fi
      done < <(sed -n "$(( last_line + 1 )),\$p" "$log" 2>/dev/null)
      last_line=$current_lines
    fi

    # Update the ISO download progress line if a download is in progress
    if [[ -n "$iso_path" ]] && [[ -f "$iso_path" ]]; then
      local cur_size cur_time elapsed em es delta_size delta_time speed_kbs size_mb pct filled bar
      cur_size=$(stat -c%s "$iso_path" 2>/dev/null || echo 0)
      cur_time=$(date +%s)

      if (( cur_size > 0 )); then
        size_mb=$(( cur_size / 1048576 ))
        elapsed=$(( cur_time - iso_start ))
        em=$(( elapsed / 60 ))
        es=$(( elapsed % 60 ))

        delta_time=$(( cur_time - iso_last_time ))
        delta_size=$(( cur_size - iso_last_size ))
        speed_kbs=0
        if (( delta_time > 0 )); then
          speed_kbs=$(( delta_size / delta_time / 1024 ))
        fi

        pct=$(( size_mb * 100 / iso_estimate_mb ))
        (( pct > 99 )) && pct=99
        (( pct < 0 )) && pct=0

        filled=$(( pct * 30 / 100 ))
        bar=$(_progress_bar "$filled" 30)

        printf "\r     ISO [%s] %4d MB  %5d KB/s  %02d:%02d  ~%2d%%" \
          "$bar" "$size_mb" "$speed_kbs" "$em" "$es" "$pct"

        iso_last_size=$cur_size
        iso_last_time=$cur_time
      fi
    fi
  done
}

# ----- main flow -----

wait_for_apt
apt-get update -qq

wait_for_apt
apt-get install -y ansible python3-apt

ansible-galaxy collection install community.general

echo ""
echo "[bootstrap] Starting Cuckoo3 deployment."
echo "[bootstrap] Live log: $QUICKSTART_LOG"
echo ""

# Wipe any stale log so the watcher does not re-show old headers
: > "$QUICKSTART_LOG" 2>/dev/null || true

_watch_quickstart_log &
WATCHER_PID=$!

# Run the playbook. Capture exit code without aborting the script so the
# watcher can be cleaned up regardless of outcome.
ansible-playbook -i localhost, -c local playbook.yml
PLAYBOOK_EXIT=$?

# Stop the watcher
kill "$WATCHER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true
printf "\n"

if (( PLAYBOOK_EXIT != 0 )); then
  echo "[bootstrap] Deployment failed (exit $PLAYBOOK_EXIT)."
  echo "[bootstrap] Check the quickstart log: $QUICKSTART_LOG"
  exit "$PLAYBOOK_EXIT"
fi
