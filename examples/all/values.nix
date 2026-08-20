# Placeholder values for the cluster module — the file that makes the render check real.
# `nix flake check` renders the whole surface from here, so a module that stops evaluating, or that
# grows a required value nobody supplies, fails in CI rather than in somebody's cluster.
#
# NOTHING HERE IS REAL. Every namespace, path, host, name, number and image is invented for this
# file, and no credential appears in any form — only the NAME of a Secret that would hold one.
#
# The three declarations are chosen to cover the paths that differ in what gets RENDERED rather
# than merely in what evaluates:
#
#   - a single-container platform with two directories and a first-boot init container, anchoring
#     a shared namespace, always on, running a tagged image, and sized;
#   - a three-container platform in that same namespace: one directory on a node and one on a
#     claim, a companion running an image of its own and a companion running the application's,
#     a port that must never reach the Service, a digest pin on both real images, a companion
#     sized separately from the application, and a credential taken out of a differently-spelled
#     key of a Secret of its own;
#   - a single-container daemon in a namespace of its OWN, sleeping behind a wake front, taking
#     its credentials from ONE named Secret both wholesale and by key.
{
  # Required by the nixidy environment itself, not by any module here.
  nixidy.target.repository = "https://example.com/example-org/example-gitops.git";
  nixidy.target.branch = "main";

  nixcloud.clusterPlatform.project = "example-clouds";

  # Two durable directories, both on node paths, and the one that anchors the shared namespace.
  # Everything in `env` here is a value the catalogue deliberately refuses to hold: the name this
  # installation is reached at, and the identity provider it defers sign-in to.
  nixcloud.applications.example-documents = {
    app = "opencloud";
    version = "0.0.0";
    namespace = "example-clouds";
    createNamespace = true;
    exposure = "public";
    slot = 2;

    # A MEASUREMENT, and the only kind of number in this file that came from watching something
    # run. The catalogue holds none of these on purpose: a twenty-service binary's memory ceiling
    # is a fact about one installation's user count, not about the software.
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

  # Joins the namespace above rather than anchoring a second one. Its code tree sits on a node path
  # and its documents on a claim, which is the pair the module's backing guard exists to keep
  # honest — and both real images carry a whole reference, so two syncs of an identical tree run
  # identical code. The realtime companion is given no image on purpose: it runs the application's
  # own, because the binary it starts lives inside the installation rather than in any image.
  nixcloud.applications.example-files = {
    app = "nextcloud";
    version = "0.0.0";
    image = "registry.example.com/example-org/example-files:0.0.0-fpm@sha256:0000000000000000000000000000000000000000000000000000000000000000";
    companionImages.web = "registry.example.com/example-org/example-web:0.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111";
    namespace = "example-clouds";
    exposure = "public";
    slot = 3;
    state.html.hostPath = "/example/state/files";
    state.data.claim = "example-files-documents";
    env = {
      NEXTCLOUD_TRUSTED_DOMAINS = "files.example.com";
      POSTGRES_HOST = "example-database";
      POSTGRES_DB = "example-files";
      POSTGRES_USER = "example-files";
    };

    # The password is the one thing in that list that may not be typed out, so it is not: the
    # catalogue names the VARIABLE, this names the Secret, and `keys` says which key inside it --
    # spelled differently here on purpose, because a Secret minted by something else does not
    # take orders about its own key names.
    credentialSecrets.database = {
      secret = "example-files-database";
      keys.POSTGRES_PASSWORD = "password";
    };
    envFromSecrets = [ "example-files-env" ];

    # The application and its web front are sized apart, which is the whole reason companions get
    # their own term: the scheduler adds them up, so a front that asks for nothing is placed as
    # though it cost nothing.
    resources.requests = { cpu = "500m"; memory = "768Mi"; };
    companionResources.web = {
      requests = { cpu = "10m"; memory = "32Mi"; };
      limits.memory = "128Mi";
    };
  };

  # Its own namespace, which it anchors: a transfer daemon and a collaboration platform do not fail
  # together, and a namespace is the boundary that says so. Sleeps, and names the front that wakes
  # it — without which the module warns that nothing brings it back.
  nixcloud.applications.example-transfers = {
    app = "rclone";
    version = "0.0.0";
    namespace = "example-transfers";
    createNamespace = true;
    exposure = "nb";
    slot = 4;
    scaling = "scale-to-zero";
    wake = "keda";
    state.cfg.hostPath = "/example/state/transfers";

    # ONE Secret, named twice on purpose and for two different claims: the pair the catalogue
    # knows this daemon reads its basic auth from, by key, and whatever else that same object
    # happens to carry, wholesale. They merge into one reference rather than fighting over it.
    credentialSecrets.rc-auth.secret = "example-transfers-auth";
    envFromSecrets = [ "example-transfers-auth" ];

    resources.requests = { cpu = "10m"; memory = "24Mi"; };
    resources.limits.memory = "128Mi";
  };
}
