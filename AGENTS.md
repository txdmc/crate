# AGENTS.md — Pelico Project Context

This file gives AI coding agents the context needed to work on this project
without re-exploring the entire repository from scratch. Update it whenever
significant architectural decisions are made or the structure changes.

---

## Project Purpose

Pelico is a **self-hosted inventory tracking appliance**. The product is
distributed as a VM image or physical hardware device. Customers boot it inside
their own infrastructure (on-prem or cloud), navigate to `http://pelico` on
their LAN, and complete a first-run wizard before using the application.

There is no SaaS layer. The appliance must work air-gapped.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Python 3.12 |
| Web framework | FastAPI (uvicorn) |
| Database | PostgreSQL (bitnami helm subchart) |
| Object storage | MinIO (bitnami helm subchart) |
| Container runtime | Docker |
| Kubernetes | k3s (appliance), Docker Desktop (local dev) |
| Ingress | nginx ingress controller |
| Package management | Helm v3 |
| Image build | Packer HCL2 >= 1.10 |
| Base OS | Ubuntu 24.04 LTS |

---

## Directory Map

```
application/        FastAPI source + Dockerfile
  app.py            Main application: /health, /ready, /setup, /inventory
  Dockerfile        Runs as UID 1000; python:3.12-slim base
  requirements.txt  Pinned deps (fastapi, uvicorn, psycopg2-binary, pydantic)

charts/pelico/      Helm chart — deploys the full appliance stack
  Chart.yaml        Chart metadata; declares bitnami postgresql + minio deps
  values.yaml       Production defaults (passwords intentionally blank)
  values-local.yaml Docker Desktop overrides (small resources, dev passwords)
  templates/
    _helpers.tpl            Named templates (fullname, labels, etc.)
    deployment.yaml         App deployment with init container (waits for PG)
    service.yaml            ClusterIP service
    ingress.yaml            nginx-class ingress for host 'pelico'
    configmap.yaml          Non-secret env vars (host, db name, log level)
    secret.yaml             Passwords + SECRET_KEY
    serviceaccount.yaml     Dedicated SA, automountServiceAccountToken=false

packer/
  pelico.pkr.hcl    All builders: vmware-iso, vsphere-iso, virtualbox-iso,
                    hyperv-iso, qemu, amazon-ebs, azure-arm, googlecompute
  variables.pkr.hcl HCL2 variable declarations with defaults
  scripts/          Provisioning scripts (to be created):
                    01-base.sh, 02-k3s.sh, 03-helm-deploy.sh,
                    04-network.sh, 05-firstrun.sh, 99-cleanup.sh
  http/             Ubuntu 24.04 autoinstall seed (to be created):
                    user-data, meta-data

Makefile            Developer targets — see `make help`
docs/               Operator documentation (sparse; expand as features land)
```

---

## Key Conventions

### Git branching (MANDATORY)
- Never commit to `main` directly.
- Always branch: `feat/<desc>`, `fix/<desc>`, `chore/<desc>`.
- Pull `main` before creating a branch, even mid-session.
- Run `git branch` before every commit to confirm you are NOT on main.

### Application
- Health probe: `GET /health` — always 200 if process is alive.
- Readiness probe: `GET /ready` — 200 only when PostgreSQL is reachable.
- All inventory routes check `SETUP_REQUIRED` and redirect to `/setup` when true.
- Config is injected entirely via environment variables (set by the Helm chart).
- `SETUP_REQUIRED` is a ConfigMap value; setting it to `"false"` and doing a
  Helm upgrade is what "completing" the wizard does (future work).

### Helm chart
- Passwords are required values with no defaults — Helm will error if unset.
  This is intentional; never hard-code passwords in `values.yaml`.
- `values-local.yaml` is the only place dev/insecure passwords are allowed.
- Pod `securityContext` runs as UID 1000 (`pelico` user). The Dockerfile
  creates that user to match.
- Dep update command: `helm dependency update charts/pelico`

