# Reads the tier's promises back off the RENDERED BYTES, not off the options that produced them.
#
# The eval check proves the module resolves and refuses. This one proves the manifests that come
# out say what the module claims — which is a different question, and the only one a cluster ever
# sees. An option can be correct and the rendering still wrong.
{ pkgs, lib, nixidy, appsModule, clusterModule, values }:

let
  env = nixidy.lib.mkEnv {
    inherit pkgs;
    modules = [ appsModule clusterModule (import values) ];
  };
in
pkgs.runCommand "nixcloud-cluster-render"
{
  nativeBuildInputs = [ pkgs.yq-go ];
  manifests = env.environmentPackage;
} ''
  set -euo pipefail
  fail=0
  check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "  ok   $1: $3"
    else echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
  }
  y() { yq -r "$1" "$2"; }

  echo "== the environment renders all three workloads and nothing else =="
  rendered=$(ls "$manifests" | sort | tr '\n' ' ' | sed 's/ $//')
  check "rendered apps" "apps example-documents example-files example-transfers" "$rendered"

  docs="$manifests/example-documents"
  files="$manifests/example-files"
  xfer="$manifests/example-transfers"

  echo "== the catalogue's ports reach the containers, and no declaration stated one =="
  check "documents port" "9200" "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $docs/Deployment-example-documents.yaml)"
  check "transfers port" "5572" "$(y '.spec.template.spec.containers[0].ports[0].containerPort' $xfer/Deployment-example-transfers.yaml)"

  echo "== a document cloud is three processes over one installation, not one =="
  check "files containers" "3" "$(y '.spec.template.spec.containers | length' $files/Deployment-example-files.yaml)"
  check "files container names" "example-files realtime web" \
    "$(y '[.spec.template.spec.containers[].name] | sort | join(" ")' $files/Deployment-example-files.yaml)"

  echo "== the application speaks FastCGI, and only the web front is on the Service =="
  check "app's own port" "9000" \
    "$(y '.spec.template.spec.containers[] | select(.name == "example-files") | .ports[0].containerPort' $files/Deployment-example-files.yaml)"
  check "web front port" "8080" \
    "$(y '.spec.template.spec.containers[] | select(.name == "web") | .ports[0].containerPort' $files/Deployment-example-files.yaml)"
  check "Service carries exactly one port" "1" "$(y '.spec.ports | length' $files/Service-example-files.yaml)"
  check "and it is the conventional number, targeting the honest one by name" "80" \
    "$(y '.spec.ports[0].port' $files/Service-example-files.yaml)"
  check "targetPort is the name, never a second copy of the number" "http" \
    "$(y '.spec.ports[0].targetPort' $files/Service-example-files.yaml)"

  echo "== the probe that gates traffic is on the container that answers it =="
  check "web front probes its own path" "/status.php" \
    "$(y '.spec.template.spec.containers[] | select(.name == "web") | .readinessProbe.httpGet.path' $files/Deployment-example-files.yaml)"
  check "the application's own container carries no probe" "null" \
    "$(y '.spec.template.spec.containers[] | select(.name == "example-files") | .readinessProbe' $files/Deployment-example-files.yaml)"
  check "a twenty-service binary is probed on the socket, not a page" "null" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.httpGet' $docs/Deployment-example-documents.yaml)"
  check "and given the budget its cold start needs" "30" \
    "$(y '.spec.template.spec.containers[0].readinessProbe.failureThreshold' $docs/Deployment-example-documents.yaml)"

  echo "== documents are single-writer, so their Deployments may not roll =="
  for f in $docs/Deployment-example-documents.yaml $files/Deployment-example-files.yaml $xfer/Deployment-example-transfers.yaml; do
    check "$(basename $f) strategy" "Recreate" "$(y '.spec.strategy.type' $f)"
  done
  # An absent `replicas` IS one -- Kubernetes' own default. Asserting it is unset is the honest
  # form: the grammar deliberately does not stamp a count on a workload whose wake front owns it.
  check "sleeping workload has no replica count" "null" "$(y '.spec.replicas' $xfer/Deployment-example-transfers.yaml)"

  echo "== one curated directory, mounted where each container needs it =="
  check "state volume lands first" "/var/lib/opencloud" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[0].mountPath' $docs/Deployment-example-documents.yaml)"
  check "and again as a config view carved out of itself" "config" \
    "$(y '.spec.template.spec.containers[0].volumeMounts[] | select(.mountPath == "/etc/opencloud") | .subPath' $docs/Deployment-example-documents.yaml)"
  check "both views are one volume, not two" "1" \
    "$(y '[.spec.template.spec.volumes[] | select(.name == "state")] | length' $docs/Deployment-example-documents.yaml)"
  check "the web front reads the code tree read-only" "true" \
    "$(y '.spec.template.spec.containers[] | select(.name == "web") | .volumeMounts[0].readOnly' $files/Deployment-example-files.yaml)"
  check "the realtime container does not" "null" \
    "$(y '.spec.template.spec.containers[] | select(.name == "realtime") | .volumeMounts[0].readOnly' $files/Deployment-example-files.yaml)"

  echo "== what backs a directory came from the declaration and nowhere else =="
  check "a node path, refusing to start when it is missing" "Directory" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "state") | .hostPath.type' $docs/Deployment-example-documents.yaml)"
  check "and a claim, mounted by name" "example-files-documents" \
    "$(y '.spec.template.spec.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName' $files/Deployment-example-files.yaml)"

  echo "== first boot generates a configuration before the server starts =="
  check "init containers" "1" "$(y '.spec.template.spec.initContainers | length' $docs/Deployment-example-documents.yaml)"
  check "which runs the application's own image" \
    "$(y '.spec.template.spec.containers[0].image' $docs/Deployment-example-documents.yaml)" \
    "$(y '.spec.template.spec.initContainers[0].image' $docs/Deployment-example-documents.yaml)"

  echo "== the image is a tag when a version was given and a whole reference when one was =="
  check "documents image" "opencloudeu/opencloud-rolling:0.0.0" "$(y '.spec.template.spec.containers[0].image' $docs/Deployment-example-documents.yaml)"
  check "files digest-pinned" "true" \
    "$(y '.spec.template.spec.containers[] | select(.name == "example-files") | .image' $files/Deployment-example-files.yaml | grep -q '@sha256:' && echo true || echo false)"
  check "web front digest-pinned too" "true" \
    "$(y '.spec.template.spec.containers[] | select(.name == "web") | .image' $files/Deployment-example-files.yaml | grep -q '@sha256:' && echo true || echo false)"
  check "the realtime container runs the application's own image" \
    "$(y '.spec.template.spec.containers[] | select(.name == "example-files") | .image' $files/Deployment-example-files.yaml)" \
    "$(y '.spec.template.spec.containers[] | select(.name == "realtime") | .image' $files/Deployment-example-files.yaml)"

  echo "== nothing here can carry a credential, only the name of one =="
  check "secret named, never valued" "example-transfers-auth" \
    "$(y '.spec.template.spec.containers[0].envFrom[0].secretRef.name' $xfer/Deployment-example-transfers.yaml)"
  check "and no Secret object is rendered anywhere in the tree" "0" \
    "$(find -L $manifests -name 'Secret-*.yaml' -type f | wc -l)"

  echo "== no address is invented here: every Service is a plain ClusterIP with nothing pinned =="
  for f in $docs/Service-example-documents.yaml $files/Service-example-files.yaml $xfer/Service-example-transfers.yaml; do
    check "$(basename $f) type" "ClusterIP" "$(y '.spec.type' $f)"
    check "$(basename $f) no pinned IP" "null" "$(y '.spec.clusterIP' $f)"
    check "$(basename $f) no nodePort" "null" "$(y '.spec.ports[0].nodePort' $f)"
  done

  # `-L` is load-bearing: the rendered tree is SYMLINKS into the store, so a plain `-type f`
  # matches nothing and returns a confident zero. A count that can only ever be zero is worse than
  # no check, because it passes the moment somebody expects zero.
  echo "== two namespaces, because these applications do not all fail together =="
  check "namespaces rendered" "2" "$(find -L $manifests -name 'Namespace-*.yaml' -type f | wc -l)"
  check "the shared one, anchored once" "example-clouds" "$(y '.metadata.name' $docs/Namespace-example-clouds.yaml)"
  check "the transfer daemon's own" "example-transfers" "$(y '.metadata.name' $xfer/Namespace-example-transfers.yaml)"
  check "and the platform that joins the shared one anchors nothing" "0" \
    "$(find -L $files -name 'Namespace-*.yaml' -type f | wc -l)"

  if [ "$fail" -ne 0 ]; then
    echo "rendered output does not match the tier's promises" >&2
    exit 1
  fi
  echo "nixcloud: the rendered tree matches every promise asserted here"
  touch $out
''
