{
  description = "nixcloud - declarative rclone FUSE cloud mounts, with a health monitor that catches a wedged private-API session before it hangs a consumer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems f;
    in
    {
      # NixOS-only, deliberately -- unlike some family siblings this is not
      # portable to system-manager. rclone-mount-as-a-server-role is
      # inherently a bare-metal-host concept (the operator end state,
      # README's own framing: ONE rclone client on a server, re-exported to
      # a fleet), not something a desktop session needs its own copy of.
      nixosModules.core = ./modules/core.nix;
      nixosModules.default = self.nixosModules.core;

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          nixcloud-health = pkgs.callPackage ./pkgs/nixcloud-health.nix { };
          default = self.packages.${system}.nixcloud-health;
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          bareStubs = {
            boot.loader.grub.enable = false;
            fileSystems."/" = {
              device = "none";
              fsType = "tmpfs";
            };
            system.stateVersion = "25.05";
          };

          host = lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              ./examples/host/configuration.nix
              bareStubs
            ];
          };

          units = host.config.systemd.services;

          # A required option (no default -- accounts.<name>.provider) with
          # nothing supplied is a MISSING-VALUE error, not a
          # `config.assertions` failure -- only forced deep enough to
          # surface by reaching `.drvPath` (which walks into whatever
          # actually consumes the option), not by a bare `seq` of the
          # `system.build.toplevel` attrset. Same helper shape
          # github:julian-corbet/nixbackup's own checks use for the same
          # proof.
          buildFailsWith =
            extraConfig:
              !(
                builtins.tryEval (
                  builtins.seq
                    (builtins.unsafeDiscardStringContext
                      (lib.nixosSystem {
                        inherit system;
                        modules = [
                          self.nixosModules.default
                          extraConfig
                          bareStubs
                        ];
                      }).config.system.build.toplevel.drvPath
                    )
                    true
                )
              ).success;
        in
        {
          # 1. Does the whole example host evaluate? Catches type errors,
          #    failed assertions, and option renames across the module at
          #    once -- including that `nixcloud.user = "cloudmount"`, never
          #    declared in `users.users`, does NOT fail eval (proving uid/
          #    gid resolution really is deferred to runtime, not looked up
          #    from `config.users.users.<name>.uid` here).
          #
          #    String context around the derivation path is discarded on
          #    purpose: kept, this BUILDS an entire NixOS system instead of
          #    evaluating one -- minutes and a multi-gigabyte download
          #    instead of seconds.
          modules-evaluate = pkgs.writeText "nixcloud-host-drvpath" (
            builtins.unsafeDiscardStringContext host.config.system.build.toplevel.drvPath
          );

          # 2. Mount path composition: <mountRoot>/<provider>/<name>, and
          #    the `remote` field defaulting to the attribute name when
          #    omitted (the "personal" account) vs. staying independent
          #    when set explicitly (the "work" account's remote is
          #    "work-remote", not "work").
          mount-paths-compose-from-root-provider-name =
            let
              personal = units.nixcloud-mount-personal.script;
              work = units.nixcloud-mount-work.script;
              ok =
                lib.strings.hasInfix "/mnt/clouds/dropbox/personal" personal
                && lib.strings.hasInfix "rclone mount personal: " personal
                && lib.strings.hasInfix "/mnt/clouds/dropbox/work" work
                && lib.strings.hasInfix "rclone mount work-remote: " work
                # NOT "rclone mount work:" -- that substring match alone would
                # miss the bug this guards against, since the account's own
                # unit/echo text elsewhere legitimately contains "work:" (from
                # "nixcloud-mount-work: user ..."). Anchoring on "rclone
                # mount " is what actually pins the remote passed to rclone,
                # not just any appearance of the word.
                && !(lib.strings.hasInfix "rclone mount work: " work);
            in
            if ok then
              pkgs.runCommand "nixcloud-check-mount-paths" { } "echo ok > $out"
            else
              throw "nixcloud: expected mountRoot/provider/name composition and remote-vs-name independence to hold; see rendered scripts:\n--- personal ---\n${personal}\n--- work ---\n${work}";

          # 3. `fragile` actually changes the generated unit's backoff,
          #    the whole point of the field: a longer RestartSec and a
          #    smaller StartLimitBurst than the non-fragile default.
          fragile-flag-changes-restart-backoff =
            let
              personal = units.nixcloud-mount-personal;
              work = units.nixcloud-mount-work;
              ok =
                personal.serviceConfig.RestartSec == "30"
                && personal.unitConfig.StartLimitBurst == 5
                && work.serviceConfig.RestartSec == "300"
                && work.unitConfig.StartLimitBurst == 3;
            in
            if ok then
              pkgs.runCommand "nixcloud-check-fragile-backoff" { } "echo ok > $out"
            else
              throw ''
                nixcloud: expected fragile=true (account "work") to render RestartSec=300/StartLimitBurst=3
                and fragile=false (account "personal") to render RestartSec=30/StartLimitBurst=5, got:
                personal: RestartSec=${personal.serviceConfig.RestartSec} StartLimitBurst=${toString personal.unitConfig.StartLimitBurst}
                work:     RestartSec=${work.serviceConfig.RestartSec} StartLimitBurst=${toString work.unitConfig.StartLimitBurst}
              '';

          # 4. extraArgs reach the rendered script AND actually land AFTER
          #    the module's own default for the same flag, since that is
          #    the entire point of appending rather than prepending them
          #    (rclone/pflag takes the LAST occurrence -- see
          #    accountType.extraArgs' own description). Splitting on the
          #    module's own default flag text and requiring exactly one
          #    split point proves both "appears" and "appears after" at
          #    once: if extraArgs had been prepended instead, the override
          #    text would be in the FIRST part, not the second.
          extra-args-are-appended-and-override-defaults =
            let
              work = units.nixcloud-mount-work.script;
              parts = lib.splitString "--vfs-cache-mode full" work;
              ok = lib.length parts == 2 && lib.strings.hasInfix "--vfs-cache-mode=writes" (lib.elemAt parts 1);
            in
            if ok then
              pkgs.runCommand "nixcloud-check-extra-args" { } "echo ok > $out"
            else
              throw "nixcloud: expected accounts.work.extraArgs' --vfs-cache-mode=writes to appear exactly once, AFTER (and thus win over) the module's own --vfs-cache-mode full, got:\n${work}";

          # 5. Every generated unit gates on the SAME configPath via
          #    ConditionPathExists -- the generic, consumer-agnostic
          #    replacement for the private module's hardcoded unseal-unit
          #    Requires= (see modules/core.nix header "CUT from it").
          # ExecStop must tolerate an already-unmounted path WITHOUT shell syntax. systemd
          # tokenizes an Exec line and never runs a shell, so a trailing `|| true` arrives as
          # two extra argv entries; fusermount then rejects the whole call with "extra
          # arguments after the mountpoint" and never attempts the unmount -- on every stop,
          # including the healthy one. The leading "-" is the only mechanism that grants
          # tolerance here, so assert the shape rather than trusting a comment.
          execstop-tolerates-without-shell-syntax =
            let
              stop = units.nixcloud-mount-personal.serviceConfig.ExecStop;
              hasShellOps = builtins.match ".*(\\|\\||&&|;).*" stop != null;
              tolerated = builtins.substring 0 1 stop == "-";
              ok = tolerated && !hasShellOps;
            in
            if ok then
              pkgs.runCommand "nixcloud-check-execstop" { } "echo ok > $out"
            else
              throw "nixcloud: ExecStop must start with '-' and contain no shell operators (systemd does not run a shell), got: ${stop}";

          units-condition-on-config-path =
            let
              personal = units.nixcloud-mount-personal.unitConfig.ConditionPathExists;
              work = units.nixcloud-mount-work.unitConfig.ConditionPathExists;
              ok = personal == "/run/rclone/rclone.conf" && work == personal;
            in
            if ok then
              pkgs.runCommand "nixcloud-check-condition-path" { } "echo ok > $out"
            else
              throw "nixcloud: expected every generated unit's ConditionPathExists to equal nixcloud.configPath, got personal=${personal} work=${work}";

          # 6. `/etc/nixcloud/health.json` -- what the health tool actually
          #    reads (pkgs/nixcloud-health.nix) -- is wired to the exact
          #    same derivation this check independently recomputes from
          #    `nixcloud.accounts`/`nixcloud.mountRoot`, proving the config
          #    the RUNNING TOOL sees is not just "some file exists" but
          #    the accounts declared in this example, addressed the same
          #    way the rest of these checks already proved the mount units
          #    themselves are addressed.
          #
          #    Deliberately compares against `environment.etc` as a plain
          #    Nix value (the `source` derivation, `text`/absence), never
          #    `builtins.readFile`s the rendered store path -- that would
          #    force a real build during flake evaluation (import-from-
          #    derivation) for no benefit over comparing the two
          #    derivations were built from equal inputs.
          health-config-is-wired-to-declared-accounts =
            let
              healthEtc = host.config.environment.etc."nixcloud/health.json";
              expected = pkgs.writeText "nixcloud-health.json" (
                builtins.toJSON {
                  probeTimeoutSec = host.config.nixcloud.health.probeTimeoutSec;
                  consecutiveFailures = host.config.nixcloud.health.consecutiveFailures;
                  cooldownSec = host.config.nixcloud.health.cooldownSec;
                  recovery = host.config.nixcloud.health.recovery;
                  stateDir = host.config.nixcloud.health.stateDir;
                  statusDir = host.config.nixcloud.health.statusDir;
                  accounts = [
                    {
                      name = "personal";
                      provider = "dropbox";
                      remote = "personal";
                      mountpoint = "/mnt/clouds/dropbox/personal";
                      unit = "nixcloud-mount-personal.service";
                    }
                    {
                      name = "work";
                      provider = "dropbox";
                      remote = "work-remote";
                      mountpoint = "/mnt/clouds/dropbox/work";
                      unit = "nixcloud-mount-work.service";
                    }
                  ];
                }
              );
            in
            if healthEtc.source == expected then
              pkgs.runCommand "nixcloud-check-health-config" { } "echo ok > $out"
            else
              throw "nixcloud: /etc/nixcloud/health.json's rendered derivation did not match the independently-expected one built from nixcloud.accounts -- a field was renamed, dropped, or computed differently on one side";

          # 7. accounts.<name>.provider has no default -- omitting it must
          #    fail the build, supplying it must succeed. Proven in BOTH
          #    directions, not just "it evaluates when every field is
          #    filled in".
          provider-is-required =
            let
              missing = buildFailsWith {
                nixcloud = {
                  enable = true;
                  accounts.example = { };
                };
              };
              present = buildFailsWith {
                nixcloud = {
                  enable = true;
                  accounts.example.provider = "example-provider";
                };
              };
            in
            if missing && !present then
              pkgs.runCommand "nixcloud-check-provider-required" { } "echo ok > $out"
            else
              throw "nixcloud.accounts.<name>.provider: expected omitting it to fail the build and supplying it to succeed, got missing=${toString missing} present=${toString present}";

          # 8. accounts.<name>.remote resolving to an empty string is
          #    caught by an eval-time assertion, not left to fail
          #    opaquely inside rclone at runtime as `rclone mount :`.
          empty-remote-is-rejected =
            let
              badEval = builtins.tryEval (
                lib.nixosSystem {
                  inherit system;
                  modules = [
                    self.nixosModules.default
                    {
                      nixcloud = {
                        enable = true;
                        accounts.example = {
                          provider = "example-provider";
                          remote = "";
                        };
                      };
                    }
                    bareStubs
                  ];
                }
              ).config.system.build.toplevel;
            in
            if !badEval.success then
              pkgs.runCommand "nixcloud-check-empty-remote-rejected" { } "echo ok > $out"
            else
              throw "nixcloud.accounts.<name>.remote = \"\": expected the eval-time assertion to reject this, but the build evaluated successfully";

          # 9. The operator's own `rclone` reaches environment.systemPackages, and it is the exact
          #    same derivation the generated mount units invoke by store path -- one source of
          #    truth, not a second independently-resolved reference. Also proves the package is
          #    gated on `nixcloud.enable`, not unconditional: a host that imports the module but
          #    never enables it must not gain the package.
          rclone-package-is-declared-and-shared-with-mount-units =
            let
              inEnv = lib.any (p: p == pkgs.rclone) host.config.environment.systemPackages;
              # hasInfix runs on builtins.match under the hood, which refuses a pattern argument
              # that carries string context -- context is discarded here on the SEARCH string only
              # (never on the script being searched), same idiom as "modules-evaluate" above.
              usedByUnit = lib.strings.hasInfix
                (builtins.unsafeDiscardStringContext "${pkgs.rclone}/bin/rclone mount")
                units.nixcloud-mount-personal.script;
              disabledHost = lib.nixosSystem {
                inherit system;
                modules = [
                  self.nixosModules.default
                  bareStubs
                ];
              };
              absentWhenDisabled = !(lib.any (p: p == pkgs.rclone) disabledHost.config.environment.systemPackages);
              ok = inEnv && usedByUnit && absentWhenDisabled;
            in
            if ok then
              pkgs.runCommand "nixcloud-check-rclone-package" { } "echo ok > $out"
            else
              throw "nixcloud: expected pkgs.rclone in environment.systemPackages (same derivation the mount units use) when enabled, and absent when nixcloud.enable = false, got inEnv=${toString inEnv} usedByUnit=${toString usedByUnit} absentWhenDisabled=${toString absentWhenDisabled}";
        }
      );
    };
}
