#
# nixcloud's cluster surface: declare which document clouds run in the cluster, and render them.
#
# ── THIS MODULE DOES NOT IMPLEMENT KUBERNETES, AND THAT IS THE DESIGN ──────────────────────────
#
# A sibling repository's whole subject is the app grammar: a workload declares WHAT IT NEEDS -- an
# image, ports, an exposure class, whether it may sleep, which directories it writes and what backs
# them, which containers stand beside it -- and that grammar renders the Argo CD Application, the
# Namespace, the Deployment and the Service. Everything expressible in those terms is expressed in
# them: this module DEFINES INTO `nixk3s.apps` and renders no Kubernetes object of its own.
#
# So it is a translator. What it adds is the one thing the grammar cannot know: what these
# particular applications ARE. Which of them speaks FastCGI and therefore needs a web front in its
# pod; which one's user files are plain readable documents and only while a particular storage
# driver is running; how long a twenty-service single binary is allowed to take before a probe is
# entitled to call it dead.
#
# IMPORT THE GRAMMAR ALONGSIDE IT. `nixk3s.apps` is declared there, not here, and a render that
# composes this module without it fails with "the option `nixk3s.apps' does not exist".
#
# ── THE KNOWLEDGE/VALUE SPLIT, ENFORCED RATHER THAN TRUSTED ────────────────────────────────────
#
# `lib/applications.nix` holds what is true of the software anywhere. A declaration holds what is
# true of one cluster. Neither can supply the other's half, and the assertions below are what makes
# that a rule rather than a habit:
#
#   - the catalogue says WHERE inside the container a directory lives; only a declaration can say
#     WHAT BACKS IT, and an unbacked directory is refused rather than quietly rendered onto a pod's
#     own filesystem, which for a document cloud means somebody's files going into a tmpfs;
#   - the catalogue says WHICH VARIABLES carry the address of a service the app cannot run itself,
#     and which carry the name it is reached at; only a declaration holds those values, and leaving
#     one out is refused rather than deferred to a startup failure nothing in the tree points at;
#   - the catalogue says a companion runs an image of its OWN; only a declaration can say which
#     build of it, because a second image has its own version and its own pin;
#   - the catalogue says WHICH VARIABLES a credential arrives in; only a declaration can say which
#     Secret holds it, and neither side can say what it IS -- there is no option anywhere in this
#     repository that carries a secret's contents.
#
# ── WHAT A DECLARATION OWNS THAT THE CATALOGUE COULD ONLY HAVE GUESSED ─────────────────────────
#
# `resources` and `companionResources` are the clearest case in the whole surface. A CPU share and
# a memory ceiling are a MEASUREMENT -- of one workload's load, on one cluster's hardware, at one
# point in its life -- and there is no reading of "true of the software wherever anyone runs it"
# under which somebody else's numbers qualify. They are per CONTAINER rather than per pod because
# that is how the scheduler sums them, which is also why a companion gets its own: a web front
# that requests nothing is placed as though it were free, and a pod is oversubscribed by the
# container nobody sized.
#
# ── ONE DIFFERENCE FROM THE SIBLING REPOSITORIES WORTH STATING ─────────────────────────────────
#
# THERE IS NO DEFAULT NAMESPACE HERE, and that is not an omission. In a repository whose apps are
# variations on one thing, one shared namespace with a default is right. These are not: two
# collaboration platforms that people keep open all day genuinely share a boundary, and a transfer
# daemon that is restarted, reconfigured and idled without anyone noticing genuinely does not
# belong inside it. A namespace is a blast-radius boundary; a default would be this repository
# guessing which of its applications fail together, which is exactly the thing it does not know.
{ config, lib, ... }:

