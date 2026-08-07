# nixcloud

Declarative rclone FUSE cloud mounts. One systemd unit per account
(kDrive, Dropbox, OneDrive, pCloud, Proton, Yandex, a WebDAV endpoint, a
private S3-compatible bucket, whatever rclone itself supports), each
mounted under a configurable root -- plus a health monitor for the one
failure `systemctl is-active` structurally cannot see: a FUSE session
that's still `active`, still readable-looking, and permanently wedged.

**The operator end state this is built for:** one rclone client on a
server, many cloud accounts, each mounted under its own subdirectory of
one root, the whole tree then re-exported once (SMB, NFS, a bind mount --
nixcloud has no opinion) to the rest of a fleet. nixcloud only ever
builds the mounts themselves.

**The problem this solves.** A mount unit reporting `active` proves the
`rclone mount` process is alive. It proves nothing about whether the
session behind it still works. Several real backends -- anything
reverse-engineered from a private API rather than a genuine OAuth/API-key
flow -- can hold the FUSE channel open while the authenticated session
backing it has silently died. Every filesystem call against the mount
then hangs instead of erroring, and `systemctl status` reports a
perfectly healthy unit the entire time. `nixcloud.health` watches for
exactly that shape -- an established mount that's stopped actually
answering -- and clears it, without needing to know anything about which
specific backend is behind it.

## Where this came from

The mechanism started as a private module (`options.nixnas.rcloneMounts`)
squatting this project's public namespace before this repo existed --
one server, one hardcoded provider registry, one hardcoded mount root.
This repo is that module generalised: the schema is now typed options
any consumer can fill in, the provider knowledge (which specific vendor
needs what) has been cut out entirely because it's estate knowledge, not
mechanism, and the health monitor -- which the private module never
had -- is new.

**Not** a github:julian-corbet/nixshare provider, and deliberately never
will be: that project's providers each render a `systemd.mount`/
`.automount` pair whose `what=` is a peer name NSS resolves to an
address. An rclone remote has no address at all -- it's a `Type=notify`
service running `rclone mount`, torn down with a FUSE unmount, not a
kernel automount. Nothing in nixshare's mechanism is reusable here; its
`nixshare-health` tool's *behaviour* -- detect a stuck mount, force it
down before it wedges a consumer -- is the one thing worth carrying
over, reimplemented for a transport that has no kernel client to reset
(see "How the health monitor works" below for why that actually makes
recovery simpler here, not harder).

## Quickstart

```nix
# flake.nix (consumer side)
{
  inputs.nixcloud.url = "github:julian-corbet/nixcloud-corbet-ch";

  outputs = { self, nixpkgs, nixcloud, ... }: {
    nixosConfigurations.example-host = nixpkgs.lib.nixosSystem {
      modules = [
        nixcloud.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

```nix
# configuration.nix
nixcloud = {
  enable = true;

  mountRoot = "/mnt/clouds";       # accounts land at <mountRoot>/<provider>/<name>
  configPath = "/run/rclone/rclone.conf"; # a SECRET, see "Secrets" below -- this
                                           # module never generates or reads it
                                           # for anything but ExecStart --config
  user = "clouduser";              # mounted files present as this user's uid/gid;
                                    # resolved via `id` at runtime -- see
                                    # nixcloud.user's own option doc for why not
                                    # a NixOS users.users.<name>.uid lookup

  accounts = {
    personal = {
      provider = "dropbox";        # -> /mnt/clouds/dropbox/personal
      # remote omitted -- defaults to "personal", the attribute name
    };

    archive = {
      remote = "archive-remote";   # the [section] name in rclone.conf, if it
                                    # differs from this module's own account name
      provider = "icloud";
      fragile = true;              # reverse-engineered backend -- longer restart
                                    # backoff so a transient failure can't turn
                                    # into a rate-limit or account lock
      extraArgs = [ "--vfs-cache-mode=writes" ];
    };
  };

  health = {
    enable = true;
    recovery = "recover";          # or "alert" to only ever observe
  };
};
```

```console
$ systemctl status nixcloud-mount-personal.service
● nixcloud-mount-personal.service - rclone FUSE mount: dropbox/personal (remote personal)
     Loaded: loaded
     Active: active (running)

$ ls /mnt/clouds/dropbox/personal
...

$ systemctl status nixcloud-health.timer
● nixcloud-health.timer - Poll nixcloud mounts for a wedged FUSE session
     Loaded: loaded
     Active: active (waiting)

