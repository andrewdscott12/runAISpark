# runAISpark

A single script, `deploy.sh`, that turns an NVIDIA DGX Spark into a self-hosted [NVIDIA Run:ai](https://run-ai-docs.nvidia.com/) system. It installs Kubernetes, the GPU stack, and both the Run:ai control plane and cluster, then prints a Web UI URL and an API URL that other machines on the local network can use.

It is built for prototyping and development, not enterprise use: single control plane, no redundancy, local storage by default.

## What it installs

| Step | Component | Notes |
|------|-----------|-------|
| 1 | [k3s](https://k3s.io) (Kubernetes v1.34 line) | Traefik disabled; the bundled `local-path` storage class is the default; `nvidia` is the default container runtime so GPU pods (including Run:ai's own) get the GPU libraries |
| 2 | NVIDIA GPU Operator | Driver install disabled (DGX OS ships the driver); container toolkit installed only if not already on the host |
| 3 | HAProxy Kubernetes Ingress | Exposes ports 80/443 on the node via k3s servicelb |
| 4 | kube-prometheus-stack | Prometheus operator only (Grafana and Alertmanager off); required by the Run:ai cluster |
| 5 | Knative Serving | Required for Run:ai inference workloads; Kourier ingress stays ClusterIP |
| 6 | TLS certificates | A private CA plus a certificate for the Run:ai host names (self-signed) |
| 7 | Run:ai control plane | Helm chart `runai/control-plane` from NGC, namespace `runai-backend`; CPU requests are lowered afterwards so the cluster components fit on one node |
| 8 | Run:ai cluster | Registered automatically through the control plane API, namespace `runai` |

Helm is installed too if it is missing.

## Requirements

**Hardware / OS**
- A DGX Spark (or another Linux machine with an NVIDIA GPU and driver) running DGX OS / Ubuntu.
- `nvidia-smi` must work.
- Roughly 10 CPU cores and 12 GB RAM free for the control plane, plus room for workloads. Allow 110 GB+ of disk.
- `root` access (`sudo`). The script installs system services and cannot run unprivileged.
- Tools: `curl`, `python3`, `openssl` (all present on DGX OS).

**Accounts / credentials**
- An **NGC API key** from an NGC organization that is **entitled to NVIDIA Run:ai**. Run:ai is licensed software; a key without the entitlement gets `403 Forbidden` when downloading the chart.
  - Create a Personal API key in NGC with the NGC Catalog service enabled.

**Network**
- Outbound internet access from the Spark (NGC, GitHub, Helm chart repos, container registries).
- Inbound from your LAN: TCP 443 (UI/API) and 80. If you add nodes later, TCP 6443 as well, plus node-to-node connectivity.
- A host name that resolves to the Spark from both client machines and pods inside the cluster. By default the script uses `runai.<ip-with-dashes>.sslip.io` (for example `runai.192-168-1-157.sslip.io`), which resolves through public DNS (sslip.io) with no setup. This requires working internet DNS. To use your own DNS instead, set `RUNAI_DOMAIN`.

**Important:** do not run this on a machine whose Kubernetes you care about. The script installs k3s and assumes it owns the node.

## Usage

Copy the script to the Spark and run it there.

```bash
sudo NGC_API_KEY=<your-ngc-key> ./deploy.sh
```

(If you export `NGC_API_KEY` first, use `sudo -E`.)

A full install takes roughly 15-30 minutes, mostly pulling images. Progress is printed every 30 seconds as pod status counts. On success it prints:

```
 Run:ai on DGX Spark is ready
   Web UI : https://runai.<ip>.sslip.io
   API URL: https://runai.<ip>.sslip.io/api/v1
   Login  : admin@runai.local / Admin123!
   CA cert (import on client machines to trust HTTPS): /var/lib/runai-spark/certs/ca.crt
   Add a Spark node: sudo ./deploy.sh join <ip> <token>
```

### Commands

| Command | Purpose |
|---------|---------|
| `sudo ./deploy.sh` or `install` | Full install. Safe to re-run; it resumes where it left off |
| `sudo ./deploy.sh status` | Reports node readiness, GPUs advertised, the Helm state of each component, pods not ready, and the UI HTTP status |
| `sudo ./deploy.sh join <server-ip> <node-token>` | Joins an additional machine to the cluster as a k3s agent |
| `sudo ./deploy.sh remove [--yes]` | Tears everything down (see below). `uninstall` is an alias |

### Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `NGC_API_KEY` | (required) | NGC key entitled to Run:ai |
| `ADMIN_USER` | `admin@runai.local` | Initial admin login. Must look like an email address |
| `ADMIN_PASSWORD` | `Admin123!` | Initial admin password (see policy below) |
| `RUNAI_DOMAIN` | `runai.<ip>.sslip.io` | Host name for the UI/API; must resolve to the Spark |
| `RUNAI_CLUSTER_DOMAIN` | `cluster.<ip>.sslip.io` | Host name used for workloads exposed by the cluster |
| `CLUSTER_NAME` | `spark` | Name of the cluster registered in Run:ai |
| `RUNAI_VERSION` | latest | Pin the control plane chart version |
| `K3S_CHANNEL` | `v1.34` | k3s release channel (Run:ai supports Kubernetes 1.34 to 1.36) |
| `NODE_IP` | auto-detected | Override the detected node IP |

### About the default credentials

Run:ai requires the admin user to be an email address and the password to have at least 8 characters including upper case, lower case, a digit, and one of `- ! @ # $ % ^ & * ( ) _ + =`. A plain `admin/admin` is rejected, so the defaults above are used. **Change the password after first login**, or set `ADMIN_USER` / `ADMIN_PASSWORD` before installing. If you supply an invalid password, the control plane stores it anyway and a later `helm upgrade` will not fix it; run `remove` and install again.

## Using it

1. Import `/var/lib/runai-spark/certs/ca.crt` into your client machine's trust store (or accept the browser warning). The certificate is self-signed.
2. Open the Web UI URL and log in.
3. The API is at the printed API URL. Authenticate against `/api/v1/token`.
4. Install the Run:ai CLI from the UI to submit jobs from your own machine.

## Running workloads

Create a project in the UI first (for example `inferencetest`). Run:ai puts each project in a namespace named `runai-<project>`, so the examples below use `runai-inferencetest`.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export NS=runai-inferencetest
```

### Request a whole GPU

On the Spark, request **1 whole GPU** (GPU devices = 1, no fraction and no GPU memory setting). Fractional requests make Run:ai start a `gpu-reservation` pod, and that pod crash-looped on the Spark in testing (see Limitations).

The Run:ai CLI syntax varies by version, so check your flags first:

```bash
runai inference submit --help
runai workspace submit --help
```

The UI (Workloads > New workload > Inference) is the most reliable way to submit. A NIM from NGC needs an image, the port the server listens on (8000 for NIM), your NGC key as an environment variable, and 1 GPU device.

### Check status

```bash
kubectl -n $NS get pods
kubectl -n $NS get inferenceworkload
POD=$(kubectl -n $NS get pod -l serving.knative.dev/service=<workload-name> -o name | head -1)
kubectl -n $NS logs $POD --all-containers --tail=40
```

A pod showing `2/2 Running` is not necessarily ready to serve. The first start of a large model can spend several minutes loading weights and compiling GPU kernels, and requests return `502 Bad Gateway` until that finishes. Poll the readiness endpoint:

```bash
curl -s localhost:8000/v1/health/ready
```

### Call a model from the Spark

Inference workloads default to a private, in-cluster URL. Forward a local port to the pod:

```bash
kubectl -n $NS port-forward $POD 8000:8000 &
curl -s localhost:8000/v1/models
curl -s localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<model-id>","messages":[{"role":"user","content":"Say hello"}],"max_tokens":500}'
```

Use the model ID returned by `/v1/models`. Some reasoning models print their thinking before the answer, so a small `max_tokens` can cut the reply off mid-thought.

### Call a model from another machine on the LAN

Bind the forward to all interfaces:

```bash
pkill -f 'port-forward.*8000:8000'   # free the port if an earlier forward is running
kubectl -n $NS port-forward --address 0.0.0.0 $POD 8000:8000
```

Then from the other machine:

```bash
curl http://<spark-hostname>:8000/v1/models
```

This endpoint has no authentication and ends when the command stops, so use it for testing only. If the connection is refused or times out, check the Spark's firewall (`sudo ufw status`). For a lasting endpoint, enable the public/external access option when you create the inference workload. That option is only available once Knative has a domain configured; the script sets it to the cluster domain (`cluster.<ip>.sslip.io`), and on a machine installed before that change you can add it with `kubectl -n knative-serving patch knativeserving knative-serving --type merge -p '{"spec":{"config":{"domain":{"cluster.<ip-with-dashes>.sslip.io":""},"network":{"domain-template":"{{.Name}}-{{.Namespace}}.{{.Domain}}"}}}}'`. It is not yet verified that traffic then reaches the workload from other machines: Kourier is ClusterIP-only, so the URL may still need an ingress route.

## Removing everything

```bash
sudo ./deploy.sh remove
```

You are asked to type `remove` to confirm (use `--yes` to skip). It will:

- uninstall the Helm releases,
- run the k3s uninstaller (removes the cluster, containers, images, volumes, CNI and firewall rules),
- delete `/var/lib/rancher`, `/etc/rancher`, `/var/lib/kubelet`, `/run/k3s`, `/run/nvidia`,
- remove the Helm repositories the script added (including the stored NGC key) and their cached indexes,
- remove the `helm` binary only if the script installed it,
- delete `/var/lib/runai-spark` (certificates and logs).

All Run:ai data and anything running in the cluster is lost. A reboot afterwards is recommended. The NVIDIA driver and the host container toolkit are not touched.

## Multiple Sparks

`./deploy.sh join <server-ip> <node-token>` runs the k3s agent installer on another machine; the GPU Operator then configures it. The command and token are printed at the end of a successful install (the token is `/var/lib/rancher/k3s/server/node-token` on the first node). This path is **not yet tested** on a multi-node cluster. Things to plan for:

- The ingress and the sslip.io host name point at the first node's IP.
- The default storage class is node-local, so volumes live on whichever node they were created on.
- Fast interconnect between nodes is not configured by this script.

## Storage

The cluster uses k3s `local-path` volumes by default. NFS and S3 are not configured by the script; add them afterwards as Run:ai data sources or Kubernetes storage classes.

## Troubleshooting

**`403 Forbidden` downloading the chart.** The NGC key is not entitled to Run:ai or is from the wrong org. Test it:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' -u '$oauthtoken:'"$NGC_API_KEY" \
  https://helm.ngc.nvidia.com/nvidia/runai/charts/control-plane-<version>.tgz
```

**`ImagePullBackOff`.** The script creates a `runai-reg-creds` pull secret from your key. If pods still cannot pull images, the key lacks access to the Run:ai images, or the Spark has no outbound access to `nvcr.io`.

**`kubectl` talks to a different cluster.** Your shell may have another kubeconfig (for example minikube). Use the k3s one:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

**An install step fails.** The script prints a diagnosis: Helm release state, pods, jobs, PVCs, events, and log tails for failing pods, plus a likely cause. Helm output is saved in `/var/lib/runai-spark/helm-<release>.log`. A failed release is cleaned up automatically on the next run, so just fix the cause and re-run.

**Cluster registration fails.** The script registers the cluster through the control plane API. If that fails, it prints the manual steps: log in, follow the onboarding wizard in the UI, and add `--set global.customCA.enabled=true --set clusterConfig.global.ingress.ingressClass=haproxy` to the Helm command it generates.

**UI unreachable from another machine.** Check that the host name resolves to the Spark's IP (`getent hosts runai.<ip>.sslip.io`), that ports 80/443 are open, and run `sudo ./deploy.sh status`.

**Cluster shows as Disconnected or has service issues.** Check the pods in the `runai` namespace (`runai-agent`, `cluster-sync`, `assets-sync`) and the Run:ai documentation's cluster troubleshooting section.

## Security notes

- The default admin password is public; change it.
- The TLS certificates are self-signed. The CA private key is in `/var/lib/runai-spark/certs/` (root only); `remove` deletes it.
- Your NGC key is stored in the `runai-reg-creds` Kubernetes secrets and in Helm's repository configuration. `remove` deletes both.
- Anyone who can reach the Spark on port 443 can reach the login page; keep it on a trusted network.

## Limitations

- Single control plane node, no high availability.
- The Run:ai container toolkit is disabled. On the Spark's GB10 GPU (unified memory) its NVML memory query returns "Not Supported" and the daemon crash-loops, which keeps the cluster from becoming healthy. As a result, features that depend on it (fractional GPUs and GPU-memory limits/accounting) are unavailable; whole-GPU workloads are unaffected.
- Run:ai is third-party licensed software; this repository only automates its documented installation.
- The control plane API calls used for automatic cluster registration come from observed behavior, so a future Run:ai version may need the script updated.
- Fractional GPU requests did not work in testing: the `gpu-reservation` pod failed with `exec /workspace/resource-reservation: no such file or directory`. That usually means a binary built for another CPU architecture, and the Spark is ARM64, but the image architecture was not confirmed. Use whole-GPU requests, or try a newer `RUNAI_VERSION`.
- Unified memory is shared between the GPU, the OS and every cluster service. A model server that reserves most GPU memory (vLLM defaults to 75-90%) leaves little for everything else.
- Distributed training operators and other optional Run:ai integrations are not installed.
- The control plane CPU-request reduction and the `nvidia` default runtime were applied by hand on the tested machine and have not been verified from a clean run of the script.