let
  cfg = config.nixcloud;
  platform = cfg.clusterPlatform;
  catalogue = (import ../lib/applications.nix { }).applications;

  declared = lib.filterAttrs (_: w: w.enable) cfg.applications;
  workloads = lib.mapAttrsToList (name: w: { inherit name w; entry = catalogue.${w.app}; }) declared;

  # ── Catalogue readers ─────────────────────────────────────────────────────────────────────────
  #
  # TOTAL BY CONSTRUCTION, all of them. A declaration that names something the catalogue does not
  # hold is refused by an assertion below, and an assertion can only refuse what evaluates: a
  # lookup that throws instead takes the whole assertion list down with it, and what a person then
  # reads is "attribute missing" rather than the sentence explaining what they got wrong.

  mountOf = m: {
    inherit (m) mountPath;
    subPath = m.subPath or null;
    readOnly = m.readOnly or false;
  };

  portOf = p: {
    inherit (p) number;
    publish = p.publish or true;
    servicePort = p.servicePort or null;
  };

  mountsOf = ms: lib.mapAttrs (_: l: map mountOf l) ms;

  # A whole reference wins over a repository plus a tag, which is what pinning by digest looks
  # like. The catalogue never carries either: a version is a deployment's choice and a digest is
  # one deployment's proof of what it actually pulled.
  imageOf = entry: w: if w.image != null then w.image else "${entry.image}:${w.version}";

  # A companion either runs the app's own image -- which is a real and common case, since a
  # process that ships inside the application's own installation has no image of its own -- or it
  # runs a second image with a second version and a second pin, which only a declaration holds.
  # The fallback is the bare repository ON PURPOSE: it is a total value so the assertion below can
  # speak, and it is also unusable enough that nothing quietly runs on it.
  companionImageOf = entry: w: cname: c:
    if c.image == null then imageOf entry w
    else w.companionImages.${cname} or c.image;

  # The catalogue's probe budgets, with the port filled in from whichever container is being
  # described. A probe reads a socket through its OWN container's port table, so the app's probe
  # takes the app's primary port and a companion's takes the companion's -- which is the whole
  # reason a probe is not a property of the app.
  probesOf = c:
    lib.optionalAttrs (c.readiness != null)
      {
        readiness = { port = c.primaryPort; } // c.readiness;
      }
    // lib.optionalAttrs (c.liveness != null) {
      liveness = { port = c.primaryPort; } // c.liveness;
    };

  # "This process needs no privilege and no capability" is a fact about the software, so it lives
  # in the catalogue; what it renders is only ever a restriction, which is all this half of the
  # grammar's `security` can express. Stated per container, because a hardened application beside
  # an unhardened sidecar in the same pod is an unhardened pod.
  securityOf = unprivileged:
    lib.optionalAttrs unprivileged {
      allowPrivilegeEscalation = false;
      capabilitiesDrop = [ "ALL" ];
    };

  # The split in one function: WHERE inside the container comes from the catalogue, WHAT BACKS IT
  # comes from the declaration, and neither side can supply the other's half.
  #
  # EVERY FIELD IS PASSED THROUGH, including the ones that only make sense on one kind of backing.
  # `hostPathType` describes a directory on the NODE, so beside a claim it is a fact about a
  # backing the volume does not have -- and the grammar refuses exactly that, which is the layer
  # that owns the term doing the refusing. Dropping it here instead would be this module deciding,
  # silently, that a field somebody typed did not matter.
  stateOf = entry: w:
    lib.mapAttrs
      (key: backing: {
        mounts = map mountOf (entry.state.${key}.mounts or [ ]);
        inherit (backing) claim hostPath hostPathType readOnly;
      })
      w.state;

  # TWO WAYS TO NAME A SECRET, AND THEY ARE NOT THE SAME CLAIM.
  #
  #   envFromSecrets -- a whole Secret, loaded wholesale. The app gets whatever it happens to
  #                     contain, which is convenient and blunt: a key added later lands in the
  #                     process environment unannounced and nothing knew to expect it.
  #   credentialSecrets -- the catalogue named a VARIABLE, and this says which Secret's key holds
  #                     it. That renders a `secretKeyRef`, so the variable the application actually
  #                     reads is written down and checkable, and the value still never exists here.
  #
  # Merged by SECRET NAME, because both forms may legitimately name one Secret: a bag of
  # environment plus one key the catalogue happens to know about is one object in the cluster, and
  # emitting it twice would be two entries fighting over one attribute.
  #
  # Nothing on either path can carry a secret's CONTENT, which is what makes a declaration written
  # against this module safe to publish.
  secretsOf = w:
    let
      wholesale = lib.listToAttrs
        (map (s: lib.nameValuePair s { secret = s; envFrom = true; }) w.envFromSecrets);

      keyedFor = secret:
        lib.concatMapAttrs
          (group: c:
            lib.optionalAttrs (c.secret == secret)
              (lib.listToAttrs (map
                (v: lib.nameValuePair v (c.keys.${v} or v))
                (catalogue.${w.app}.credentials.${group} or [ ]))))
          w.credentialSecrets;

      named = lib.listToAttrs (map
        (c: lib.nameValuePair c.secret {
          secret = c.secret;
          env = keyedFor c.secret;
        })
        (lib.attrValues w.credentialSecrets));
    in
    lib.zipAttrsWith (_: lib.foldl' lib.recursiveUpdate { }) [ wholesale named ];

  companionsOf = entry: w:
    lib.mapAttrs
      (cname: c: {
        image = companionImageOf entry w cname c;
        inherit (c) command args env;
        ports = lib.mapAttrs (_: portOf) c.ports;
        mounts = mountsOf c.mounts;
        security = securityOf c.unprivileged;
        probes = probesOf c;
        # A companion the declaration never sized asks for nothing, which is the grammar's own
        # default and renders no `resources` block at all -- rather than a zero, which is a
        # different and much worse claim.
        resources = w.companionResources.${cname} or { requests = { }; limits = { }; };
      })
      entry.companions;

  # A LIST, because the kubelet runs them in sequence and that order is the semantics. An init
  # container here is always one that touches the app's own volumes or runs the app's own image;
  # anything else is a wait loop, which is nothing this repository knows about.
  initOf = entry: w:
    map
      (c: {
        inherit (c) name command args env;
        image = if c.image == null then imageOf entry w else c.image;
        mounts = mountsOf c.mounts;
        security = securityOf c.unprivileged;
      })
      entry.init;

  # Handed to the band model only when the consumer says it is part of the render: `origin` and
  # `slot` are ITS terms, and defining them into a render that does not declare them is an eval
  # error rather than a graceful no-op.
  addressingOf = w:
    lib.optionalAttrs (platform.origin != null) {
      origin = platform.origin;
      inherit (w) slot;
    };

  mkApp = x:
    let inherit (x) entry w; in
    {
      inherit (w) namespace createNamespace project exposure scaling resources adopt;
      image = imageOf entry w;
      inherit (entry) command;
      args = entry.args ++ w.args;
      env = entry.env // w.env;
      ports = lib.mapAttrs (_: portOf) entry.ports;
      state = stateOf entry w;
      secrets = secretsOf w;
      security = securityOf entry.unprivileged;
      probes = probesOf entry;
      companions = companionsOf entry w;
      init = initOf entry w;
    }
    // lib.optionalAttrs (w.wake != null) { inherit (w) wake; }
    // addressingOf w;

  # ── Assertions ────────────────────────────────────────────────────────────────────────────────

  stateAssertions = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          assertion = lib.attrNames w.state == lib.attrNames entry.state;
          message =
            "nixcloud: application `${name}` must back every directory it writes, and backs "
            + (if w.state == { } then "none" else lib.concatMapStringsSep ", " (k: "`${k}`") (lib.attrNames w.state))
            + ". It writes: "
            + (if entry.state == { } then "nothing"
            else
              lib.concatStringsSep ", " (lib.mapAttrsToList
                (k: st: "`${k}` at " + lib.concatMapStringsSep " and " (m: m.mountPath) st.mounts)
                entry.state))
            + ".";
        }
        {
          assertion = lib.all
            (backing: (backing.claim == null) != (backing.hostPath == null))
            (lib.attrValues w.state);
          message =
            "nixcloud: application `${name}` must back each directory with EITHER an existing claim OR a "
            + "node path, never both and never neither. A directory with no backing is a pod's own "
            + "filesystem, discarded on the next restart -- and for these applications the thing being "
            + "discarded is somebody's documents.";
        }
      ])
    workloads;

  # THE OTHER HALF OF THE SAME SPLIT. The catalogue knows which variables an application must be
  # handed before it can start; only a declaration holds the values, and an application started
  # without them does not fail loudly -- it comes up and refuses everybody, which is the failure
  # this guard exists to move from runtime to eval.
  requirementAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        missing = vars: lib.filter (v: !(w.env ? ${v})) vars;
      in
      lib.mapAttrsToList
        (service: vars: {
          assertion = missing vars == [ ];
          message =
            "nixcloud: application `${name}` must be told where to find its `${service}`, and "
            + lib.concatMapStringsSep ", " (v: "`${v}`") (missing vars)
            + " ${if lib.length (missing vars) == 1 then "is" else "are"} unset. `${w.app}` does not run "
            + "that service itself and will not invent an address for it; supply the values in `env`.";
        })
        entry.requires
      ++ [
        {
          assertion = lib.all (v: w.env ? ${v}) entry.publicIdentity;
          message =
            "nixcloud: application `${name}` must be told the name it is reached at, and "
            + lib.concatMapStringsSep ", " (v: "`${v}`")
              (lib.filter (v: !(w.env ? ${v})) entry.publicIdentity)
            + " ${if lib.length (lib.filter (v: !(w.env ? ${v})) entry.publicIdentity) == 1 then "is" else "are"} "
            + "unset. Everything `${w.app}` sees is a proxied request, so it cannot derive its own "
            + "address -- and told nothing it does not guess, it refuses every caller.";
        }
      ])
    workloads;

  # THE THIRD HALF OF THE SAME SPLIT, and the one that decides whether a published declaration is
  # safe. The catalogue names the VARIABLES a credential arrives in; a declaration names the Secret
  # whose keys hold them, and never the values. Every direction of getting that wrong is refused
  # here rather than at startup, where an application without its password does not stop -- it
  # comes up and fails the first request that needs the thing behind it.
  credentialAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        groups = lib.attrNames entry.credentials;
        given = lib.attrNames w.credentialSecrets;
      in
      [
        {
          assertion = lib.all (g: w.credentialSecrets ? ${g}) groups;
          message =
            "nixcloud: application `${name}` reads a credential from "
            + lib.concatMapStringsSep ", "
              (g: "`${g}` (" + lib.concatMapStringsSep ", " (v: "`${v}`") entry.credentials.${g} + ")")
              (lib.filter (g: !(w.credentialSecrets ? ${g})) groups)
            + " and no Secret was named for it. Name one in `credentialSecrets`; the VALUE cannot "
            + "arrive here and nothing in this repository may hold it. `envFromSecrets` does not "
            + "answer this: a wholesale Secret might contain the key or might not, and neither this "
            + "module nor the cluster can tell which until the application fails.";
        }
        {
          assertion = lib.all (g: lib.elem g groups) given;
          message =
            "nixcloud: application `${name}` names a Secret for "
            + lib.concatMapStringsSep ", " (g: "`${g}`") (lib.filter (g: !(lib.elem g groups)) given)
            + ", which is not a credential `${w.app}` reads. A name that is neither a typo nor a "
            + "credential is a Secret mounted into a process that never looks at it.";
        }
      ]
      ++ lib.mapAttrsToList
        (group: c:
          let
            vars = entry.credentials.${group} or [ ];
            stray = lib.filter (v: !(lib.elem v vars)) (lib.attrNames c.keys);
          in
          {
            assertion = stray == [ ];
            message =
              "nixcloud: application `${name}` maps a key of Secret `${c.secret}` onto "
              + lib.concatMapStringsSep ", " (v: "`${v}`") stray
              + ", which `${w.app}` does not read as part of `${group}`. `keys` renames the key "
              + "INSIDE a Secret for a variable the catalogue already named; it does not invent "
              + "variables, because a variable nothing reads is a credential handed out for free.";
          })
        w.credentialSecrets
      ++ [
        {
          assertion = lib.all (v: !(w.env ? ${v})) (lib.concatLists (lib.attrValues entry.credentials));
          message =
            "nixcloud: application `${name}` sets "
            + lib.concatMapStringsSep ", " (v: "`${v}`")
              (lib.filter (v: w.env ? ${v}) (lib.concatLists (lib.attrValues entry.credentials)))
            + " in `env`, and the catalogue records "
            + "${if lib.length (lib.filter (v: w.env ? ${v}) (lib.concatLists (lib.attrValues entry.credentials))) == 1 then "that variable as a credential" else "those variables as credentials"}"
            + ". `env` is plain text in a file written to be published; a credential belongs in a "
            + "Secret this declaration NAMES, through `credentialSecrets`.";
        }
      ])
    workloads;

  # Sizing a container the pod does not have is not a preference either: it is a number nobody
  # applies, sitting in a declaration that reads as though somebody had thought about the load.
  companionResourceAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        stray = lib.filter (c: !(entry.companions ? ${c})) (lib.attrNames w.companionResources);
      in
      [
        {
          assertion = stray == [ ];
          message =
            "nixcloud: application `${name}` sizes "
            + lib.concatMapStringsSep ", " (c: "`${c}`") stray
            + ", which is not a container of `${w.app}`. A request against a container that does "
            + "not exist is a number the scheduler never sees.";
        }
      ])
    workloads;

  # A companion that runs its own image needs its own version and its own pin, which is a
  # deployment's to hold. A companion that runs the APP'S image must not be given one: two answers
  # to which code a container runs is not a preference, it is a pod where one container silently
  # ran something else.
  companionImageAssertions = lib.concatMap
    (x:
      let
        inherit (x) name w entry;
        ownImage = lib.attrNames (lib.filterAttrs (_: c: c.image != null) entry.companions);
        given = lib.attrNames w.companionImages;
      in
      [
        {
          assertion = lib.all (c: w.companionImages ? ${c}) ownImage;
          message =
            "nixcloud: application `${name}` has companions that run an image of their own ("
            + lib.concatMapStringsSep ", " (c: "`${c}`") (lib.filter (c: !(w.companionImages ? ${c})) ownImage)
            + ") and no reference was given. The catalogue holds the repository; which BUILD of it runs "
            + "is a deployment's, exactly as it is for the application's own image.";
        }
        {
          assertion = lib.all (c: lib.elem c ownImage) given;
          message =
            "nixcloud: application `${name}` gives an image for "
            + lib.concatMapStringsSep ", " (c: "`${c}`") (lib.filter (c: !(lib.elem c ownImage)) given)
            + ", which is not a container of `${w.app}` that runs an image of its own. A companion that "
            + "shares the application's installation shares its image; a name that is neither is a typo, "
            + "and a typo here renders a container nobody declared.";
        }
      ])
    workloads;

  # A namespace outlives every workload in it, so exactly one thing may own it. Two anchors is not a
  # merge, it is two Namespace objects Argo will fight over.
  anchorAssertions =
    let
      anchors = lib.filter (x: x.w.createNamespace) workloads;
      byNs = lib.groupBy (x: x.w.namespace) anchors;
      namespaces = lib.unique (map (x: x.w.namespace) workloads);
    in
    lib.mapAttrsToList
      (ns: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixcloud: namespace `${ns}` is anchored by ${toString (lib.length xs)} applications ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). Exactly one workload may create a namespace.";
      })
      byNs
    ++ map
      (ns: {
        assertion = byNs ? ${ns};
        message =
          "nixcloud: namespace `${ns}` is used by "
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") (lib.filter (x: x.w.namespace == ns) workloads)
          + " and anchored by none of them. Something must own it: set `createNamespace` on exactly one "
          + "of them, or anchor it outside this repository and say so by leaving it false everywhere -- "
          + "which is a deliberate statement, not the default it currently looks like.";
      })
      (lib.filter (ns: !(byNs ? ${ns})) namespaces);

  slotAssertions =
    let
      claimed = lib.filter (x: x.w.slot != null) workloads;
      bySlot = lib.groupBy (x: toString x.w.slot) claimed;
    in
    lib.mapAttrsToList
      (slot: xs: {
        assertion = lib.length xs == 1;
        message =
          "nixcloud: slot ${slot} is claimed by ${toString (lib.length xs)} applications ("
          + lib.concatMapStringsSep ", " (x: "`${x.name}`") xs
          + "). A slot is one identity in several address spaces at once; two workloads on one number "
          + "is two workloads on one address.";
      })
      bySlot;

  # A warning is `{ when; message; }` -- the renderer decides whether to print it, so the condition
  # travels with the text rather than being applied here.
  warnings = lib.concatMap
    (x:
      let inherit (x) name w entry; in
      [
        {
          when = w.scaling == "scale-to-zero" && w.wake == null;
          message =
            "nixcloud: application `${name}` is declared scale-to-zero with no wake front, so nothing "
            + "brings it back. At zero replicas that is not an idle workload, it is an unreachable one.";
        }
        {
          when = w.scaling == "scale-to-zero" && !entry.sleepSafe;
          message =
            "nixcloud: application `${name}` is declared scale-to-zero, and the catalogue records that "
            + "`${w.app}` does not idle safely -- it has work that happens while nobody is looking, or "
            + "clients that hold a connection open expecting it to be there. Sleeping it is not free the "
            + "way it is for a workload that only ever answers requests.";
        }
        {
          when = w.slot != null && platform.origin == null;
          message =
            "nixcloud: application `${name}` claims slot ${toString w.slot}, and "
            + "`nixcloud.clusterPlatform.origin` is unset -- so the number is checked for collisions "
            + "inside this repository and by nothing for which RANGE it may come from.";
        }
      ])
    workloads;

  commonOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to render this workload. Declaring the attribute is declaring the workload, so this
        defaults to true; set false to park a declaration without rendering it.
      '';
    };

    namespace = lib.mkOption {
      type = lib.types.str;
      description = ''
        Namespace this workload lands in. REQUIRED, and defaulted nowhere -- see the header: this
        repository's applications do not agree on one boundary, so a default here would be a guess
        about which of them fail together.
      '';
    };

    createNamespace = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload anchors its namespace. Defaults to false, because a namespace outlives
        every workload in it and exactly one thing may own it. Every namespace these workloads use
        must be anchored by one of them or deliberately by something outside this repository.
      '';
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = platform.project;
      defaultText = lib.literalExpression "config.nixcloud.clusterPlatform.project";
      description = ''
        Delivery project this workload's Application belongs to. Unlike the namespace this DOES take
        a shared default: a project may span namespaces, so one repository's applications belonging
        to one delivery project says nothing about their blast radius.
      '';
    };

    slot = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      description = ''
        THE POSITION this workload holds in the fleet's ordered identity space. Not an address --
        the layers underneath map it into however many address spaces the fleet keeps, which is
        why nothing here moves one. The VALUE is a fleet fact and belongs to the consumer.
      '';
    };

    exposure = lib.mkOption {
      type = lib.types.enum [ "internal" "nb" "public" ];
      default = "internal";
      description = ''
        Who can reach it, as a CLASS rather than an address. Defaults to the closed answer, and for
        this catalogue that default earns its keep: every application here is a door to somebody's
        documents, and one of them authenticates with a single username and password pair.
      '';
    };

    scaling = lib.mkOption {
      type = lib.types.enum [ "always" "scale-to-zero" ];
      default = "always";
      description = ''
        Whether the workload may idle to zero replicas.

        The catalogue records whether sleeping is SAFE for a given application -- whether anything
        happens on a timer, whether clients hold connections open, whether it watches a directory
        for writes that did not come through it. Whether it is WANTED is a deployment's call,
        because the wake path is one cluster's routing and this repository cannot see whether that
        path is healthy. Declaring it against the catalogue's answer warns rather than refuses.
      '';
    };

    wake = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "keda" "sablier" ]);
      default = null;
      description = ''
        Which front wakes it from zero. Meaningless unless `scaling = "scale-to-zero"`, and its
        absence there is warned about: nothing brings the workload back.
      '';
    };

    adopt = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this workload is TAKING OVER objects that already exist in the cluster -- applied
        by hand, by an addon, or by the manifests this declaration replaces. It renders the
        Application with server-side apply and server-side diff, so the delivery controller
        compares against what the API server actually holds rather than against a client-side
        reconstruction of it.

        IT IS A DECLARATION'S TERM AND NOT THE CATALOGUE'S, deliberately, and the reason is the
        same one that splits this repository in half: whether an object is already in a cluster is
        THAT CLUSTER'S HISTORY, not a fact about the software. The same application adopted on one
        cluster and created fresh on another differs here and nowhere else, so the catalogue can
        have no opinion to hold.

        AND IT EARNS ITS KEEP FOR EXACTLY THIS CATALOGUE. A rendered spec is never byte-identical
        to the YAML it replaces -- labels differ, fields this grammar sets appear, fields it does
        not set disappear -- and the controller acts on that difference. Every application here
        keeps somebody's documents on a single-writer volume, so its Deployment rolls by
        `Recreate`: the old pod stops before the new one starts, and the difference is downtime
        rather than a rollout nobody notices. Adopting shrinks the diff to what genuinely changed,
        which is what makes taking over a live installation possible at all. It does not make it
        zero. Render it, diff it against what is running, and decide knowingly.
      '';
    };

    state = lib.mkOption {
      default = { };
      description = ''
        What backs each directory the catalogue says this application writes, keyed by the SAME
        names. Backing a directory it does not write, or leaving one it does write unbacked, is an
        eval error rather than a surprise at runtime.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          claim = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "An existing PersistentVolumeClaim, by name. Nothing here creates one.";
          };
          hostPath = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "A directory on the node. Pins the workload to whichever node holds it.";
          };
          hostPathType = lib.mkOption {
            type = lib.types.str;
            default = "Directory";
            description = ''
              The hostPath type, when a node path is what backs it. `Directory` -- refuse to start
              when the path is missing -- is the default HERE even though the looser
              `DirectoryOrCreate` is the more common one elsewhere, and the reason is the subject:
              an application that comes up on an empty directory it created itself does not report
              an error, it reports an empty cloud, and then starts writing a second parallel reality
              beside the documents nobody can find.
            '';
          };
          readOnly = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the mount is read-only. ORed with each mount's own.";
          };
        };
      });
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Environment this deployment adds, merged over whatever the catalogue sets. This is where the
        values behind the catalogue's `requires` and `publicIdentity` arrive: the address of a
        database this application does not run, the issuer of an identity provider it does not
        implement, the name a browser reaches it at. Values only -- anything secret belongs in a
        Secret and arrives through `envFromSecrets`.
      '';
    };

    envFromSecrets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Secrets loaded wholesale, by name. Named rather than carried: nothing in this repository
        can hold a secret's contents, which is what makes a declaration written here publishable.

        BLUNT ON PURPOSE, and not a substitute for `credentialSecrets`: the application gets
        whatever the Secret happens to contain, so a key added to it later arrives in the process
        environment unannounced and nothing was expecting it. Where the catalogue knows the
        variable, name it.
      '';
    };

    credentialSecrets = lib.mkOption {
      default = { };
      example = lib.literalExpression ''{ database.secret = "example-files-database"; }'';
      description = ''
        WHICH SECRET holds each credential the catalogue says this application reads, keyed by the
        SAME group names. The catalogue names the VARIABLE -- which is written in the software's
        own documentation and true of every installation of it -- and this names the object in the
        cluster whose key carries the value. Neither side holds the value, and there is no option
        anywhere in this repository that could.

        Renders a `secretKeyRef` per variable, so the value never passes through Nix or the
        rendered tree, and the variable the application actually reads is written down somewhere a
        person can check it against the Secret.

        Leaving a group out is refused rather than deferred to runtime: an application started
        without its password does not fail at startup, it comes up and then fails the first request
        that needs whatever the password was protecting.
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          secret = lib.mkOption {
            type = lib.types.str;
            description = ''
              NAME of an existing Secret. Required and defaulted nowhere: the attribute key is the
              catalogue's name for the credential, not a name any cluster gave an object, and
              guessing that the two agree is how a declaration silently references a Secret that
              was never created.
            '';
          };
          keys = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            example = lib.literalExpression ''{ POSTGRES_PASSWORD = "password"; }'';
            description = ''
              Which KEY inside that Secret holds each variable, as
              `<VARIABLE> = "<key>"`. Defaults to the variable's own name, which is what a Secret
              minted for this application looks like; state it only for a Secret whose keys were
              named by something else and which this deployment does not get to rename.

              Naming a variable the catalogue does not list for this group is refused -- this
              renames a key, it does not invent a variable.
            '';
          };
        };
      });
    };

    resources = lib.mkOption {
      default = { requests = { }; limits = { }; };
      example = lib.literalExpression ''{ requests = { cpu = "200m"; memory = "512Mi"; }; limits.memory = "2Gi"; }'';
      description = ''
        Compute for THIS DEPLOYMENT's copy of the application's own container. A measurement of one
        workload's load on one cluster's hardware, which is why the catalogue does not hold it and
        why nothing here defaults it to a guess: a container that asks for nothing is scheduled as
        though it were free, and that is an honest statement of "nobody has measured this yet"
        rather than a number somebody copied.

        A memory limit is a kill threshold, which is usually what a leaky application wants; a CPU
        limit is a throttle, which is usually not.
      '';
      type = lib.types.submodule {
        options = {
          requests = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "What the scheduler must find for this container.";
          };
          limits = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Ceilings for this container.";
          };
        };
      };
    };

    companionResources = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          requests = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "What the scheduler must find for this companion.";
          };
          limits = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
            description = "Ceilings for this companion.";
          };
        };
      });
      default = { };
      example = lib.literalExpression ''{ web = { requests = { cpu = "10m"; memory = "32Mi"; }; limits.memory = "128Mi"; }; }'';
      description = ''
        The same measurement for the containers that stand BESIDE the application, keyed by the
        name the catalogue gives them. Separate from `resources` for the reason the scheduler
        cares about: it sums a pod's containers, so the web front nobody sized is exactly how a
        node ends up oversubscribed by a process everyone thought of as small.

        Sizing a container this application does not have is refused. Init containers take no entry
        here -- they run once and exit, and the one this repository catalogues runs the
        application's own image against the application's own volume, so what it costs is what the
        application already costs.
      '';
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments appended to whatever the catalogue sets.";
    };

    image = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        A whole image reference, overriding the catalogue's repository and this workload's version.
        This is where a digest pin goes, and pinning by digest is what makes two syncs of an
        identical rendered tree run identical code.
      '';
    };

    companionImages = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''{ web = "registry.example.com/example/web:1.2.3@sha256:..."; }'';
      description = ''
        Whole image references for the containers that stand beside this application and run an
        image of their OWN, keyed by the name the catalogue gives them. A companion that runs the
        application's own image -- because the process it runs ships inside the application's
        installation rather than in any image -- takes no entry here, and giving it one is refused.
      '';
    };
  };
