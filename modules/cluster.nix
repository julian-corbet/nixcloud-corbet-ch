#
# nixcloud's cluster surface: catalogue document clouds and translate them through the shared app
# grammar. The factory owns the repeated application/namespace/slot machinery; this adapter keeps
# the parts that are true only of document clouds: a FastCGI front, a run-once-if-absent bootstrap,
# plain service settings distinct from credentials, and state that must never be silently empty.
#
{ mkConsumerModule }:

{ lib, ... }:

let
  rawCatalogue = (import ../lib/applications.nix { }).applications;

  # The factory's generic idle rule is deliberately stricter than this established public surface.
  # Keep the catalogue fact under its existing `sleepSafe` name and publish this domain's warning
  # below: a cluster, rather than a catalogue, owns the decision to accept the cold-start cost.
  catalogue = lib.mapAttrs (_: entry: entry // {
    idleSafe = true;

    # nixcloud's established catalogue has one dependency role mapping to SEVERAL literal
    # environment variables. The shared term is intentionally disabled below because its typed
    # endpoint model is not this public contract. Keep the raw map under an adapter-private name,
    # make the factory-facing field empty, and translate/validate it in `extendApp` and the domain
    # assertions rather than pretending that one of the variables is the dependency.
    legacyRequires = entry.requires;
    requires = { };
  }) rawCatalogue;

  mountOf = m: {
    inherit (m) mountPath;
    subPath = m.subPath or null;
    readOnly = m.readOnly or false;
  };

  mountsOf = mounts: lib.mapAttrs (_: entries: map mountOf entries) mounts;

  imageOf = x:
    if x.w.image != null then x.w.image else "${x.entry.image}:${x.w.version}";

  securityOf = unprivileged:
    lib.optionalAttrs unprivileged {
      allowPrivilegeEscalation = false;
      capabilitiesDrop = [ "ALL" ];
    };

  probesOf = container:
    lib.optionalAttrs (container.readiness != null) {
      readiness = { port = container.primaryPort; } // container.readiness;
    }
    // lib.optionalAttrs (container.liveness != null) {
      liveness = { port = container.primaryPort; } // container.liveness;
    };

  # Keep lookup total. The factory owns the state-key assertion, so a misspelled public key gets
  # its diagnostic instead of an attribute-missing evaluation failure while that diagnostic is made.
  stateOf = x:
    lib.mapAttrs
      (key: backing: {
        mounts = map mountOf (x.entry.state.${key}.mounts or [ ]);
        inherit (backing) claim hostPath hostPathType readOnly;
      })
      (lib.filterAttrs (key: _: x.entry.state ? ${key}) x.w.state);

  secretsOf = x:
    let
      wholesale = lib.listToAttrs (map
        (secret: lib.nameValuePair secret { inherit secret; envFrom = true; })
        x.w.envFromSecrets);
      keyedFor = secret:
        lib.concatMapAttrs
          (group: declaration:
            lib.optionalAttrs (declaration.secret == secret)
              (lib.listToAttrs (map
                (variable: lib.nameValuePair variable (declaration.keys.${variable} or variable))
                (x.entry.credentials.${group} or [ ]))))
          x.w.credentialSecrets;
      keyed = lib.listToAttrs (map
        (declaration: lib.nameValuePair declaration.secret {
          secret = declaration.secret;
          env = keyedFor declaration.secret;
        })
        (lib.attrValues x.w.credentialSecrets));
    in
    lib.zipAttrsWith (_: lib.foldl' lib.recursiveUpdate { }) [ wholesale keyed ];

  companionImageOf = x: name: container:
    if container.image == null then imageOf x
    else x.w.companionImages.${name} or container.image;

  portsOf = ports:
    lib.mapAttrs (_: port: {
      inherit (port) number;
      publish = port.publish or true;
      servicePort = port.servicePort or null;
    }) ports;

  companionsOf = x:
    lib.mapAttrs
      (name: container: {
        image = companionImageOf x name container;
        inherit (container) command args env;
        ports = portsOf container.ports;
        mounts = mountsOf container.mounts;
        security = securityOf container.unprivileged;
        probes = probesOf container;
        resources = x.w.companionResources.${name} or { requests = { }; limits = { }; };
      })
      x.entry.companions;

  initOf = x:
    map
      (container: {
        inherit (container) name command args env;
        image = if container.image == null then imageOf x else container.image;
        mounts = mountsOf container.mounts;
        security = securityOf container.unprivileged;
      })
      x.entry.init;

  extendApp = x:
    x.app // {
      image = imageOf x;
      inherit (x.entry) command;
      args = x.entry.args ++ x.w.args;
      env = x.entry.env // x.w.env;
      ports = portsOf x.entry.ports;
      state = stateOf x;
      secrets = secretsOf x;
      security = securityOf x.entry.unprivileged;
      probes = probesOf x.entry;
      companions = companionsOf x;
      init = initOf x;
      resources = x.w.resources;
    };

  requirementAssertions = workloads:
    lib.concatMap
      (x:
        let
          missing = variables: lib.filter (variable: !(x.w.env ? ${variable})) variables;
          missingIdentity = missing x.entry.publicIdentity;
        in
        lib.mapAttrsToList
          (service: variables: {
            assertion = missing variables == [ ];
            message =
              "nixcloud: application `${x.name}` must be told where to find its `${service}`, and "
              + lib.concatMapStringsSep ", " (variable: "`${variable}`") (missing variables)
              + " ${if lib.length (missing variables) == 1 then "is" else "are"} unset. `${x.selected}` "
              + "does not run that service itself and will not invent an address for it; supply the values in `env`.";
          })
          x.entry.legacyRequires
        ++ [
          {
            assertion = missingIdentity == [ ];
            message =
              "nixcloud: application `${x.name}` must be told the name it is reached at, and "
              + lib.concatMapStringsSep ", " (variable: "`${variable}`") missingIdentity
              + " ${if lib.length missingIdentity == 1 then "is" else "are"} unset. Everything `${x.selected}` "
              + "sees is a proxied request, so it cannot derive its own address.";
          }
        ])
      workloads;

  credentialAssertions = workloads:
    lib.concatMap
      (x:
        let
          groups = lib.attrNames x.entry.credentials;
          given = lib.attrNames x.w.credentialSecrets;
          requiredMissing = lib.filter (group: !(x.w.credentialSecrets ? ${group})) groups;
          unknown = lib.filter (group: !(lib.elem group groups)) given;
          credentialVariables = lib.concatLists (lib.attrValues x.entry.credentials);
          plain = lib.filter (variable: x.w.env ? ${variable}) credentialVariables;
        in
        [
          {
            assertion = requiredMissing == [ ];
            message =
              "nixcloud: application `${x.name}` reads a credential from "
              + lib.concatMapStringsSep ", " (group: "`${group}`") requiredMissing
              + " and no Secret was named for it. Name one in `credentialSecrets`; `envFromSecrets` does not answer this.";
          }
          {
            assertion = unknown == [ ];
            message =
              "nixcloud: application `${x.name}` names a Secret for "
              + lib.concatMapStringsSep ", " (group: "`${group}`") unknown
              + ", which is not a credential `${x.selected}` reads.";
          }
          {
            assertion = plain == [ ];
            message =
              "nixcloud: application `${x.name}` sets "
              + lib.concatMapStringsSep ", " (variable: "`${variable}`") plain
              + " in `env`, and the catalogue records it as a credential. `env` is plain text in a file written to be published.";
          }
        ]
        ++ lib.mapAttrsToList
          (group: declaration:
            let
              known = x.entry.credentials.${group} or [ ];
              stray = lib.filter (variable: !(lib.elem variable known)) (lib.attrNames declaration.keys);
            in {
              assertion = stray == [ ];
              message =
                "nixcloud: application `${x.name}` maps a key of Secret `${declaration.secret}` onto "
                + lib.concatMapStringsSep ", " (variable: "`${variable}`") stray
                + ", which `${x.selected}` does not read as part of `${group}`.";
            })
          x.w.credentialSecrets)
      workloads;

  companionResourceAssertions = workloads:
    lib.concatMap
      (x:
        let
          stray = lib.filter (name: !(x.entry.companions ? ${name}))
            (lib.attrNames x.w.companionResources);
        in [{
          assertion = stray == [ ];
          message =
            "nixcloud: application `${x.name}` sizes "
            + lib.concatMapStringsSep ", " (name: "`${name}`") stray
            + ", which is not a container of `${x.selected}`. A request against a container that does not exist is a number the scheduler never sees.";
        }])
      workloads;

  sleepWarnings = workloads:
    lib.concatMap
      (x: lib.optional (x.w.scaling == "scale-to-zero" && !x.entry.sleepSafe) {
        when = true;
        message =
          "nixcloud: application `${x.name}` is declared scale-to-zero, and the catalogue records that "
          + "`${x.selected}` does not idle safely -- it has work that happens while nobody is looking, or clients "
          + "that hold a connection open expecting it to be there.";
      })
      workloads;

  resourceOptions = {
    requests = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
    limits = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
  };

  stateOption = lib.mkOption {
    default = { };
    description = "Claim-or-hostPath backing for every directory the selected catalogue entry writes.";
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        claim = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        hostPath = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        hostPathType = lib.mkOption { type = lib.types.str; default = "Directory"; };
        readOnly = lib.mkOption { type = lib.types.bool; default = false; };
      };
    });
  };

  resourcesOption = lib.mkOption {
    default = { requests = { }; limits = { }; };
    type = lib.types.submodule { options = resourceOptions; };
  };

  companionResourcesOption = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule { options = resourceOptions; });
    default = { };
  };

  envFromSecretsOption = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Existing Secrets loaded wholesale into the environment.";
  };

  credentialSecretsOption = lib.mkOption {
    default = { };
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        secret = lib.mkOption { type = lib.types.str; };
        keys = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
      };
    });
  };

  factoryModule = mkConsumerModule {
    namespace = "nixcloud";
    platformOption = "clusterPlatform";
    publishPlatformOptions = false;
    platformOf = { consumer, ... }: {
      inherit (consumer.clusterPlatform) project origin;
      namespace = "nixcloud-declaration-namespace";
    };
    originOptionPath = [ "nixcloud" "clusterPlatform" "origin" ];
    roots.applications = {
      inherit catalogue;
      selector = "app";
      enabledOptions = [
        "version" "image" "companionImages" "namespace" "createNamespace" "project"
        "slot" "exposure" "scaling" "wake" "adopt" "state" "env" "args"
      ];
      extraOptions = {
        version = lib.mkOption {
          type = lib.types.str;
          description = "Which version this workload runs, used as the image tag. Required and defaulted nowhere.";
        };
        state = stateOption;
        resources = resourcesOption;
        companionResources = companionResourcesOption;
        envFromSecrets = envFromSecretsOption;
        credentialSecrets = credentialSecretsOption;
      };
      extend = extendApp;
    };
    extraNamespaceOptions.clusterPlatform = {
      project = lib.mkOption { type = lib.types.str; default = "cloud"; };
      origin = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    };
    extraAssertions = workloads:
      requirementAssertions workloads
      ++ credentialAssertions workloads
      ++ companionResourceAssertions workloads;
    extraWarnings = sleepWarnings;
  };
in
{
  imports = [ factoryModule ];
}
