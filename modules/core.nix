# modules/core.nix
#
# nixcloud's entire mechanism in one file: the `nixcloud.accounts.<name>`
# schema, the per-account rclone-mount systemd unit each entry generates,
# and the health monitor that watches an already-`active` mount for the
# ONE failure systemd's own unit-state tracking cannot see -- a FUSE
# session that is open, readable-looking to `systemctl`, and permanently
# wedged. Bundled together deliberately, same shape as
# github:julian-corbet/nixshare's own `modules/core.nix`: the supervisor
# reads `cfg.accounts`, so it lives with the schema that defines them
# rather than off in its own file pretending not to know about it.
#
# GENERALISED FROM a private module (infra's own
# modules/nixos/services/network-filesystems/rclone.nix) that squatted
# this project's public namespace before this repo existed. KEPT from it,
# because it was already right and this repo owes it credit rather than
# reinvention:
#
#   - one systemd `Type = "notify"` unit per account, `rclone mount`
#     itself signalling readiness (rclone's own sd_notify support, not a
#     hand-rolled readiness probe);
#   - the SOFT-mount posture: short --timeout/--contimeout/--low-level-
#     retries/--retries so a dead credential or an unreachable backend
#     fails an individual op in seconds, never rclone's 5-minute default,
#     combined with --vfs-cache-mode full so the tree stays browsable
#     through a transient outage from cache;
#   - running the mount PROCESS as root (the standard rclone deployment
#     shape -- unprivileged FUSE needs a setuid fusermount3 wrapper most
#     systems don't provide) while presenting files under an ordinary
#     user's uid/gid via --uid/--gid, so a downstream SMB export or
#     another user's session sees normal ownership, never root's;
#   - a LONGER restart backoff for accounts flagged `fragile` -- a
#     reverse-engineered private-API backend rate-limits or
#     account-locks on a tight restart loop in a way an official OAuth
#     API generally does not, so the difference is preserved per-account
#     instead of being discovered the hard way per provider;
#   - StartLimitBurst + Restart=on-failure with NO unbounded retry: a
#     permanent fault (dead credential, missing config) goes `failed` and
#     STAYS failed instead of looping the journal full -- the account's
#     own state, exposed below as data, reads as a real fault rather than
#     "still trying".
#
# CUT from it, deliberately, and why:
#
#   - the sops-encrypted-config unseal step (`configEnc`/`ageKeyFile`/the
#     `rclone-config-unseal` oneshot). That was a SECRET-PROVISIONING
#     concern tied to one specific unsealing scheme, not a mounting
#     concern -- see `configPath`'s own option doc below. A consumer
#     hands this module an already-readable runtime path however they
#     provision it (sops-nix, agenix, a plain root-only file);
#     `ConditionPathExists=` on every generated unit is the generic
#     replacement for the safety property that step existed to provide
#     (never restart-loop against a config that genuinely isn't there
#     yet) -- without this module hardcoding a `Requires=` on a unit name
#     it cannot know;
#   - the hardcoded provider registry (backend name, "needs 2FA",
#     per-vendor rate-limit notes). That is estate knowledge about which
#     specific clouds one specific operator uses, not a mechanism.
#     `fragile` survives as a plain per-account bool the CONSUMER
#     declares; `provider` survives as a free-form label that only ever
#     affects the mount path and carries no assumed backend behaviour of
#     its own.
#
# THE FAILURE THIS MODULE EXISTS FOR. `systemctl is-active` on a mount
# unit proves the rclone PROCESS is alive; it proves nothing about
# whether the session behind it still works. Several real backends
# (anything reverse-engineered from a private API, rather than a genuine
# OAuth/API-key flow) can hold the FUSE channel open while the
# authenticated session backing it has silently died -- every filesystem
# call against the mount then hangs instead of erroring, and systemd
# reports a perfectly healthy `active` unit the entire time. `nixcloud.
# health` below is what actually watches for that shape and clears it;
# see its option docs and `pkgs/nixcloud-health.nix` for the detection +
# recovery contract.
#
# ONE THING THAT MAKES RECOVERY HERE SIMPLER than the equivalent problem
# on a kernel-mounted network filesystem: every account is its OWN
# isolated FUSE mount, with no shared kernel client underneath it. A
# wedged NFS mount can be sharing a kernel `nfs_client` with every other
# mount of the same server, so curing it means tearing down the whole
# peer group at once (see github:julian-corbet/nixshare's `nixshare-
# health` for exactly that problem, and why it needs one). Here,
# unmounting and restarting the ONE account's unit is the entire cure --
# no peer-group bookkeeping, and no risk of touching a resource a sibling
# mount still holds a reference on.
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.nixcloud;

  accountType = types.submodule (
    { name, ... }:
    {
      options = {
        remote = mkOption {
          type = types.str;
          default = name;
          description = ''
            The `[section]` name in the rclone.conf at `nixcloud.configPath`
            this account mounts -- passed verbatim as `rclone mount
            <remote>:`. Defaults to the attribute name (the common case is
            that they already match), kept as its own field because this
            module's identity for an account -- used for the systemd unit
            suffix and the mount subdirectory -- and the section name a
            separately-managed rclone.conf happens to use are two
            different things that need not move together: renaming one
            here should never force rewriting the other.
          '';
        };

        provider = mkOption {
          type = types.str;
          example = "dropbox";
          description = ''
            Free-form label, purely organisational: this account mounts
            at `<mountRoot>/<provider>/<name>`, grouping every account of
            the same provider under one directory. Carries no assumed
            backend behaviour of its own -- unlike the private module
            this generalises, nixcloud has no built-in table of "provider
            X needs Y". That is estate knowledge and belongs to the
            consumer, not the mechanism.
          '';
        };

        fragile = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Set for a reverse-engineered / private-API backend -- no
            official OAuth or API-key flow -- that punishes a tight
            restart loop by rate-limiting or locking the account out. A
            much longer `RestartSec` applies (see the generated unit)
            instead of the normal fast retry. Left to the consumer to
            declare per account, since only they know which of their own
            remotes are which kind of backend.
          '';
        };

        extraArgs = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "--vfs-cache-mode=writes" "--bwlimit=10M" ];
          description = ''
            Extra `rclone mount` flags, appended after every default this
            module sets. Appended, not prepended: rclone (pflag) takes the
            LAST occurrence of a repeated flag, so listing e.g.
            `--vfs-cache-mode=writes` here overrides the module's own
            `--vfs-cache-mode full` rather than conflicting with it.
            Escape hatch, not the primary tuning surface -- most accounts
            need nothing here.
          '';
        };
      };
    }
  );

  mountPointOf = name: acct: "${cfg.mountRoot}/${acct.provider}/${name}";
  cacheDirOf = name: "${cfg.cacheDir}/${name}";
  unitNameOf = name: "nixcloud-mount-${name}";

  mkAccountUnit =
    name: acct:
    let
      mp = mountPointOf name acct;
      cacheDir = cacheDirOf name;
    in
    nameValuePair (unitNameOf name) {
      description = "rclone FUSE mount: ${acct.provider}/${name} (remote ${acct.remote})";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        # Skips cleanly, no restart loop, when the secret genuinely isn't
        # there yet -- the generic replacement for the private module's
        # unseal-unit `Requires=`; see this file's header "CUT from it".
        # `ConditionPathExists` failing is not a failure state at all (the
        # unit goes `inactive (dead)`, not `failed`), which matters: a
        # config that hasn't landed yet is an ordinary, expected boot-order
        # fact on a fresh host, not a fault to alert on.
        ConditionPathExists = cfg.configPath;
        StartLimitIntervalSec = "1h";
        StartLimitBurst = if acct.fragile then 3 else 5;
      };

      serviceConfig = {
        Type = "notify";
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m0755 ${escapeShellArg mp} ${escapeShellArg cacheDir}";
        # ExecStop tolerates "already gone" -- the health monitor
        # (nixcloud.health) may already have force-unmounted this before
        # systemd ever gets here, and that must not read as a stop failure.
        #
        # The leading "-" is what grants that tolerance, and it is the ONLY thing that can:
        # systemd tokenizes an Exec line itself and never runs a shell, so a trailing `|| true`
        # is not an operator -- it arrives as two more argv entries and fusermount rejects the
        # call outright with "extra arguments after the mountpoint", meaning the unmount is not
        # merely un-tolerated but never attempted, on every stop including the healthy one.
        ExecStop = "-${pkgs.fuse}/bin/fusermount -uz ${escapeShellArg mp}";
        # Recovery's whole cure is `systemctl restart`; it must not itself
        # be the slow part. Bounded well under the health monitor's own
        # cooldown so a stop that hangs on a wedged process still resolves
        # (SIGKILL) before the NEXT health tick would otherwise pile a
        # second recovery attempt on top of one still in flight.
        TimeoutStopSec = "20s";
        Restart = "on-failure";
        RestartSec = if acct.fragile then "300" else "30";
      };

      # uid/gid are resolved at RUNTIME via `id`, not read from
      # `config.users.users.<name>.uid` at Nix eval time. A normal
      # (non-system) NixOS user's uid is assigned at ACTIVATION, not eval
      # time, unless someone has pinned it by hand -- reading `.uid` here
      # would silently be `null` for the common case. Runtime resolution
      # also means `nixcloud.user` works identically whether it names a
      # NixOS-declared user, an externally-provisioned account, or
      # anything else `id` can resolve -- this module never needs to know
      # which.
      script = ''
        if ! id ${escapeShellArg cfg.user} >/dev/null 2>&1; then
          echo "nixcloud-mount-${name}: user '${cfg.user}' (nixcloud.user) does not exist on this system" >&2
          exit 1
        fi
        mount_uid=$(id -u ${escapeShellArg cfg.user})
        mount_gid=$(id -g ${escapeShellArg cfg.user})

        exec ${pkgs.rclone}/bin/rclone mount ${escapeShellArg "${acct.remote}:"} ${escapeShellArg mp} \
          --config ${escapeShellArg cfg.configPath} \
          --vfs-cache-mode full \
          --cache-dir ${escapeShellArg cacheDir} \
          --dir-cache-time 1h \
          --vfs-cache-max-size ${escapeShellArg cfg.cacheMaxSize} \
          --vfs-cache-max-age 168h \
          --vfs-fast-fingerprint \
          --transfers 8 \
          --checkers 16 \
          --timeout 30s \
          --contimeout 15s \
          --low-level-retries 2 \
          --retries 3 \
          --attr-timeout 5s \
          --uid "$mount_uid" \
          --gid "$mount_gid" \
          --allow-other \
          --umask 022 \
          ${concatStringsSep " \\\n          " (map escapeShellArg acct.extraArgs)}
      '';
    };

  # ---------------------------------------------------------------------
  # Health config render -- the tool itself (pkgs/nixcloud-health.nix) is
  # entirely generic; every account-specific fact it needs lives in this
  # one JSON file, read fresh every tick. Same idiom
  # github:julian-corbet/nixshare's own watchdog/health config render
  # uses, for the same reason: the shell tool carries zero project-
  # specific literals.
  # ---------------------------------------------------------------------
  healthConfig = {
    probeTimeoutSec = cfg.health.probeTimeoutSec;
    consecutiveFailures = cfg.health.consecutiveFailures;
    cooldownSec = cfg.health.cooldownSec;
    recovery = cfg.health.recovery;
    stateDir = cfg.health.stateDir;
    statusDir = cfg.health.statusDir;
    accounts = mapAttrsToList
      (name: acct: {
        inherit name;
        provider = acct.provider;
        remote = acct.remote;
        mountpoint = mountPointOf name acct;
        unit = "${unitNameOf name}.service";
      })
      cfg.accounts;
  };

  healthConfigFile = pkgs.writeText "nixcloud-health.json" (builtins.toJSON healthConfig);
