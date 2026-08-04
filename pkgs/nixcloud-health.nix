# pkgs/nixcloud-health.nix
#
# Detects a wedged rclone FUSE session and clears it. See modules/core.nix's
# header for the failure this exists for, and why recovery here is simpler
# than the equivalent problem on a kernel-mounted network filesystem (no
# shared client to reset -- every account is its own isolated mount).
#
# WHY SHELL, NOT RUST: a systemd oneshot invoked fresh by a timer, one pass,
# process exits every tick, cross-tick state lives in files under stateDir
# rather than in the process. The same stateless-CLI carve-out
# github:julian-corbet/nixshare's own watchdog/health tools document for
# themselves -- a genuinely resident daemon would warrant Rust; this is
# never that.
#
# EVERY TICK, PER ACCOUNT:
#
#   1. `systemctl show -p ActiveState`. Not `active` (still starting,
#      crashed, or intentionally down)? Nothing this tool can do about
#      that shape -- a unit that never establishes is bounded by systemd's
#      own Type=notify startup timeout and Restart=/StartLimitBurst, not by
#      this tool. Reset the account's failure counter (nothing to
#      accumulate against a mount that isn't up) and record the unit's own
#      state as the status, so a consumer still sees WHY an account reads
#      unhealthy even while this tool takes no action.
#
#   2. Active: probe the mountpoint with a bounded timeout -- a `stat` of
#      the mountpoint root, then (only if that succeeded) an `ls` of it.
#      The kernel's own FUSE attribute cache is 5s in modules/core.nix's
#      fixed `--attr-timeout`, so any poll cadence slower than that (the
#      default is 60s) always reaches the rclone daemon itself for the
#      `stat`, never a stale kernel-side cache entry -- that part of the
#      probe is a real guarantee, not a hope. The `ls` catches a daemon
#      that can still answer a plain GETATTR from local state but hangs on
#      anything that actually needs the backend.
#
#      HONEST GAP, same shape github:julian-corbet/nixshare's own health
#      monitor states for its NFS equivalent probe: rclone's OWN
#      `--dir-cache-time` (1h, modules/core.nix) can serve the `ls` from
#      its internal directory cache within that window, independent of the
#      kernel-level guarantee above -- so a backend that died less than
#      dir-cache-time ago can still pass probe 2 if something else
#      refreshed that listing recently. Closing this fully would need
#      either a much shorter dir-cache-time (a real performance cost) or
#      driving rclone's `--rc` remote-control API to force a cache-forget
#      before every probe (a real feature, deliberately not built here --
#      see experiments/README.md). Left stated, not silently assumed
#      solved.
#
#   3. Either probe timing out counts as a failure; both returning counts
#      as success. A consecutive-failure counter persists per account in
#      stateDir (tmpfs -- see modules/core.nix's own note on why).
#
#   4. Below `consecutiveFailures`: write status, do nothing else. At or
#      above it, gated by `cooldownSec` since this account's last recovery
#      (never hammer a genuinely dead remote with repeated force-restarts):
#      if `recovery == "recover"`, force-unmount (`fusermount -uz`, falling
#      back to `umount -f -l` -- neither needs the wedged rclone process to
#      cooperate) then `systemctl restart` the account's own unit.
#      `recovery == "alert"` stops at detection: observe, change nothing.
#
#   5. Always: write `<statusDir>/<name>.json`, and once every account is
#      processed, a combined `<statusDir>/summary.json`. This is the DATA
#      contract this tool exists to provide -- see README "Health data".
#      It ships no alerting, push, or webhook of its own; wiring this data
#      into whatever monitoring a consumer already runs is the consumer's
#      job, deliberately, so this repo never has an opinion on it.
{ lib, writeShellApplication, jq, systemd, util-linux, fuse, coreutils }:

