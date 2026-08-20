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
#     a shared namespace, always on, and running a tagged image;
#   - a three-container platform in that same namespace: one directory on a node and one on a
#     claim, a companion running an image of its own and a companion running the application's,
#     a port that must never reach the Service, and a digest pin on both real images;
#   - a single-container daemon in a namespace of its OWN, sleeping behind a wake front, taking
#     its credentials from a named Secret.
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
    envFromSecrets = [ "example-files-env" ];
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
    envFromSecrets = [ "example-transfers-auth" ];
  };
}
