# Proves the cluster module resolves what it claims and REFUSES what it claims to refuse, both
# directions, through the real renderer and the real app grammar.
#
# Both halves matter and neither is enough alone. A guard nobody has watched fire is a comment; a
# guard that fires on everything is a wall. So every case below is a complete, otherwise-valid
# surface with exactly one thing wrong, and the `control` case is the same shape with nothing wrong
# and MUST render -- without it, a typo in the shared base would make every other case "pass" for
# the wrong reason.
#
# THREE OF THE REFUSALS ARE NOT GUARDS AT ALL. Naming an application the catalogue does not hold,
# leaving out the version, and leaving out the namespace fail as a type error and two missing
# required options -- not as assertions. That is the stronger kind: a boundary nobody has to
# remember, because it is unwritable rather than refused. `tryEval` cannot tell those apart from a
# guard, so the ones that ARE guards additionally have their message asserted by content.
{ pkgs, lib, nixidy, appsModule, clusterModule, values }:

let
  base = import values;

  mkEnv = v: nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule clusterModule v ];
  };

  # `tryEval` alone forces only WHNF. Forcing the derivation path is what actually runs the module
  # system's type checks and the assertions underneath.
  renders = v: (builtins.tryEval (builtins.seq (mkEnv v).environmentPackage.drvPath true)).success;

  # EVERY assertion in the stack, from both places they live. This module's own land on the
  # environment; the app grammar's land on each Application it renders, and a refusal that comes
  # from the layer owning the term is still this surface refusing. Searching only one of the two
  # would quietly turn "the grammar caught it" into "nothing caught it".
  assertionsOf = v:
    let c = (mkEnv v).config; in
    c.nixidy.assertions ++ lib.concatMap (a: a.assertions) (lib.attrValues c.applications);

  warningsOf = v:
    let c = (mkEnv v).config; in
    c.nixidy.warnings ++ lib.concatMap (a: a.warnings) (lib.attrValues c.applications);

  # An assertion fired, AND it is the one meant: a refusal that happens for an unrelated reason is
  # a false pass, which is exactly the failure this repository's checks exist to make impossible.
  failsWith = infix: v:
    let
      r = builtins.tryEval (lib.any
        (a: !a.assertion && lib.hasInfix infix a.message)
        (assertionsOf v));
    in
    r.success && r.value;

  warnsWith = infix: v:
    let
      r = builtins.tryEval (lib.any
        (w: w.when && lib.hasInfix infix w.message)
        (warningsOf v));
    in
    r.success && r.value;

  # A surface with nothing declared at all, to prove the module is inert until something asks.
  emptyCfg = (mkEnv {
    nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
    nixidy.target.branch = "main";
  }).config;

  goodCfg = (mkEnv base).config;
  apps = goodCfg.nixk3s.apps;

  with' = f: lib.recursiveUpdate base f;

  # The declaration whose environment is complete, rebuilt one variable short. `recursiveUpdate`
  # cannot REMOVE an attribute, so the whole set is replaced with a copy missing one -- which is
  # also the honest shape of the mistake being tested: somebody wrote out the environment and left
  # a line out of it.
  filesEnvWithout = names: with' {
    nixcloud.applications.example-files.env =
      lib.mkForce (removeAttrs base.nixcloud.applications.example-files.env names);
  };

  results = {
    # ── The control, and the floor ────────────────────────────────────────────────────────────
    "the example surface renders -- without this every refusal below could pass for the wrong reason" =
      renders base;

    "an undeclared surface renders no apps at all, rather than a default one" =
      emptyCfg.nixk3s.apps == { };

    "all three declared workloads reach the grammar" =
      lib.sort (a: b: a < b) (lib.attrNames apps)
      == [ "example-documents" "example-files" "example-transfers" ];

    # ── What the catalogue supplies and the declaration never states ──────────────────────────
    "the catalogue supplies every port, and no declaration states one" =
      apps.example-documents.ports.http.number == 9200
      && apps.example-transfers.ports.http.number == 5572
      && apps.example-files.ports.fpm.number == 9000;

    "the port a browser reaches is on the web front, and carries a Service number of its own" =
      apps.example-files.companions.web.ports.http.number == 8080
      && apps.example-files.companions.web.ports.http.servicePort == 80;

    "a FastCGI socket is a real port that must never reach a Service" =
      !apps.example-files.ports.fpm.publish
      && !apps.example-files.companions.realtime.ports.push.publish;

    "a version becomes the tag, and a whole reference overrides it" =
      apps.example-documents.image == "opencloudeu/opencloud-rolling:0.0.0"
      && lib.hasInfix "@sha256:" apps.example-files.image;

    "a companion that ships inside the application's installation runs the application's image" =
      apps.example-files.companions.realtime.image == apps.example-files.image;

    "a companion that runs an image of its own runs the one the declaration named" =
      apps.example-files.companions.web.image == base.nixcloud.applications.example-files.companionImages.web
      && apps.example-files.companions.web.image != apps.example-files.image;

    "the catalogue supplies WHERE a directory lives and the declaration supplies WHAT BACKS IT" =
      (lib.head apps.example-documents.state.state.mounts).mountPath == "/var/lib/opencloud"
      && apps.example-documents.state.state.hostPath == "/example/state/documents"
      && apps.example-files.state.data.claim == "example-files-documents";

    "one curated directory is mounted more than once, and the second view is a subPath of the first" =
      lib.length apps.example-documents.state.state.mounts == 2
      && (lib.elemAt apps.example-documents.state.state.mounts 1).subPath == "config"
      && (lib.elemAt apps.example-documents.state.state.mounts 1).mountPath == "/etc/opencloud";

    "three containers share one code tree, and only the one that serves it reads it read-only" =
      apps.example-files.companions.web.mounts.html != [ ]
      && (lib.head apps.example-files.companions.web.mounts.html).readOnly
      && !(lib.head apps.example-files.companions.realtime.mounts.html).readOnly;

    "a node path that must already exist refuses to start rather than inventing an empty cloud" =
      apps.example-documents.state.state.hostPathType == "Directory";

    "the probe that decides when traffic arrives is on the container that answers it" =
      apps.example-files.probes.readiness == null
      && apps.example-files.companions.web.probes.readiness.port == "http"
      && apps.example-files.companions.web.probes.readiness.path == "/status.php";

    "a probe with no cheap endpoint asks the socket, with the budget a slow start needs" =
      apps.example-documents.probes.readiness.path == null
      && apps.example-documents.probes.readiness.failureThreshold == 30
      && apps.example-transfers.probes.readiness.periodSeconds == 5;

    "a first-boot init container runs the application's own image against its own volume" =
      lib.length apps.example-documents.init == 1
      && (lib.head apps.example-documents.init).image == apps.example-documents.image
      && (lib.head apps.example-documents.init).mounts.state != [ ];

    "a Secret is named and never carried" =
      apps.example-transfers.secrets ? example-transfers-auth
      && apps.example-transfers.secrets.example-transfers-auth.envFrom;

    "the catalogue's environment and the deployment's are merged, not chosen between" =
      apps.example-documents.env.STORAGE_USERS_DRIVER == "posix"
      && apps.example-documents.env.OC_DOMAIN == "cloud.example.com";

    # ── Unwritable, not merely refused ────────────────────────────────────────────────────────
    "an application the catalogue does not hold is not a value this option has" =
      !renders (with' { nixcloud.applications.example-documents.app = "nonesuch"; });

    "a workload with no version is refused, because a floating tag is not a default anyone can pick" =
      !renders {
        nixidy.target.repository = "https://example.com/x.git";
        nixidy.target.branch = "main";
        nixcloud.applications.x = { app = "rclone"; namespace = "example-x"; };
      };

    "a workload with no namespace is refused, because this repository has no honest default" =
      !renders {
        nixidy.target.repository = "https://example.com/x.git";
        nixidy.target.branch = "main";
        nixcloud.applications.x = { app = "rclone"; version = "0.0.0"; };
      };

    # ── The guards, each with its message asserted ────────────────────────────────────────────
    "backing a directory the application does not write is refused" =
      failsWith "must back every directory it writes"
        (with' { nixcloud.applications.example-transfers.state.nope.hostPath = "/example/nope"; });

    "leaving a directory it DOES write unbacked is refused" =
      failsWith "must back every directory it writes"
        (with' { nixcloud.applications.example-documents.state = lib.mkForce { }; });

    "a hostPathType beside a claim is refused -- it describes a backing the volume does not have" =
      failsWith "sets `hostPathType` on state that is not backed by a node path"
        (with' { nixcloud.applications.example-files.state.data.hostPathType = "DirectoryOrCreate"; });

    "a directory backed by both a claim and a node path is refused" =
      failsWith "EITHER an existing claim OR a node path"
        (with' { nixcloud.applications.example-transfers.state.cfg.claim = "example-claim"; });

    "an application not told where its database is, is refused rather than left to fail at boot" =
      failsWith "must be told where to find its `database`"
        (filesEnvWithout [ "POSTGRES_HOST" ]);

    "an application not told the name it is reached at is refused, because it refuses everybody" =
      failsWith "must be told the name it is reached at"
        (filesEnvWithout [ "NEXTCLOUD_TRUSTED_DOMAINS" ]);

    "a companion that runs its own image and was given none is refused" =
      failsWith "and no reference was given"
        (with' { nixcloud.applications.example-files.companionImages = lib.mkForce { }; });

    "naming an image for a companion that shares the application's is refused" =
      failsWith "which is not a container of"
        (with' { nixcloud.applications.example-files.companionImages.realtime = "registry.example.com/nope:0.0.0"; });

    "two workloads anchoring one namespace is refused" =
      failsWith "Exactly one workload may create a namespace"
        (with' { nixcloud.applications.example-files.createNamespace = true; });

    "a namespace nobody anchors is refused, because nothing then owns it" =
      failsWith "anchored by none of them"
        (with' { nixcloud.applications.example-transfers.createNamespace = false; });

    "two workloads on one slot is refused" =
      failsWith "is claimed by 2 applications"
        (with' { nixcloud.applications.example-files.slot = 2; });

    # ── The warnings that are not refusals ────────────────────────────────────────────────────
    # Both are real mistakes and neither is an eval error: which front a cluster runs, and how much
    # a cold start is worth to it, are its own business, and a repository that refused either would
    # be legislating routing and economics it cannot see.
    "scale-to-zero with no wake front warns rather than refuses" =
      warnsWith "nothing brings it back"
        (with' { nixcloud.applications.example-transfers.wake = lib.mkForce null; });

    "sleeping an application the catalogue calls unsafe to sleep warns rather than refuses" =
      warnsWith "does not idle safely"
        (with' {
          nixcloud.applications.example-documents.scaling = "scale-to-zero";
          nixcloud.applications.example-documents.wake = "keda";
        });

    "and the application the catalogue DOES call safe to sleep draws no such warning" =
      !(warnsWith "does not idle safely" base);
  };

  failed = lib.filter (n: !results.${n}) (lib.attrNames results);
in
pkgs.runCommand "nixcloud-cluster-eval" { } (
  if failed == [ ]
  then ''
    echo "nixcloud: all ${toString (lib.length (lib.attrNames results))} cluster-eval properties hold"
    touch $out
  ''
  else ''
    echo "nixcloud cluster-eval FAILED (${toString (lib.length failed)}/${toString (lib.length (lib.attrNames results))}):" >&2
    ${lib.concatMapStringsSep "\n" (n: ''echo "  - ${n}" >&2'') failed}
    exit 1
  ''
)