### Packer
- HCL2 format only (legacy JSON template.json is a stub from the initial
  skeleton — ignore it; use `pelico.pkr.hcl`).
- Builders that need a local hypervisor (vmware, virtualbox, hyperv, qemu)
  only run when that hypervisor is present on the build machine.
- Cloud builders (aws, azure, gcp) need credentials in the environment.
- All ISO-based builders share the same `local.iso_boot_command` and
  `local.provision_scripts` locals defined at the top of `pelico.pkr.hcl`.

---

## What Is Complete

- [x] FastAPI application with health probes and setup redirect
- [x] Dockerfile (python:3.12-slim, non-root UID 1000)
- [x] Full Helm chart (deployment, service, ingress, configmap, secret, SA)
- [x] `values-local.yaml` for Docker Desktop
- [x] `Makefile` with `dev-deps`, `dev-up`, `dev-down`, `dev-logs`, etc.
- [x] Packer HCL2 template covering all 8 platforms
- [x] Packer variable declarations

## What Still Needs Work

- [ ] `packer/scripts/` — provisioning shell scripts (k3s install, helm deploy,
      network/mDNS setup, cleanup)
- [ ] `packer/http/` — Ubuntu 24.04 autoinstall `user-data` + `meta-data`
- [ ] PostgreSQL-backed inventory persistence (currently in-memory dict)
- [ ] First-run wizard UI (currently just a JSON API stub at `/setup`)
- [ ] License management (validation, activation)
- [ ] mDNS / Avahi setup so `pelico.local` works without manual `/etc/hosts`
- [ ] TLS (cert-manager or self-signed, configurable via values)
- [ ] CI pipeline (build image, push to ghcr.io, build packer images)

---

## Local Dev Quick Reference

```bash
# One-time setup
make dev-deps        # install ingress-nginx into Docker Desktop k8s
make hosts           # add 127.0.0.1 pelico to /etc/hosts

# Daily
make dev-up          # build image + helm upgrade
make dev-logs        # tail app logs
make dev-status      # pods / svc / ingress overview
make dev-psql        # psql into postgresql pod
make dev-down        # full teardown
make lint            # helm lint

# Helm dependency refresh (after Chart.yaml dep changes)
make helm-deps
```

---

## Environment Variables (Injected by Helm)

| Variable | Source | Notes |
|---|---|---|
| `LOG_LEVEL` | ConfigMap | DEBUG / INFO / WARNING / ERROR |
| `SETUP_REQUIRED` | ConfigMap | "true" until wizard completed |
| `POSTGRES_HOST` | ConfigMap | `<release>-postgresql` |
| `POSTGRES_DB` | ConfigMap | default `pelico` |
| `POSTGRES_USER` | Secret | |
| `POSTGRES_PASSWORD` | Secret | |
| `MINIO_ENDPOINT` | ConfigMap | `http://<release>-minio:9000` |
| `MINIO_ACCESS_KEY` | Secret | |
| `MINIO_SECRET_KEY` | Secret | |
| `SECRET_KEY` | Secret | 32+ char random string |

---

## Architecture Notes

- **k3s was chosen** over full k8s because it ships as a single binary, starts
  in seconds, and is designed for edge/appliance deployments. Traefik is
  disabled in the provisioning scripts and replaced with nginx ingress for
  ecosystem consistency.
- **Bitnami subcharts** manage PostgreSQL and MinIO. Do not create custom
  StatefulSets for these — let the subcharts handle upgrades and probes.
- **All eight Packer builders share one provisioning script set.** Cloud
  builders (AWS/Azure/GCP) skip the k3s install (they use managed k8s services
  or run standalone); on-prem builders install k3s and pre-deploy the Helm
  chart so the appliance is functional on first boot.
- **No Kubernetes namespaced RBAC is needed yet** — the ServiceAccount has
  `automountServiceAccountToken: false` and no ClusterRole bindings. Add only
  when a specific feature requires API access.
