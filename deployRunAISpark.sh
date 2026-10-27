#!/usr/bin/env bash
# Deploys k3s + GPU Operator + NVIDIA Run:ai (self-hosted control plane and cluster) on a DGX Spark.
#
#   sudo NGC_API_KEY=<key> ./deploy.sh [install]      # first/only node (control plane + GPU worker)
#   sudo ./deploy.sh join <server-ip> <node-token>    # additional Spark nodes
#   sudo ./deploy.sh remove [--yes]                   # tear down everything this script installed
#
# Optional env: RUNAI_DOMAIN, ADMIN_USER, ADMIN_PASSWORD, CLUSTER_NAME, RUNAI_VERSION, K3S_CHANNEL, NODE_IP
set -euo pipefail

K3S_CHANNEL="${K3S_CHANNEL:-v1.34}"
CLUSTER_NAME="${CLUSTER_NAME:-spark}"
RUNAI_VERSION="${RUNAI_VERSION:-}"          # empty = latest chart
# Run:ai requires an email-style user and a password with upper/lower/digit/special (min 8).
ADMIN_USER="${ADMIN_USER:-admin@runai.local}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-Admin123!}"
STATE_DIR=/var/lib/runai-spark
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

detect_ip() {
  ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

preflight() {
  need_root
  [[ -n "${NGC_API_KEY:-}" ]] || die "NGC_API_KEY is required (NGC key entitled to Run:ai)."
  command -v nvidia-smi >/dev/null || die "NVIDIA driver not found (nvidia-smi)."
  command -v curl >/dev/null || die "curl required."
  command -v python3 >/dev/null || die "python3 required."
  command -v openssl >/dev/null || die "openssl required."
  NODE_IP="${NODE_IP:-$(detect_ip)}"
  [[ -n "$NODE_IP" ]] || die "Could not detect node IP; set NODE_IP."
  # Domain must resolve from clients AND from pods; sslip.io resolves to the embedded IP.
  IP_DASHED="${NODE_IP//./-}"
  DOMAIN="${RUNAI_DOMAIN:-runai.${IP_DASHED}.sslip.io}"
  CLUSTER_DOMAIN="${RUNAI_CLUSTER_DOMAIN:-cluster.${DOMAIN#*.}}"
  [[ "$CLUSTER_DOMAIN" != "$DOMAIN" ]] || CLUSTER_DOMAIN="cluster.${DOMAIN}"
}

install_k3s() {
  log "Installing k3s ($K3S_CHANNEL)"
  if ! command -v k3s >/dev/null; then
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
      INSTALL_K3S_EXEC="server --disable traefik --write-kubeconfig-mode 644 --default-runtime nvidia --tls-san ${NODE_IP}" sh -
  fi
  until kubectl get nodes 2>/dev/null | grep -q ' Ready'; do sleep 3; done
  mkdir -p "$STATE_DIR"
}

install_helm() {
  command -v helm >/dev/null && return
  log "Installing helm"
  mkdir -p "$STATE_DIR"; echo helm_installed >> "$STATE_DIR/state"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
}

install_gpu_operator() {
  log "Installing NVIDIA GPU Operator"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update >/dev/null
  # DGX OS ships the driver (and normally the container toolkit); k3s auto-registers the nvidia runtime.
  local toolkit=true
  command -v nvidia-ctk >/dev/null && toolkit=false
  [[ $toolkit == true ]] && echo operator_toolkit >> "$STATE_DIR/state"
  helm upgrade -i gpu-operator nvidia/gpu-operator -n gpu-operator --create-namespace \
    --set driver.enabled=false \
    --set toolkit.enabled="$toolkit" \
    --set toolkit.env[0].name=CONTAINERD_CONFIG \
    --set toolkit.env[0].value=/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl \
    --set toolkit.env[1].name=CONTAINERD_SOCKET \
    --set toolkit.env[1].value=/run/k3s/containerd/containerd.sock \
    --set toolkit.env[2].name=CONTAINERD_RUNTIME_CLASS \
    --set toolkit.env[2].value=nvidia \
    --set toolkit.env[3].name=CONTAINERD_SET_AS_DEFAULT \
    --set-string toolkit.env[3].value=true \
    --wait --timeout 15m
  log "Waiting for a GPU to be advertised"
  for _ in $(seq 1 120); do
    kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' | grep -q '[1-9]' && return
    sleep 5
  done
  die "No nvidia.com/gpu resource appeared; check 'kubectl -n gpu-operator get pods'."
}

install_prereqs() {
  log "Installing HAProxy ingress (hostPort 80/443 via k3s servicelb)"
  helm repo add haproxytech https://haproxytech.github.io/helm-charts --force-update >/dev/null
  helm upgrade -i haproxy-kubernetes-ingress haproxytech/kubernetes-ingress \
    -n haproxy-controller --create-namespace \
    --set controller.kind=DaemonSet --set controller.service.type=LoadBalancer \
    --set controller.ingressClass=haproxy --set controller.ingressClassResource.name=haproxy \
    --wait --timeout 10m

  log "Installing Prometheus operator (required by Run:ai cluster)"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
  helm upgrade -i prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    --set grafana.enabled=false --set alertmanager.enabled=false \
    --wait --timeout 10m

  log "Installing Knative Serving (required for Run:ai inference workloads)"
  helm repo add knative-operator https://knative.github.io/operator --force-update >/dev/null
  helm upgrade -i knative-operator knative-operator/knative-operator \
    -n knative-operator --create-namespace --wait --timeout 10m
  kubectl wait --for=condition=Established crd/knativeservings.operator.knative.dev --timeout=5m
  kubectl create namespace knative-serving --dry-run=client -o yaml | kubectl apply -f -
  # Kourier stays ClusterIP so it does not fight HAProxy for ports 80/443 on k3s servicelb.
  # Without a Knative domain, Run:ai greys out the public inference endpoint option.
  kubectl apply -f - <<EOF
apiVersion: operator.knative.dev/v1beta1
kind: KnativeServing
metadata:
  name: knative-serving
  namespace: knative-serving
spec:
  ingress:
    kourier:
      enabled: true
      service-type: ClusterIP
  config:
    domain:
      ${CLUSTER_DOMAIN}: ""
    network:
      ingress-class: kourier.ingress.networking.knative.dev
      domain-template: "{{.Name}}-{{.Namespace}}.{{.Domain}}"
    autoscaler:
      enable-scale-to-zero: "true"
    defaults:
      max-revision-timeout-seconds: "3600"
    features:
      kubernetes.podspec-schedulername: enabled
      kubernetes.podspec-affinity: enabled
      kubernetes.podspec-tolerations: enabled
      kubernetes.podspec-nodeselector: enabled
      kubernetes.podspec-securitycontext: enabled
      kubernetes.podspec-init-containers: enabled
      kubernetes.podspec-volumes-emptydir: enabled
      kubernetes.podspec-persistent-volume-claim: enabled
      kubernetes.podspec-persistent-volume-write: enabled
      kubernetes.containerspec-addcapabilities: enabled
      multi-container: enabled
EOF
  kubectl -n knative-serving wait --for=condition=Ready knativeserving/knative-serving --timeout=10m \
    || die "Knative Serving did not become ready; check 'kubectl -n knative-serving get pods'."
}

make_certs() {
  log "Generating TLS certificates for $DOMAIN"
  local d="$STATE_DIR/certs"; mkdir -p "$d"
  if [[ ! -f $d/ca.crt ]]; then
    openssl req -x509 -newkey rsa:4096 -nodes -days 3650 -subj "/CN=runai-spark-ca" \
      -keyout "$d/ca.key" -out "$d/ca.crt" 2>/dev/null
  fi
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$DOMAIN" -keyout "$d/tls.key" -out "$d/tls.csr" 2>/dev/null
  printf 'subjectAltName=DNS:%s,DNS:%s,DNS:*.%s\n' "$DOMAIN" "$CLUSTER_DOMAIN" "$CLUSTER_DOMAIN" > "$d/san.ext"
  openssl x509 -req -in "$d/tls.csr" -CA "$d/ca.crt" -CAkey "$d/ca.key" -CAcreateserial \
    -days 825 -extfile "$d/san.ext" -out "$d/tls.crt" 2>/dev/null
  cat "$d/tls.crt" "$d/ca.crt" > "$d/fullchain.crt"

  for ns in runai-backend runai; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "$ns" create secret generic runai-ca-cert --from-file=runai-ca.pem="$d/ca.crt" \
      --dry-run=client -o yaml | kubectl apply -f -
  done
  # Run:ai replicates labelled secrets into every project namespace (workloads' oauth2-proxy needs the CA).
  kubectl -n runai label secret runai-ca-cert run.ai/cluster-wide=true run.ai/name=runai-ca-cert --overwrite
  kubectl -n runai-backend create secret tls runai-backend-tls --cert="$d/fullchain.crt" --key="$d/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f -
  # Cluster-side wildcard cert for workspaces/inference endpoints.
  kubectl -n runai create secret tls runai-cluster-domain-tls-secret --cert="$d/fullchain.crt" --key="$d/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f -
}

# Prints: absent | deployed | failed | pending-install | pending-upgrade | ...
release_state() {
  helm status "$1" -n "$2" -o json 2>/dev/null |
    python3 -c 'import sys,json; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null || echo absent
}

diagnose() {
  local rel=$1 ns=$2 state
  state=$(release_state "$rel" "$ns")
  printf '\n\033[1;31m==== %s: INSTALL FAILED ====\033[0m\n' "$rel"
  case "$state" in
    deployed) echo "Helm reports the release as deployed, but it did not become healthy." ;;
    absent)   echo "NOT INSTALLED: Helm has no record of this release. Some hook resources may remain in namespace '$ns'." ;;
    *)        echo "NOT INSTALLED (partial): Helm release state is '$state'. Chart hook jobs/pods ran but the release never completed." ;;
  esac
  echo "Helm log: $STATE_DIR/helm-$rel.log"

  echo; echo "-- Pods in $ns"
  kubectl -n "$ns" get pods -o wide 2>&1 | head -40
  echo; echo "-- Jobs in $ns"
  kubectl -n "$ns" get jobs 2>&1 | head -20
  echo; echo "-- PVCs in $ns"
  kubectl -n "$ns" get pvc 2>&1 | head -20

  local bad p
  bad=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"{print $1":"$3}')
  for entry in $bad; do
    p=${entry%%:*}
    echo; echo "-- $p (${entry##*:}): events"
    kubectl -n "$ns" describe pod "$p" 2>/dev/null | sed -n '/^Events:/,$p' | tail -8
    echo "-- $p: last log lines"
    kubectl -n "$ns" logs "$p" --all-containers --tail=15 2>&1 | tail -15
  done
  echo; echo "-- Recent warning events"
  kubectl -n "$ns" get events --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -10

  echo; echo "-- Likely cause"
  if [[ -z "$(kubectl -n "$ns" get pods --no-headers 2>/dev/null)" && "$state" == absent ]]; then
    echo "Helm failed before deploying anything; the error is shown above (see also $STATE_DIR/helm-$rel.log)."
  elif grep -qE 'ImagePullBackOff|ErrImagePull' <<<"$bad"; then
    echo "Image pulls are failing: check NGC key entitlement, registry credentials and outbound internet from the Spark."
  elif grep -q 'Pending' <<<"$bad"; then
    echo "Pods are Pending: check the PVCs above (storage class) and node CPU/memory (control plane needs ~10 cores / 12GB)."
  elif grep -qE 'CrashLoopBackOff|Error' <<<"$bad"; then
    echo "A pod is crashing: see its log lines above."
  else
    echo "No failing pod found; the hook job was probably still running when the timeout hit. Check the logs above, then retry."
  fi
  echo "Retry: re-run this script (a failed release is removed automatically), or '$0 status', or '$0 remove'."
}

