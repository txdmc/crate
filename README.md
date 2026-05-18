# Pelico

Pelico is a self-hosted inventory tracking system distributed as a **secure, plug-and-play appliance**. Customers either purchase a physical device or download a VM image and boot it inside their own infrastructure. Once running, the appliance exposes a web UI at `http://pelico` on the local network — no cloud dependency required.

---

## How It Works

```
Customer network
│
├── Physical appliance  ──┐
│   (bare-metal, x86-64)  │
│                         ▼
└── Virtual appliance  ── k3s (single-node Kubernetes)
    (OVA / AMI / VHDX)       └── nginx ingress
                                  └── pelico app  ←→  PostgreSQL + MinIO
```

The appliance image is built with Packer. At boot it runs a hardened Ubuntu 24.04 OS with k3s pre-installed and the Pelico Helm chart already deployed. Customers navigate to `http://pelico` to complete the first-run wizard (license, admin credentials, network settings).

---

## Supported Platforms

| Platform | Format | Builder |
|---|---|---|
| VMware Workstation / Fusion | VMDK + VMX | `vmware-iso` |
| VMware vSphere / ESXi | VM Template | `vsphere-iso` |
| VirtualBox | OVA | `virtualbox-iso` |
| Microsoft Hyper-V | VHDX | `hyperv-iso` |
| Xen / XCP-ng / KVM | RAW disk | `qemu` |
| AWS | AMI | `amazon-ebs` |
| Azure | Managed Image | `azure-arm` |
| GCP | GCE Image | `googlecompute` |

---

## Repository Structure

```
.
├── application/          FastAPI backend (inventory API, health probes, setup)
│   ├── app.py
│   ├── Dockerfile
│   └── requirements.txt
│
├── charts/
│   └── pelico/           Helm chart for the full appliance stack
│       ├── Chart.yaml
│       ├── values.yaml           Production defaults
│       ├── values-local.yaml     Docker Desktop / local k8s overrides
│       └── templates/
│           ├── _helpers.tpl
│           ├── configmap.yaml
│           ├── deployment.yaml
│           ├── ingress.yaml
│           ├── secret.yaml
│           ├── service.yaml
│           └── serviceaccount.yaml
│
├── packer/               Packer HCL2 templates for all supported platforms
│   ├── pelico.pkr.hcl    Build definitions (all builders)
│   ├── variables.pkr.hcl Variable declarations
│   ├── scripts/          Provisioning shell scripts (01-base … 99-cleanup)
│   └── http/             Ubuntu autoinstall cloud-init seed files
│
├── docs/                 Operator and end-user documentation
├── Makefile              Developer convenience targets
└── AGENTS.md             AI-agent context file
```

---

## Local Development (Docker Desktop)

This is the fastest way to iterate without building an appliance image.

### Prerequisites

| Tool | Install |
|---|---|
| Docker Desktop (Kubernetes enabled) | [docs.docker.com](https://docs.docker.com/desktop/kubernetes/) |
| `helm` | `brew install helm` |
| `kubectl` | bundled with Docker Desktop |
| `make` | bundled with Xcode CLT |

### First-time setup

```bash
# 1. Install the nginx ingress controller into the local cluster
make dev-deps

# 2. Add 'pelico' to /etc/hosts so the browser can resolve it
make hosts        # adds: 127.0.0.1  pelico

# 3. Build the app image and deploy the Helm chart
make dev-up

# 4. Open the app
open http://pelico
```

### Daily workflow

```bash
make dev-up       # rebuild image + helm upgrade (idempotent)
make dev-logs     # tail application logs
make dev-status   # show pods, services, ingress
make dev-psql     # open a psql shell in the PostgreSQL pod
make dev-restart  # rolling restart without a full redeploy
make dev-down     # tear everything down
```

Run `make help` for a full list of targets.

---

## Helm Chart

### Subchart dependencies

The chart depends on the [Bitnami](https://github.com/bitnami/charts) charts for PostgreSQL and MinIO. Update the lock file before the first install:

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm dependency update charts/pelico
```

### Deploying to production / appliance

```bash
helm upgrade --install pelico charts/pelico \
  --namespace pelico --create-namespace \
  --set postgresql.auth.password=<strong-password> \
  --set minio.auth.rootPassword=<strong-password> \
  --set app.secretKey=<32-char-random-string>
```

### Key values

| Value | Default | Description |
|---|---|---|
| `app.setupRequired` | `true` | Redirect all traffic to the setup wizard until `false` |
| `app.secretKey` | `""` | **Required** — 32+ char random string for signing |
| `postgresql.auth.password` | `""` | **Required** |
| `minio.auth.rootPassword` | `""` | **Required** |
| `ingress.hosts[0].host` | `pelico` | Hostname the appliance answers on |

---

## Building Appliance Images (Packer)

### Prerequisites

```bash
brew install packer
packer plugins install github.com/hashicorp/vmware
packer plugins install github.com/hashicorp/virtualbox
# ... (see packer/pelico.pkr.hcl for full plugin list)
```

### Build a single target

```bash
cd packer

# VirtualBox OVA (good for local import into any hypervisor)
packer build -only='virtualbox-iso.pelico_virtualbox' .

# VMware VMDK
packer build -only='vmware-iso.pelico_vmware' .

# AWS AMI (requires AWS credentials in environment)
packer build -only='amazon-ebs.pelico_aws' \
  -var="aws_region=us-east-1" .

# GCP image
packer build -only='googlecompute.pelico_gcp' \
  -var="gcp_project_id=my-project" .
```

### Override variables

Copy `packer/example.pkrvars.hcl` (see `packer/` directory) and pass it:

```bash
packer build -var-file=my-env.pkrvars.hcl .
```

### Xen / XCP-ng

Build with the QEMU builder then import the raw disk:

```bash
packer build -only='qemu.pelico_qemu' .
xe vm-import filename=output/qemu/pelico-1.0.0.raw format=raw sr-uuid=<YOUR-SR-UUID>
```

---

## Application API

Once the appliance is running, the FastAPI backend is available under `/api/`:

| Endpoint | Method | Description |
|---|---|---|
| `/health` | GET | Liveness probe (always 200 if process is up) |
| `/ready` | GET | Readiness probe (200 only if DB is reachable) |
| `/setup` | GET | Returns setup wizard status |
| `/inventory` | GET | List all inventory items |
| `/inventory` | POST | Add an item `{"id","name","quantity"}` |
| `/inventory/{id}` | DELETE | Remove an item |
| `/api/docs` | GET | Swagger UI |

---

## Architecture Decisions

- **k3s** — single-binary Kubernetes distribution designed for edge/appliance use. Includes Traefik by default; we replace it with nginx ingress for consistency with the cloud ingress-nginx ecosystem.
- **Helm chart** — the chart deploys identically on Docker Desktop and inside the appliance, ensuring parity between dev and production.
- **Packer HCL2** — one template file covers all builders; per-platform parameters are passed via variables, keeping the build DRY.
- **Ubuntu 24.04 LTS** — five-year LTS lifecycle suitable for an appliance that customers may not update frequently.
- **Bitnami subcharts** — well-maintained, production-grade PostgreSQL and MinIO subcharts avoid reinventing stateful service management.

---

## Contributing

1. Follow the branching convention: `feat/*`, `fix/*`, `chore/*`
2. Never commit directly to `main`
3. Run `make lint` before opening a PR