in
{
  options.nixcloud = {
    enable = mkEnableOption "declarative rclone FUSE cloud mounts";

    mountRoot = mkOption {
      type = types.path;
      default = "/mnt/clouds";
      description = ''
        Parent directory under which every account mounts, at
        `<mountRoot>/<provider>/<name>`. The intended end state (see
        README) is this whole tree re-exported once, e.g. over SMB, to
        the rest of a fleet -- nixcloud only ever builds the mounts
        themselves and has no opinion on how they're re-shared.
      '';
    };

    configPath = mkOption {
      type = types.path;
      default = "/run/rclone/rclone.conf";
      description = ''
        Runtime path to an already-decrypted, already-readable
        rclone.conf. A SECRET the consumer supplies -- this module never
        generates, decrypts, or inspects the contents of one; it only
        reads this path at mount time (`ConditionPathExists=` on every
        generated unit) and hands it to `rclone --config`. Point it at
        whatever your own secret-provisioning already produces
        (sops-nix, agenix, a plain root-only runtime file) -- see
        README "Secrets" for why the private module's own decrypt step
        was cut rather than ported over.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "root";
      description = ''
        The system user whose uid/gid the mounted files present as
        (rclone's `--uid`/`--gid`) -- what "the user the mounts run as"
        means here, resolved at runtime via `id` (see the generated
        unit's own comment for why not at Nix eval time).

        Deliberately NOT the identity the systemd SERVICE itself runs
        as -- every generated unit executes as root regardless of this
        value. Unprivileged FUSE mounting needs a setuid fusermount3
        wrapper most systems don't provide; running as root is the
        standard rclone deployment shape and sidesteps that entirely.
        This option only controls what OWNERSHIP the mounted files
        present with to everything downstream of the mount (an SMB
        export, a bind mount, another user's session) -- not who can
        start or stop the mount itself.
      '';
    };

    cacheDir = mkOption {
      type = types.path;
      default = "/var/cache/nixcloud";
      description = "Parent directory for per-account VFS cache dirs (rclone --cache-dir), one subdirectory per account.";
    };

    cacheMaxSize = mkOption {
      type = types.str;
      default = "10G";
      description = ''
        Per-mount VFS cache ceiling (`--vfs-cache-max-size`). Bounds how
        much local disk each account's on-demand cache may hold; rclone
        evicts oldest cached files past this. Small-file reads/writes
        serve from this cache at local speed -- the real performance
        lever for whatever re-exports `mountRoot` downstream.
      '';
    };

    accounts = mkOption {
      type = types.attrsOf accountType;
      default = { };
      description = "One declared rclone remote per attribute name -- see README Quickstart for a worked example.";
    };

    health = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Run the mount-health monitor. On by default for the reason
          this project exists: an unattended mount that silently wedges
          -- `active`, readable-looking, and useless -- is exactly the
          failure this module is meant to keep off a consumer's session.
          It only ever acts on a mount that is already `active`, only
          after `consecutiveFailures` sustained bad probes, and never
          more often than once per `cooldownSec`.
        '';
      };

      pollIntervalSec = mkOption {
        type = types.ints.positive;
        default = 60;
        description = "How often to probe every account's mountpoint. Every tick costs two bounded round-trips per mounted account (see probeTimeoutSec).";
      };

      probeTimeoutSec = mkOption {
        type = types.ints.positive;
        default = 10;
        description = ''
          Hard bound on EACH of a tick's two sub-probes (a `stat` and an
          `ls` of the mountpoint -- see pkgs/nixcloud-health.nix), so a
          fully wedged mount cannot itself wedge the monitor; worst case
          one account's check is bounded by twice this value. A timeout
          counts as the most degraded reading there is.
        '';
      };

      consecutiveFailures = mkOption {
        type = types.ints.positive;
        default = 3;
        description = ''
          How many consecutive degraded ticks before recovery is
          attempted. Hysteresis is what keeps a large in-flight transfer
          or a slow backend response from triggering a force-unmount;
          the session-death wedge this targets does not clear on its
          own, so waiting a few extra ticks costs nothing real.
        '';
      };

      cooldownSec = mkOption {
        type = types.ints.positive;
        default = 600;
        description = "Minimum interval between recovery attempts for the same account. Bounds the damage if recovery does not actually help (a permanently dead credential, say) -- the monitor keeps reporting degraded and waits rather than looping a disruptive unmount/restart.";
      };

      recovery = mkOption {
        type = types.enum [ "alert" "recover" ];
        default = "recover";
        description = ''
          `alert`   : detect and report only, via the status data below;
                      never force-unmount or restart anything.
          `recover` : force-unmount (`fusermount -uz`, falling back to
                      `umount -f -l`) and `systemctl restart` the
                      account's own unit once `consecutiveFailures` is
                      reached. Both operations act on this ONE account's
                      mount only -- see this file's header for why no
                      wider (peer-group) teardown is ever needed here.
        '';
      };

      stateDir = mkOption {
        type = types.path;
        default = "/run/nixcloud/state";
        description = "Where the monitor keeps its cross-tick state (consecutive-failure counts, recovery cooldown stamps). On tmpfs by design -- a reboot clears mount state anyway, so a stale counter must not survive one.";
      };

      statusDir = mkOption {
        type = types.path;
        default = "/run/nixcloud/status";
        description = ''
          Where the monitor writes its DATA -- one `<name>.json` per
          account plus a combined `summary.json`, every tick, whether
          the account is healthy or not. This is the entire interface
          nixcloud offers a consumer's own monitoring: it is deliberately
          just files to read, not a push, a webhook, or a bundled
          alerting integration. See README "Health data" for the shape
          and a worked example of wiring it into an existing check.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.callPackage ../pkgs/nixcloud-health.nix { };
        description = "The nixcloud-health executable. Override only to pin/patch a build.";
      };
    };
  };

  config = mkIf cfg.enable (
    mkMerge [
      {
        assertions = mapAttrsToList
          (name: acct: {
            assertion = acct.remote != "";
            message = "nixcloud.accounts.${name}.remote resolved to an empty string -- rclone would be run as \"rclone mount :\", which cannot work.";
          })
          cfg.accounts;

        # rclone mounts run with --allow-other so a downstream re-export
        # (Samba, a bind mount, another user's session) can read them even
        # though the mount process itself is root. NixOS' own
        # programs.fuse.userAllowOther has been observed to not reliably
        # materialize this file across releases -- written directly rather
        # than depended on.
        environment.etc."fuse.conf".text = ''
          user_allow_other
        '';

        systemd.tmpfiles.rules = [ "d ${cfg.cacheDir} 0755 root root -" ];

        systemd.services = listToAttrs (mapAttrsToList mkAccountUnit cfg.accounts);

        # The operator's own `rclone` on PATH -- for a human running `rclone lsd remote:`,
        # `rclone config`, or diagnosing a mount by hand, never for the mounts themselves: every
        # generated unit above already invokes this exact `pkgs.rclone` by store path, so the FUSE
        # mounts never depended on this line and would keep working without it. Gated on
        # `cfg.enable`, the same condition as everything else in this block, so a consumer who
        # imports this module without turning it on does not silently gain a package.
        environment.systemPackages = [ pkgs.rclone ];
      }

      (mkIf cfg.health.enable {
        environment.etc."nixcloud/health.json".source = healthConfigFile;

        systemd.services.nixcloud-health = {
          description = "nixcloud health: detect a wedged rclone FUSE session and clear it before it hangs a consumer";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${cfg.health.package}/bin/nixcloud-health";
            RuntimeDirectory = "nixcloud";
            RuntimeDirectoryPreserve = "yes";
            # Unsandboxed, same load-bearing reason as
            # github:julian-corbet/nixshare's own watchdog/health units:
            # recovery's `fusermount -uz`/`umount -f -l` and `systemctl
            # restart` must land in the HOST's real, shared mount
            # namespace. Any of systemd's namespace-based hardening gives
            # the unit its OWN private mount namespace, silently turning
            # every force-unmount into a no-op as far as whatever actually
            # reads `mountRoot` is concerned.
          };
        };

        systemd.timers.nixcloud-health = {
          description = "Poll nixcloud mounts for a wedged FUSE session";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "${toString cfg.health.pollIntervalSec}s";
            OnUnitInactiveSec = "${toString cfg.health.pollIntervalSec}s";
            Unit = "nixcloud-health.service";
          };
        };
      })
    ]
  );
}
