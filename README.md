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
nixcloud has no opinion) to the rest of a fleet.

**And the other half of the same subject:** the document clouds that
serve those files back out -- a sync-and-share platform, and the
remote-control daemon an operator drives the transfers from -- declared
for a Kubernetes cluster rather than for a host. That is
`nixidyModules.nixcloud` and the catalogue behind it; see [Cluster
plane](#cluster-plane). The two halves share a name and a subject and
nothing else: a host mount is a `systemd` unit, a document cloud is a
pod, and neither module can see the other.

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

## Desktop client

`nixcloud.desktop.enable` declares the Nextcloud sync GUI
(`nextcloud-client`) -- deliberately independent of `nixcloud.enable`,
the mount-serving role above. A laptop that just wants the GUI does not
need to declare itself a mount-serving host (and inherit the health
monitor's timer) to get it, and a mount-serving host does not gain the
GUI as a side effect of enabling its mounts:

```nix
# NixOS
nixcloud.desktop.enable = true;   # -> environment.systemPackages
```

```nix
# Arch / system-manager -- this module has no installer to call here
# (see "Scope" below), so it only publishes a pacman name:
nixcloud.desktop.enable = true;
nixarch.packages.pacman = config.nixcloud.desktop.archPackages;
```

## Cluster plane

Same subject, other end of it. `nixidyModules.nixcloud` declares the
document clouds that serve those files to everybody else, for a
Kubernetes cluster:

```nix
# a nixidy environment (consumer side)
{
  imports = [ nixk3s.nixidyModules.apps nixcloud.nixidyModules.default ];

  nixcloud.applications.documents = {
    app = "opencloud";                 # from lib/applications.nix
    version = "0.0.0";
    namespace = "clouds";
    createNamespace = true;
    exposure = "public";
    state.state.hostPath = "/srv/state/documents";
    state.userfiles.hostPath = "/srv/documents";
    resources.requests = { cpu = "200m"; memory = "512Mi"; };
    resources.limits.memory = "2Gi";
    env = {
      OC_URL = "https://cloud.example.com";
      OC_DOMAIN = "cloud.example.com";
      OC_OIDC_ISSUER = "https://id.example.com";
      WEB_OIDC_METADATA_URL = "https://id.example.com/.well-known/openid-configuration";
      WEB_OIDC_CLIENT_ID = "00000000-0000-0000-0000-000000000000";
    };
  };
}
```

**It renders no Kubernetes object of its own.** It defines into the app
grammar in github:julian-corbet/nixk3s-corbet-ch -- which owns the
Application, the Namespace, the Deployment and the Service -- and adds
the one thing that grammar cannot know: what these particular
applications *are*. Import the grammar alongside it or the module has
nothing to define into.

`lib/applications.nix` is the catalogue and holds only what is true of
the software wherever anyone runs it: the port it listens on, the
directories it writes *inside* the container, which variables carry an
address it must be told, which variables a password arrives in, how
patient a probe has to be, what it stops doing when nobody is looking.
Three applications are catalogued -- `opencloud`, `nextcloud`, `rclone`
-- and the enum comes from that file, so an application it does not hold
is not a refused value, it is not a value.

Everything a *deployment* knows arrives from the declaration and cannot
be defaulted here: the namespace, what backs each directory, the address
of a database this repository does not run, the name a browser reaches
it at, which build of each image runs, which Secret holds each
credential, and what the workload actually costs. The split is enforced
rather than asked for -- leaving a directory unbacked, leaving a required
address unset, leaving a credential with no Secret behind it, typing a
credential into `env`, sizing a container the application does not have,
or giving a version to a container that shares the application's image
are all eval errors, each with its own message and each with a check that
watches it fire.

**Naming a variable is not carrying a secret**, and `credentials` is
where that distinction pays. The catalogue names the variable an
application reads its password out of -- which its own documentation
states and every installation shares; the declaration names the Secret
and, where the keys were spelled by something else, which key. The value
has no home on either side, and what comes out is a `secretKeyRef`.

**Resources are the declaration's**, per container. A CPU share and a
memory ceiling are a measurement of one workload's load on one cluster's
hardware, so the catalogue holds none and nothing here defaults one: a
container nobody sized asks for *nothing*, which renders no `resources`
block at all rather than a zero. Companions are sized separately
(`companionResources`) because the scheduler sums a pod's containers, and
the front that asks for nothing is how a node gets oversubscribed.

There is deliberately **no default namespace**. Two collaboration
platforms people keep open all day share a blast radius; a transfer
daemon restarted and idled without anyone noticing does not, and a
default would be this repository guessing which of its applications fail
together.

## Scope

The mount-serving role (`nixosModules.core`/`nixosModules.default`) is
NixOS-only -- deliberately, unlike some sibling projects in this family
that also ship a `systemManagerModules` variant for a non-NixOS desktop
host. Running an rclone-mount-as-a-server role is inherently a
bare-metal-host concept (see "the operator end state" above); there's no
equivalent desktop-session use case that role is trying to also serve.

The desktop client above is the exception: it *is* a desktop-session use
case, so it ships both backends -- `nixosModules.desktop`
(`environment.systemPackages`) and `systemManagerModules.desktop`/
`systemManagerModules.default` (publishes `nixcloud.desktop.archPackages`
for the host's own pacman reconciler, the same NixOS/Arch split
github:julian-corbet/nixdev uses for its whole catalogue). It shares
nothing with the mount mechanism beyond the `nixcloud` option namespace.

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
| `nixcloud.desktop.enable` | bool | `false` | independent of `nixcloud.enable`, see "Desktop client" |
| `nixcloud.desktop.archPackages` | list of str | *(computed)* | `[ "nextcloud-client" ]` when enabled, for the Arch/system-manager side |

Every option carries its full reasoning in `modules/core.nix`'s (mounts)
or `modules/desktop.nix`'s (desktop client) own doc comments -- this
table is a lookup, not a substitute for reading them.

The cluster plane has its own namespace under the same prefix, and is
documented the same way in `modules/cluster.nix`:

| Option | Type | Default | |
|---|---|---|---|
| `nixcloud.clusterPlatform.project` | str | `"cloud"` | delivery project the Applications belong to |
| `nixcloud.clusterPlatform.origin` | null or str | `null` | identity the apps are addressed under, when the render composes a band model |
| `nixcloud.applications.<name>.app` | enum | *(required)* | `opencloud` \| `nextcloud` \| `rclone` |
| `nixcloud.applications.<name>.version` | str | *(required)* | image tag; a whole reference overrides it |
| `nixcloud.applications.<name>.namespace` | str | *(required)* | no default, deliberately -- see "Cluster plane" |
| `nixcloud.applications.<name>.createNamespace` | bool | `false` | exactly one workload may anchor a namespace |
| `nixcloud.applications.<name>.exposure` | enum | `"internal"` | `internal` \| `nb` \| `public` |
| `nixcloud.applications.<name>.scaling` | enum | `"always"` | `always` \| `scale-to-zero`; against the catalogue's answer it warns |
| `nixcloud.applications.<name>.wake` | null or enum | `null` | `keda` \| `sablier` |
| `nixcloud.applications.<name>.adopt` | bool | `false` | takes over objects the cluster already holds: server-side apply and diff. A cluster's history, never the catalogue's |
| `nixcloud.applications.<name>.state.<dir>` | submodule | `{ }` | `claim` or `hostPath`, one of the two, for every directory the catalogue says it writes |
| `nixcloud.applications.<name>.env` | attrs of str | `{ }` | where a deployment's addresses and names arrive |
| `nixcloud.applications.<name>.envFromSecrets` | list of str | `[ ]` | Secrets by NAME, wholesale; nothing here can carry one's contents |
| `nixcloud.applications.<name>.credentialSecrets.<group>.secret` | str | *(required)* | which Secret holds the credential the catalogue named |
| `nixcloud.applications.<name>.credentialSecrets.<group>.keys` | attrs of str | `{ }` | `<VARIABLE> = "<key>"`; defaults to the variable's own name |
| `nixcloud.applications.<name>.resources.requests` | attrs of str | `{ }` | what the scheduler must find for the app's own container |
| `nixcloud.applications.<name>.resources.limits` | attrs of str | `{ }` | ceilings for the app's own container |
| `nixcloud.applications.<name>.companionResources.<c>` | submodule | `{ }` | the same measurement for a container beside it |
| `nixcloud.applications.<name>.image` | null or str | `null` | whole reference; where a digest pin goes |
| `nixcloud.applications.<name>.companionImages` | attrs of str | `{ }` | for containers that run an image of their own |
| `nixcloud.applications.<name>.slot` | null or uint | `null` | a position, never an address |

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
rather than failing opaquely inside rclone at runtime; and the desktop
client (`nixcloud.desktop.enable`) lands in `environment.systemPackages`
independently of `nixcloud.enable`, proven in both directions -- on with
the mount role off, and off with the mount role on.

Two further checks cover the cluster plane, and both build a real nixidy
environment from `examples/all/values.nix` through the real app grammar
rather than a stand-in -- a module that merely *mentions* `nixk3s.apps`
would type-check, which is not the claim being made:

- `cluster-eval` -- the module's own resolution and every guard it makes,
  in both directions. A control case that must render, so that a typo in
  the shared base cannot make the refusals pass for the wrong reason;
  then one otherwise-valid surface per guard with exactly one thing
  wrong, each asserted by the *content* of the message it must produce.
- `cluster-render` -- the manifests that actually come out, read back off
  the rendered YAML with `yq`: which containers exist, which ports reach
  the Service and which must never, that a single-writer Deployment does
  not roll, that a claim and a node path each render as themselves, that
  two namespaces are created and the workload joining one creates
  nothing, that a credential arrives as a `secretKeyRef` and never as a
  `value`, that a measurement lands on the container it was written for
  while an unmeasured one carries no `resources` block at all, and that
  no Secret object exists anywhere in the tree.

## License

MIT.