writeShellApplication {
  name = "nixcloud-health";
  runtimeInputs = [ jq systemd util-linux fuse coreutils ];
  text = ''
    # nixcloud-health -- see pkgs/nixcloud-health.nix and README.md
    # "How the health monitor works" for the full explanation.

    config_file="''${NIXCLOUD_HEALTH_CONFIG:-/etc/nixcloud/health.json}"

    if [ ! -r "$config_file" ]; then
      echo "nixcloud-health: cannot read config: $config_file (is nixcloud.health.enable set?)" >&2
      exit 1
    fi
    if ! jq -e . >/dev/null 2>&1 < "$config_file"; then
      echo "nixcloud-health: config is not valid JSON: $config_file" >&2
      exit 1
    fi

    probe_timeout=$(jq -r '.probeTimeoutSec' "$config_file")
    needed_fails=$(jq -r '.consecutiveFailures' "$config_file")
    cooldown=$(jq -r '.cooldownSec' "$config_file")
    recovery=$(jq -r '.recovery' "$config_file")
    state_dir=$(jq -r '.stateDir' "$config_file")
    status_dir=$(jq -r '.statusDir' "$config_file")

    mkdir -p "$state_dir" "$status_dir"

    # Read a numeric counter from a state file, tolerating anything that is
    # not a clean integer. Load-bearing, not defensive noise: under `set -u`
    # bash's arithmetic context treats a non-numeric bare word as a
    # VARIABLE NAME, so `fails=$(( $(read_counter "$f") + 1 ))` against a
    # corrupt state file (a truncated write from an OOM kill or power loss)
    # would otherwise be an "unbound variable" hard abort mid-loop, leaving
    # the corruption unhealed and every account ordered after the bad one
    # silently unprobed for the rest of this tick. Same discipline
    # github:julian-corbet/nixshare's own health tool applies to its
    # equivalent state.
    read_counter() {
      local f="$1" raw=""
      [ -f "$f" ] && raw=$(cat "$f" 2>/dev/null || true)
      case "$raw" in
        ""|*[!0-9]*) echo 0 ;;
        *) echo "$raw" ;;
      esac
    }

    now=$(date +%s)
    summary_tmp=$(mktemp)
    trap 'rm -f "$summary_tmp"' EXIT

    # Writes <statusDir>/<name>.json for whichever account is CURRENT in
    # the loop below and appends it to the running summary. Defined once,
    # outside the loop, and reads the loop's own variables as ordinary
    # globals at call time -- bash has no closures to rebind, so redefining
    # this per iteration would buy nothing.
    write_status() {
      local state="$1" probe_ok="$2" probe_ms="$3" fails="$4" last_recovery
      last_recovery=$(read_counter "$recovery_file")
      [ "$last_recovery" -eq 0 ] && last_recovery=null
      jq -n \
        --arg name "$name" --arg provider "$provider" --arg remote "$remote" \
        --arg mountpoint "$mountpoint" --arg unit "$unit" --arg activeState "$active_state" \
        --arg state "$state" --argjson probeOk "$probe_ok" --argjson probeMs "$probe_ms" \
        --argjson consecutiveFailures "$fails" --argjson lastCheckedAt "$now" \
        --argjson lastRecoveryAt "$last_recovery" \
        '{name: $name, provider: $provider, remote: $remote, mountpoint: $mountpoint,
          unit: $unit, activeState: $activeState, state: $state, probeOk: $probeOk,
          probeMs: $probeMs, consecutiveFailures: $consecutiveFailures,
          lastCheckedAt: $lastCheckedAt, lastRecoveryAt: $lastRecoveryAt}' > "$status_file.tmp"
      mv -f "$status_file.tmp" "$status_file"
      cat "$status_file" >> "$summary_tmp"
    }

    account_count=$(jq -r '.accounts | length' "$config_file")
    if [ "$account_count" -eq 0 ]; then
      jq -n '[]' > "$status_dir/summary.json"
      exit 0
    fi

    while IFS= read -r acct_json; do
      name=$(jq -r '.name' <<<"$acct_json")
      provider=$(jq -r '.provider' <<<"$acct_json")
      remote=$(jq -r '.remote' <<<"$acct_json")
      mountpoint=$(jq -r '.mountpoint' <<<"$acct_json")
      unit=$(jq -r '.unit' <<<"$acct_json")

      count_file="$state_dir/$name.count"
      recovery_file="$state_dir/$name.lastrecovery"
      status_file="$status_dir/$name.json"

      active_state=$(systemctl show -p ActiveState --value "$unit" 2>/dev/null || echo "unknown")

      if [ "$active_state" != "active" ]; then
        rm -f "$count_file"
        write_status "unit-$active_state" null null 0
        continue
      fi

      start=$(date +%s%N)
      ok=1
      timeout -k 5 "$probe_timeout" stat "$mountpoint" >/dev/null 2>&1 || ok=0
      if [ "$ok" -eq 1 ]; then
        timeout -k 5 "$probe_timeout" ls -la "$mountpoint" >/dev/null 2>&1 || ok=0
      fi
      end=$(date +%s%N)
      probe_ms=$(( (end - start) / 1000000 ))

      if [ "$ok" -eq 1 ]; then
        rm -f "$count_file"
        write_status healthy true "$probe_ms" 0
        continue
      fi

      fails=$(( $(read_counter "$count_file") + 1 ))
      echo "$fails" > "$count_file"

      if [ "$fails" -lt "$needed_fails" ]; then
        echo "nixcloud-health: '$name' ($mountpoint) probe failed (attempt $fails/$needed_fails, ''${probe_ms}ms)"
        write_status degraded false "$probe_ms" "$fails"
        continue
      fi

      last_recovery=$(read_counter "$recovery_file")
      since_recovery=$(( now - last_recovery ))
      if [ "$last_recovery" -gt 0 ] && [ "$since_recovery" -lt "$cooldown" ]; then
        echo "nixcloud-health: '$name' still degraded, last recovery ''${since_recovery}s ago (< ''${cooldown}s cooldown) -- waiting"
        write_status cooldown false "$probe_ms" "$fails"
        continue
      fi

      if [ "$recovery" != "recover" ]; then
        echo "nixcloud-health: '$name' ($mountpoint) failed $fails consecutive probes -- recovery=alert, taking no action"
        write_status degraded-alert-only false "$probe_ms" "$fails"
        continue
      fi

      echo "nixcloud-health: '$name' ($mountpoint, unit $unit) failed $fails consecutive probes -- forcing unmount and restart"
      fusermount -uz "$mountpoint" 2>/dev/null || umount -f -l "$mountpoint" 2>/dev/null || true
      if systemctl restart "$unit" 2>&1; then
        echo "nixcloud-health: restarted $unit"
      else
        echo "nixcloud-health: restart of $unit reported an error -- see journal" >&2
      fi
      echo "$now" > "$recovery_file"
      rm -f "$count_file"
      write_status recovered false "$probe_ms" 0
    done < <(jq -c '.accounts[]' "$config_file")

    jq -s '.' "$summary_tmp" > "$status_dir/summary.json.tmp"
    mv -f "$status_dir/summary.json.tmp" "$status_dir/summary.json"
  '';

  meta = with lib; {
    description = "Detect a wedged rclone FUSE session and clear it before it hangs a consumer; exposes per-account health as JSON";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