# Runs helm in the background, reports pod progress every 30s, diagnoses on failure.
helm_install() {
  local rel=$1 ns=$2; shift 2
  local state; state=$(release_state "$rel" "$ns")
  if [[ "$state" != absent && "$state" != deployed ]]; then
    log "Removing previous $rel release in state '$state'"
    helm uninstall "$rel" -n "$ns" --timeout 5m >/dev/null 2>&1 || true
  fi
  helm upgrade -i "$rel" "$@" >"$STATE_DIR/helm-$rel.log" 2>&1 &
  local pid=$! t=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 30; t=$((t + 30))
    printf '  [%dm%02ds] %s: %s\n' $((t / 60)) $((t % 60)) "$ns" \
      "$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '{c[$3]++} END{for(k in c) printf "%s=%d ", k, c[k]}')"
  done
  if ! wait "$pid"; then
    tail -5 "$STATE_DIR/helm-$rel.log"
    diagnose "$rel" "$ns"
    exit 1
  fi
}

install_control_plane() {
  log "Installing Run:ai control plane (can take 10-15 minutes)"
  helm repo add runai https://helm.ngc.nvidia.com/nvidia/runai --force-update \
    --username='$oauthtoken' --password="$NGC_API_KEY" >/dev/null
  helm repo update >/dev/null
  for ns in runai-backend runai; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl -n "$ns" create secret docker-registry runai-reg-creds \
      --docker-server=https://nvcr.io --docker-username='$oauthtoken' \
      --docker-password="$NGC_API_KEY" --docker-email=runai@localhost \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  local ver=(); [[ -n "$RUNAI_VERSION" ]] && ver=(--version "$RUNAI_VERSION")
  helm_install runai-backend runai-backend runai/control-plane -n runai-backend "${ver[@]}" \
    --set global.domain="$DOMAIN" \
    --set global.ingress.ingressClass=haproxy \
    --set global.customCA.enabled=true \
    --set tenantsManager.config.adminUsername="$ADMIN_USER" \
    --set-string tenantsManager.config.adminPassword="$ADMIN_PASSWORD" \
    --timeout 30m

  # Chart requests (3x NATS, postgres, keycloak at 1 CPU each) fill the node's CPU requests and starve the cluster chart.
  log "Lowering control plane CPU requests"
  kubectl -n runai-backend set resources statefulset --all --requests=cpu=200m >/dev/null 2>&1 || true
  kubectl -n runai-backend set resources deployment --all --requests=cpu=100m >/dev/null 2>&1 || true

  log "Waiting for control plane pods to become ready"
  local obj
  kubectl -n runai-backend wait --for=condition=available deployment --all --timeout=20m >/dev/null 2>&1 \
    || { diagnose runai-backend runai-backend; die "Control plane deployments did not become available."; }
  for obj in $(kubectl -n runai-backend get statefulset -o name 2>/dev/null); do
    kubectl -n runai-backend rollout status "$obj" --timeout=10m >/dev/null 2>&1 \
      || { diagnose runai-backend runai-backend; die "$obj did not become ready."; }
  done

  log "Waiting for control plane API"
  for _ in $(seq 1 180); do
    code=$(curl -ks -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" || true)
    [[ "$code" =~ ^(200|301|302|401|403)$ ]] && return
    sleep 10
  done
  diagnose runai-backend runai-backend
  die "Helm finished but https://$DOMAIN is not responding (ingress/DNS?). Check 'kubectl -n haproxy-controller get pods,svc' and that $DOMAIN resolves to $NODE_IP."
}

json_get() {
  python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
print(d.get(sys.argv[1],"") if isinstance(d,dict) else "")' "$1"
}
api() { curl -ks --resolve "$DOMAIN:443:127.0.0.1" -H 'Content-Type: application/json' "$@"; }

# Retries until the auth endpoint returns a token; reports the HTTP status/body so failures are visible.
get_token() {
  local payload out code body tok i
  payload=$(python3 -c '
import json,sys; print(json.dumps({"grantType":"password","clientID":"cli","username":sys.argv[1],"password":sys.argv[2]}))' \
    "$ADMIN_USER" "$ADMIN_PASSWORD")
  for i in $(seq 1 90); do
    out=$(api -w '\n%{http_code}' -X POST "https://$DOMAIN/api/v1/token" -d "$payload" || true)
    code=${out##*$'\n'}; body=${out%$'\n'*}
    tok=$(json_get accessToken <<<"$body")
    if [[ -n "$tok" ]]; then echo "$tok"; return; fi
    if (( i == 1 || i % 6 == 0 )); then
      echo "  waiting for auth API (HTTP ${code:-none}): ${body:0:120}" >&2
    fi
    sleep 10
  done
  manual_fallback "token request failed (last HTTP ${code:-none}): ${body:0:200}"
}

register_and_install_cluster() {
  log "Registering cluster '$CLUSTER_NAME' with the control plane"
  local tok uuid info cp_ver
  # The cluster chart must match the control plane chart that is actually installed.
  cp_ver=$(helm list -n runai-backend -o json | python3 -c '
import sys,json
for r in json.load(sys.stdin):
    if r["name"]=="runai-backend": print(r["chart"].split("control-plane-",1)[-1])')
  [[ -n "$cp_ver" ]] || die "Could not determine installed control plane version."
  tok=$(get_token)
  [[ -n "$tok" ]] || manual_fallback "could not obtain API token"

  uuid=$(api -X POST "https://$DOMAIN/api/v1/clusters" -H "Authorization: Bearer $tok" \
    -d "{\"name\":\"$CLUSTER_NAME\",\"domain\":\"https://$CLUSTER_DOMAIN\"}" | json_get uuid)
  [[ -n "$uuid" ]] || uuid=$(api "https://$DOMAIN/api/v1/clusters" -H "Authorization: Bearer $tok" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: d=[]
for c in (d if isinstance(d,list) else d.get("clusters",[])):
    if c.get("name")==sys.argv[1]: print(c["uuid"])' "$CLUSTER_NAME")
  [[ -n "$uuid" ]] || manual_fallback "could not create cluster"

  info=$(api "https://$DOMAIN/api/v1/clusters/$uuid/cluster-install-info?version=$cp_ver" \
    -H "Authorization: Bearer $tok" | json_get installationStr)
  [[ -n "$info" ]] || manual_fallback "could not fetch cluster install info"

  # Reuse the --set values (controlPlane.url, clientSecret, cluster.uid, cluster.url, version) from the generated command.
  mapfile -t args < <(INFO="$info" python3 - <<'PY'
import os, shlex
t = shlex.split(os.environ["INFO"].replace("\\\n", " "))
i = 0
while i < len(t):
    if t[i] == "--version" and i + 1 < len(t):
        i += 2
    elif t[i].startswith("--version="):
        i += 1
    elif t[i] in ("--set", "--set-string") and i + 1 < len(t):
        print(t[i]); print(t[i+1]); i += 2
    else:
        i += 1
PY
)
  log "Installing Run:ai cluster components (chart $cp_ver)"
  # The container toolkit's NVML memory query is unsupported on GB10 (unified memory) and crash-loops, so it is disabled.
  helm_install runai-cluster runai runai/runai-cluster -n runai --create-namespace "${args[@]}" \
    --version "$cp_ver" \
    --set global.customCA.enabled=true \
    --set clusterConfig.global.ingress.ingressClass=haproxy \
    --set clusterConfig.runai-container-toolkit.enabled=false \
    --set clusterConfig.runai-container-toolkit-reservation.enabled=false \
    --timeout 15m

  log "Waiting for cluster to report Connected"
  for _ in $(seq 1 60); do
    st=$(api "https://$DOMAIN/api/v1/clusters/$uuid" -H "Authorization: Bearer $tok" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: d={}
s=d.get("status") if isinstance(d,dict) else ""
print(s.get("state","") if isinstance(s,dict) else s)' || true)
    [[ "${st,,}" == "connected" ]] && return
    sleep 10
  done
  echo "Cluster not yet reported Connected; check the UI (Resources > Clusters)." >&2
}

manual_fallback() {
  cat >&2 <<EOF

Automatic cluster registration failed: $1
Log in at https://$DOMAIN as $ADMIN_USER, follow the onboarding wizard (cluster URL: https://$CLUSTER_DOMAIN),
and run the generated helm command with these extra flags:
  --set global.customCA.enabled=true --set clusterConfig.global.ingress.ingressClass=haproxy
EOF
  print_summary
  exit 1
}

print_summary() {
  local token=""
  [[ -f /var/lib/rancher/k3s/server/node-token ]] && token=$(cat /var/lib/rancher/k3s/server/node-token)
  cat <<EOF

=====================================================================
 Run:ai on DGX Spark is ready
   Web UI : https://$DOMAIN
   API URL: https://$DOMAIN/api/v1
   Login  : $ADMIN_USER / $ADMIN_PASSWORD
   CA cert (import on client machines to trust HTTPS): $STATE_DIR/certs/ca.crt
   Add a Spark node: sudo ./deploy.sh join $NODE_IP $token
=====================================================================
EOF
}

cmd_install() {
  preflight
  install_k3s
  install_helm
  install_gpu_operator
  install_prereqs
  make_certs
  install_control_plane
  register_and_install_cluster
  print_summary
}

cmd_join() {
  need_root
  local server="${1:-}" token="${2:-}"
  [[ -n "$server" && -n "$token" ]] || die "usage: $0 join <server-ip> <node-token>"
  curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL="$K3S_CHANNEL" \
    K3S_URL="https://$server:6443" K3S_TOKEN="$token" sh -
  echo "Joined. The GPU Operator and Run:ai will configure the node automatically."
}

cmd_remove() {
  need_root
  if [[ "${1:-}" != "--yes" ]]; then
    echo "This permanently removes k3s, all workloads, volumes/data, certificates and Helm repo credentials."
    read -r -p "Type 'remove' to continue: " ans
    [[ "$ans" == remove ]] || die "Aborted."
  fi
  local state=""; [[ -f "$STATE_DIR/state" ]] && state=$(cat "$STATE_DIR/state")

  if command -v helm >/dev/null && [[ -f $KUBECONFIG ]] && kubectl get nodes >/dev/null 2>&1; then
    log "Uninstalling Helm releases"
    kubectl delete knativeserving knative-serving -n knative-serving --timeout=5m >/dev/null 2>&1 || true
    for rel in runai-cluster:runai runai-backend:runai-backend knative-operator:knative-operator prometheus:monitoring \
               haproxy-kubernetes-ingress:haproxy-controller gpu-operator:gpu-operator; do
      helm uninstall "${rel%%:*}" -n "${rel##*:}" --timeout 5m >/dev/null 2>&1 || true
    done
  fi

  log "Removing k3s (cluster state, containers, images, volumes, CNI and iptables rules)"
  [[ -x /usr/local/bin/k3s-uninstall.sh ]] && /usr/local/bin/k3s-uninstall.sh || true
  [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]] && /usr/local/bin/k3s-agent-uninstall.sh || true
  rm -rf /var/lib/rancher /etc/rancher /var/lib/kubelet /run/k3s

  if grep -q operator_toolkit <<<"$state"; then
    rm -rf /usr/local/nvidia/toolkit
  fi
  rm -rf /run/nvidia

  if command -v helm >/dev/null; then
    log "Removing Helm repositories and cached indexes"
    local cache; cache=$(helm env HELM_REPOSITORY_CACHE)
    for r in nvidia haproxytech prometheus-community knative-operator runai; do
      helm repo remove "$r" >/dev/null 2>&1 || true
      rm -f "$cache/$r-index.yaml" "$cache/$r-charts.txt"
    done
    rm -f "$cache"/*.tgz
  fi
  if grep -q helm_installed <<<"$state"; then rm -f /usr/local/bin/helm; fi

  rm -rf "$STATE_DIR"
  log "Removed. Reboot is recommended to clear leftover network interfaces."
}

cmd_status() {
  need_root
  local ok="\033[1;32mOK\033[0m" bad="\033[1;31mNOT OK\033[0m"
  command -v k3s >/dev/null || { echo "k3s: not installed (nothing deployed)"; return; }
  printf 'k3s node ready : '; kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready' && echo -e "$ok" || echo -e "$bad"
  printf 'GPUs advertised: %s\n' "$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)"
  for rel in gpu-operator:gpu-operator haproxy-kubernetes-ingress:haproxy-controller prometheus:monitoring \
             knative-operator:knative-operator runai-backend:runai-backend runai-cluster:runai; do
    printf '%-28s: %s\n' "${rel%%:*}" "$(release_state "${rel%%:*}" "${rel##*:}")"
  done
  local pods; pods=$(kubectl -n runai-backend get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)
  echo "control-plane pods not ready: $pods"
  NODE_IP="${NODE_IP:-$(detect_ip)}"; DOMAIN="${RUNAI_DOMAIN:-runai.${NODE_IP//./-}.sslip.io}"
  printf 'UI https://%s : HTTP %s\n' "$DOMAIN" "$(curl -ks -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" 2>/dev/null)"
}

case "${1:-install}" in
  status)    cmd_status ;;
  install)   cmd_install ;;
  join)      shift; cmd_join "$@" ;;
  remove|uninstall) shift; cmd_remove "$@" ;;
  *) die "usage: $0 [install | status | join <server-ip> <token> | remove [--yes]]" ;;
esac
