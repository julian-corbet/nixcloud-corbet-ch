# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth
writing up properly. Nothing here is guaranteed to work, be maintained,
or survive the next cleanup pass. If something in here turns out to
matter, distill the actual finding into [`../studies/`](../studies/README.md)
and let the experiment stay disposable (or delete it).

This is also the open-questions ledger for nixcloud's own judgment
calls -- every entry below corresponds to a default or design choice
that's reasoned, not measured. Results feed back into `modules/core.nix`
and `pkgs/nixcloud-health.nix`'s defaults as they close.

All open; nothing here has run against a real cloud mount yet -- the
private module this repo generalises has real mileage (see its own
header, ported into `modules/core.nix`'s own comments), but this repo's
OWN health monitor has none.

## 001 -- the `--dir-cache-time` blind spot in the health probe's second check

**Question:** `pkgs/nixcloud-health.nix`'s probe 2 (`ls` of the
mountpoint) can be served from rclone's own internal directory cache
within `--dir-cache-time` (1h, `modules/core.nix`), independent of the
kernel-side attribute-cache guarantee probe 1 relies on. A backend that
died less than an hour ago can still pass probe 2 if something else
(another reader of the same mount) refreshed that listing recently. Is
that gap actually observed in practice, or is the theoretical exposure
much smaller than it sounds because a wedged session in practice also
fails probe 1 (the `stat`) shortly after?

**Hypothesis:** probe 1 alone likely catches most real wedges -- a
session that's fully dead behind the FUSE channel tends to fail
`GETATTR` too, not just `READDIRPLUS` -- but this is reasoning, not a
finding; github:julian-corbet/nixshare's own equivalent gap (its
README/pkgs/nixshare-health.nix "HONEST LIMIT ON FIX 2") was found by
a real incident where the NFS analogue of this exact split occurred.
Nothing here has been reproduced on rclone specifically.

**Method sketch:** hold an account's mount open, kill the backend
session out from under it in a way that leaves the local process alive
(revoke an OAuth token server-side, or block the account's API access),
and observe whether `stat` and `ls` degrade together or independently.

**Status:** open.

## 002 -- closing the gap with `rclone --rc` instead of accepting it

**Question:** rclone's `--rc` remote-control API exposes `vfs/forget`,
which can force a cache-forget of a path before probing it -- a
definitive fix for #001 rather than a documented gap. Worth the added
surface (an `--rc-addr` unix socket per account, a second tool
dependency in the health script to speak to it)?

**Hypothesis:** probably yes eventually, but it roughly doubles the
health tool's own complexity (a socket to manage, a second failure mode
if `--rc` itself doesn't answer) for a gap #001 hasn't even confirmed
matters in practice. Deferred until #001 either closes with "yes, this
is a real gap" or the simpler two-probe approach turns out to be
sufficient on its own.

**Status:** open.

## 003 -- are `pollIntervalSec=60` / `consecutiveFailures=3` / `cooldownSec=600` the right defaults?

**Question:** `nixcloud.health`'s defaults mean a wedge is detected
somewhere in a 60--180s window (three ticks at 60s) and, once recovered,
the account won't be force-restarted again for 10 minutes even if it's
still broken. Right balance, or too slow to notice / too quick to
hammer a genuinely dead remote?

**Hypothesis:** modelled on github:julian-corbet/nixshare's own health
monitor (`consecutiveFailures = 3`, there too, for the same hysteresis
reason -- don't trigger on one slow tick), scaled `cooldownSec` up from
its 900s (`900` there is for a much heavier NFS client-reset operation;
a plain unmount+restart here is cheaper, so 600s was chosen as "still
generous, not identically heavy-handed") without measuring either
number against a real wedge.

**Status:** open.

## 004 -- `TimeoutStopSec = "20s"` on every mount unit

**Question:** recovery's cure is `systemctl restart`, which stops the
unit (SIGTERM, then SIGKILL after `TimeoutStopSec`) before starting it
again. 20s was chosen to keep recovery itself fast and to finish safely
inside one health-monitor tick at the smallest realistic
`pollIntervalSec`. Is 20s enough margin for systemd to actually reap a
genuinely wedged rclone process, or does a real wedge sometimes need
longer than that to die even under SIGKILL (e.g. while it's inside an
uninterruptible local disk write to its own VFS cache)?

**Hypothesis:** SIGKILL should be sufficient in the overwhelming
majority of cases -- rclone's wedge shape described in this project's
own motivation is a hung NETWORK call, and network reads/writes are
interruptible, unlike the kernel-level D-state case
github:julian-corbet/nixshare's own watchdog documents for an NFS
automount. Not verified against a real hung rclone process.

**Status:** open.