# Simulate the failure this project exists for: the session behind the
# mount dies while the FUSE channel stays open. Once probes fail
# consecutiveFailures times in a row, the monitor forces it down and
# restarts the unit -- nobody has to notice a session hung on `ls` and
# reach for `fusermount -uz` by hand.
$ journalctl -u nixcloud-health.service -n5
nixcloud-health: 'archive' (/mnt/clouds/icloud/archive) probe failed (attempt 2/3, 10004ms)
nixcloud-health: 'archive' (/mnt/clouds/icloud/archive, unit nixcloud-mount-archive.service) failed 3 consecutive probes -- forcing unmount and restart
nixcloud-health: restarted nixcloud-mount-archive.service
```

`nixcloud.enable = true` also puts `rclone` itself on the operator's PATH
(`environment.systemPackages`), so `rclone lsd remote:` or `rclone config`
work at a shell without a separate package declaration. That's for a
human only -- every generated mount unit already invokes this exact same
`pkgs.rclone` by store path, so the FUSE mounts themselves never depended
on it and would keep working even with `nixcloud.enable = false` removing
it again.

## How the health monitor works

`nixcloud-health` ([pkgs/nixcloud-health.nix](pkgs/nixcloud-health.nix))
is a real, working shell tool run by `nixcloud-health.service`
(`Type = "oneshot"`, root, no sandboxing -- see [Security](#security)
for why), fired every `health.pollIntervalSec` (default `60`) by
`nixcloud-health.timer`. Every tick, for every declared account:

1. **Is a mount attempt even up?** `systemctl show -p ActiveState`. Not
   `active` -- still starting, crashed, or intentionally down -- and
   there's nothing for this tool to do: that shape is bounded by
   systemd's own `Type=notify` startup timeout and
   `Restart=`/`StartLimitBurst`, not by a health probe. Its state is
   still recorded as data (see "Health data"), just with no probe
   attempted.
2. **Probe the mountpoint, twice, bounded.** A `stat` of the mountpoint
   root, then (only if that succeeded) an `ls` of it -- each wrapped in
   `timeout`. The kernel's own FUSE attribute cache is 5s
   (`--attr-timeout`, `modules/core.nix`), well under any sane poll
   interval, so the `stat` is guaranteed to reach the rclone daemon
   itself and not a stale kernel-side cache entry. The `ls` catches a
   daemon that can still answer a bare `GETATTR` from local state but
   hangs on anything that actually needs the backend -- with one stated,
   honest gap: rclone's own `--dir-cache-time` (1h) can still serve that
   listing from ITS internal cache within the window, independent of the
   kernel guarantee above. See `pkgs/nixcloud-health.nix`'s own header
   and `experiments/README.md` #001/#002 for the reasoning and the
   deferred, more complete fix.
3. **Track consecutive failures per account**, in `health.stateDir`
   (tmpfs -- a reboot already clears mount state, so a stale counter must
   not survive one).
4. **At `health.consecutiveFailures` in a row**, gated by
   `health.cooldownSec` since that account's last recovery attempt: if
   `health.recovery == "recover"`, force-unmount
   (`fusermount -uz`, falling back to `umount -f -l` -- neither needs the
   wedged process to cooperate) and `systemctl restart` the account's own
   unit. `"alert"` stops at detection: report, change nothing.
5. **Always write status data** -- see below.

**Why recovery here is simpler than the equivalent NFS problem.** A
wedged NFS mount can share one kernel `nfs_client` with every other
mount of the same server, so curing it means tearing down a whole peer
group at once and reassembling it afterwards -- exactly the problem
github:julian-corbet/nixshare's own `nixshare-health` solves, and why it
needs a restore-guarantee trap, a reachability gate, and an escalation
ladder. An rclone FUSE mount has no such shared resource: every account
is its own isolated mount. Unmounting and restarting the ONE unit that
went bad is the entire cure -- no peer group, no shared client, no risk
of touching something a sibling mount still holds a reference on.

## Health data

`nixcloud.health.statusDir` (default `/run/nixcloud/status`) is the
entire interface this project offers a consumer's own monitoring: plain
JSON files, written every tick, nothing pushed anywhere. One
`<name>.json` per account, plus a combined `summary.json`:

```json
{
  "name": "archive",
  "provider": "icloud",
  "remote": "archive-remote",
  "mountpoint": "/mnt/clouds/icloud/archive",
  "unit": "nixcloud-mount-archive.service",
  "activeState": "active",
  "state": "recovered",
  "probeOk": false,
  "probeMs": 10004,
  "consecutiveFailures": 0,
  "lastCheckedAt": 1785900000,
  "lastRecoveryAt": 1785900000
}
```

`state` is one of: `healthy`, `degraded`, `cooldown`, `recovered`,
`degraded-alert-only` (health.recovery == "alert"), or `unit-<ActiveState>`
(the mount unit itself isn't `active`). Wiring this into an existing
monitoring stack is deliberately left to the consumer -- a Prometheus
node-exporter textfile collector reading `summary.json` through a tiny
`jq` translator, a gatus TCP/HTTP endpoint fronting a script that reads
the same file, a cron job that greps for anything not `healthy`, are all
equally valid and none of them are this repo's job to pick. This module
ships no push, webhook, or alert-command integration of its own -- see
`modules/core.nix` header "CUT from it" for the private module feature
that was deliberately not carried over, and why.

## Secrets

`nixcloud.configPath` is a runtime path to an **already-decrypted**
`rclone.conf`. This module never generates one, never decrypts one, and
never inspects the contents of one -- it reads that path at mount time
(`rclone --config <configPath>`) and nothing else. Every generated
mount unit sets `ConditionPathExists = configPath`, so a config that
genuinely isn't there yet (a fresh host, a secret not yet provisioned)
makes the unit skip cleanly -- `inactive (dead)`, not `failed`, no
restart loop -- instead of crash-looping against a file that was never
going to appear on its own.

How `configPath` actually gets populated is entirely the consumer's
concern: a sops-nix secret, an agenix secret, a plain root-only file
written by some other unit first. If that provisioning step needs to run
*before* any `nixcloud-mount-*` unit starts, order it with an ordinary
NixOS override:

```nix
systemd.services."nixcloud-mount-personal".requires = [ "my-secret-unseal.service" ];
systemd.services."nixcloud-mount-personal".after = [ "my-secret-unseal.service" ];
```

(repeat per account, or wrap in a helper in your own config -- nixcloud
has no opinion on the unseal mechanism, so it has nothing to add here
beyond the units already being ordinary `systemd.services` entries any
NixOS module can extend).

## Security

* Every mount unit runs its `rclone mount` process **as root**, and this
  is deliberate, not an oversight: unprivileged FUSE mounting needs a
  setuid `fusermount3` wrapper most systems don't provide by default,
  and running as root is the standard rclone deployment shape. Files
  inside the mount still present as `nixcloud.user`'s uid/gid via
  `--uid`/`--gid` + `--allow-other`, so a downstream reader (Samba,
  another user's session) sees ordinary ownership, never root's.
* `nixcloud-health.service` is deliberately **unsandboxed** -- no
  `ProtectSystem`, no private mount namespace. Its whole purpose is a
  `fusermount -uz`/`umount -f -l` that must land in the HOST's real,
  shared mount namespace, the one every actual consumer of `mountRoot`
  is using. Most of systemd's hardening directives work by giving a unit
  its own private mount namespace -- which would silently turn every
  force-unmount this tool performs into a no-op.
* `configPath` should point at a root-only-readable file. This module
  does not check its permissions; get that right in whatever provisions
  it.

## Scope

NixOS-only (`nixosModules.core`/`nixosModules.default`) -- deliberately,
unlike some sibling projects in this family that also ship a
`systemManagerModules` variant for a non-NixOS desktop host. Running an
rclone-mount-as-a-server role is inherently a bare-metal-host concept
(see "the operator end state" above); there's no equivalent desktop-
session use case this repo is trying to also serve.

## Option reference

| Option | Type | Default | |
|---|---|---|---|
| `nixcloud.enable` | bool | `false` | also puts `rclone` on the operator's PATH |
| `nixcloud.mountRoot` | path | `/mnt/clouds` | parent of every `<provider>/<name>` mount |
| `nixcloud.configPath` | path | `/run/rclone/rclone.conf` | runtime path to an already-decrypted rclone.conf |
| `nixcloud.user` | str | `"root"` | uid/gid mounted files present as, resolved at runtime |
| `nixcloud.cacheDir` | path | `/var/cache/nixcloud` | parent of per-account VFS cache dirs |
| `nixcloud.cacheMaxSize` | str | `"10G"` | per-mount `--vfs-cache-max-size` |
| `nixcloud.accounts.<name>.remote` | str | `<name>` | rclone.conf `[section]` name |
| `nixcloud.accounts.<name>.provider` | str | *(required)* | mount-path label, `<mountRoot>/<provider>/<name>` |
| `nixcloud.accounts.<name>.fragile` | bool | `false` | longer restart backoff for a reverse-engineered backend |
| `nixcloud.accounts.<name>.extraArgs` | list of str | `[ ]` | extra `rclone mount` flags, appended (last wins) |
| `nixcloud.health.enable` | bool | `true` | |
| `nixcloud.health.pollIntervalSec` | int | `60` | |
| `nixcloud.health.probeTimeoutSec` | int | `10` | bound per sub-probe |
| `nixcloud.health.consecutiveFailures` | int | `3` | before recovery is attempted |
| `nixcloud.health.cooldownSec` | int | `600` | minimum gap between recovery attempts, per account |
| `nixcloud.health.recovery` | enum | `"recover"` | `"recover"` \| `"alert"` |
| `nixcloud.health.stateDir` | path | `/run/nixcloud/state` | cross-tick counters (tmpfs) |
| `nixcloud.health.statusDir` | path | `/run/nixcloud/status` | the data contract -- see "Health data" |
| `nixcloud.health.package` | package | *(built-in)* | override to pin/patch |

Every option carries its full reasoning in `modules/core.nix`'s own
doc comments -- this table is a lookup, not a substitute for reading
them.

## Checks

`nix flake check` builds a toy two-account example host
(`examples/host/configuration.nix`) and proves, among other things: mount
paths compose as `<mountRoot>/<provider>/<name>`; `remote` defaults to
the account name but stays independent when set explicitly; `fragile`
actually changes the generated unit's `RestartSec`/`StartLimitBurst`;
`extraArgs` are appended *after* (and so override) the module's own
defaults; every unit's `ConditionPathExists` tracks `configPath`; the
rendered `health.json` is wired to the declared accounts, not some
independent copy that could drift; `provider` is a genuinely required
option (proven in both directions: omitting it fails the build,
supplying it succeeds); an empty `remote` is rejected at eval time
rather than failing opaquely inside rclone at runtime.

## License

MIT.