in
{
  options.nixcloud.clusterPlatform = {
    project = lib.mkOption {
      type = lib.types.str;
      default = "cloud";
      description = ''
        Delivery project these applications' Argo CD Applications belong to unless a declaration
        says otherwise. A project may span namespaces, which is why this one has a default and the
        namespace deliberately does not.
      '';
    };

    origin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        THE IDENTITY THIS REPOSITORY'S APPS ARE ADDRESSED UNDER, when the render composes the band
        model. A repository naming itself is not a fleet fact; which band that name binds is, and it
        lives in whatever repository owns the fleet. Left null, slots are still checked for
        collisions here and by nothing for range.
      '';
    };
  };

  options.nixcloud.applications = lib.mkOption {
    default = { };
    description = ''
      The document clouds that run in the cluster, keyed by a name of your choosing.

      THE ENUM IS THE HOUSE RULE. It is built from `lib/applications.nix`, so an application this
      repository does not catalogue is not a refused value here -- it is not a value. What belongs
      in that catalogue is documents and the machinery that moves them: an object store, a chat
      archive and a backup tier are all adjacent to the word "cloud" and none of them is this.
    '';
    example = lib.literalExpression ''
      {
        example-documents = {
          app = "opencloud";
          version = "0.0.0";
          namespace = "example-clouds";
          createNamespace = true;
          exposure = "public";
          slot = 2;
          resources.requests = { cpu = "200m"; memory = "512Mi"; };
          resources.limits.memory = "2Gi";
          state.state.hostPath = "/example/state/documents";
          state.userfiles.hostPath = "/example/documents";
          env = {
            OC_URL = "https://cloud.example.com";
            OC_DOMAIN = "cloud.example.com";
            OC_OIDC_ISSUER = "https://id.example.com";
            WEB_OIDC_METADATA_URL = "https://id.example.com/.well-known/openid-configuration";
            WEB_OIDC_CLIENT_ID = "00000000-0000-0000-0000-000000000000";
          };
        };
      }
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
      options = commonOptions // {
        app = lib.mkOption {
          type = lib.types.enum (lib.attrNames catalogue);
          description = "Which application, from the catalogue. Available: ${lib.concatStringsSep ", " (lib.attrNames catalogue)}.";
        };

        version = lib.mkOption {
          type = lib.types.str;
          description = "Which version this workload runs, used as the image tag. Required, and defaulted nowhere.";
        };
      };
    }));
  };

  # ── Computed, read-only ───────────────────────────────────────────────────────────────────────
  options.nixcloud.clusterSlots = lib.mkOption {
    type = lib.types.attrsOf lib.types.ints.unsigned;
    readOnly = true;
    default = lib.listToAttrs
      (map (x: lib.nameValuePair x.name x.w.slot) (lib.filter (x: x.w.slot != null) workloads));
    defaultText = lib.literalExpression "every declared workload that claims a slot";
    description = ''
      workload -> the position it claims. Nothing is rendered from it here: what an address looks
      like is the private layer's business, and this is what that layer reads to build one.
    '';
  };

  config = {
    nixk3s.apps = lib.listToAttrs (map (x: lib.nameValuePair x.name (mkApp x)) workloads);
    nixidy.assertions =
      stateAssertions
      ++ requirementAssertions
      ++ credentialAssertions
      ++ companionResourceAssertions
      ++ companionImageAssertions
      ++ anchorAssertions
      ++ slotAssertions;
    nixidy.warnings = warnings;
  };
}
