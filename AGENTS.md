# AGENTS.md — Crate Project Context

This file gives AI coding agents the context needed to work on this project
without re-exploring the entire repository from scratch. Update it whenever
significant architectural decisions are made or the structure changes.

---

## Project Purpose

Crate is a **self-hosted inventory tracking appliance**. The product is
distributed as a VM image or physical hardware device. Customers boot it inside
their own infrastructure (on-prem or cloud), navigate to `http://crate` on
their LAN, and complete a first-run wizard before using the application.

There is no SaaS layer. The appliance must work air-gapped.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Python 3.12 |
| Web framework | FastAPI (uvicorn) |
| Database | PostgreSQL 17-alpine (inline Helm templates — no bitnami) |
| Object storage | MinIO (inline Helm templates — no bitnami) |
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
  app.py            Routes: /health, /ready, /setup, /login, /logout,
                    /settings, /settings/site, /settings/password, /inventory
                    Full DB-backed auth (PBKDF2 + itsdangerous sessions, 8h TTL)
                    SETUP_REQUIRED persisted to pelico_config table
  Dockerfile        Runs as UID 1000; python:3.12-slim base
  requirements.txt  Pinned deps (fastapi, uvicorn, psycopg2-binary, pydantic,
                    itsdangerous, jinja2)
  templates/        setup.html, login.html, inventory.html, settings.html
  static/style.css  Dark navy (#0b1221) + orange (#f05a28) design system

charts/crate/       Helm chart — deploys the full appliance stack
  Chart.yaml        No external dependencies; postgres + minio are inline
  values.yaml       Production defaults (passwords intentionally blank)
  values-local.yaml Docker Desktop overrides (small resources, dev passwords)
  values-appliance.yaml  Appliance overrides; __APP_REPOSITORY__/__APP_TAG__
                         placeholders substituted by packer/scripts/03-app.sh
  templates/
    _helpers.tpl            Named templates (fullname, labels, etc.)
    deployment.yaml         App deployment with init container (waits for PG)
    service.yaml            ClusterIP service
    ingress.yaml            nginx-class ingress (crate / crate.local)
    configmap.yaml          Non-secret env vars (host, db name, log level)
    secret.yaml             Passwords + SECRET_KEY
    serviceaccount.yaml     Dedicated SA, automountServiceAccountToken=false
    postgresql.yaml         Inline PostgreSQL 17-alpine StatefulSet
    minio.yaml              Inline MinIO StatefulSet

packer/
  crate.pkr.hcl    All builders: vmware-iso, vsphere-iso, virtualbox-iso,
                    hyperv-iso, qemu (outputs QCOW2), amazon-ebs, azure-arm,
                    googlecompute. QEMU is the CI target.
  variables.pkr.hcl HCL2 variable declarations; includes app_image, app_version
  http/
    user-data       Ubuntu 24.04 autoinstall (subiquity); user crate,
                    NOPASSWD sudo, avahi/mDNS packages, cloud-init disabled
    meta-data       instance-id + local-hostname for autoinstall
  scripts/
    01-base.sh      apt upgrade, hostname crate, Avahi config (crate.local),
                    UFW (22/80/443/5353/udp), sysctl for k3s, disable snapd
    02-k3s.sh       k3s (Traefik disabled), Helm v3, nginx ingress
                    (hostNetwork DaemonSet, ClusterIP svc), pre-pull all images
    03-app.sh       cp charts → /opt/crate/chart; sed-substitute
                    __APP_REPOSITORY__ and __APP_TAG__ in values-appliance.yaml
    04-network.sh   Netplan (DHCP), crate-update-host.service, enable Avahi
    05-firstrun.sh  Install crate-firstrun.service (one-shot systemd unit:
                    generates passwords → helm install → never runs again)
                    ConditionPathExists=!/etc/crate/passwords.env
    99-cleanup.sh   Zero free space, remove SSH host keys, truncate machine-id,
                    lock crate passwd, clear logs
    create-ova.sh   QCOW2 → streamOptimized VMDK → OVF + .mf manifest → TAR OVA

.github/workflows/
  build-appliance.yml   Job 1: docker buildx → ghcr.io/txdmc/crate:<ver>
                        Job 2: KVM Packer QEMU build → OVA + VHDX + QCOW2
                               xz-compressed → SHA256SUMS → GitHub Release
  version-bump.yml      On PR merge to main: inspect commits for conventional
                        commit prefixes to determine semver bump (major/minor/patch),
                        write VERSION, commit [skip ci], dispatch build-appliance

VERSION             Plain semver file (e.g. 0.1.0); source of truth for releases
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
- `SETUP_REQUIRED` is persisted to the `pelico_config` PostgreSQL table and
  survives pod restarts. It is set to `false` when the setup wizard is completed.

### Helm chart
- Passwords are required values with no defaults — Helm will error if unset.
  This is intentional; never hard-code passwords in `values.yaml`.
- `values-local.yaml` is the only place dev/insecure passwords are allowed.
- `values-appliance.yaml` is for the packaged VM. Placeholders `__APP_REPOSITORY__`
  and `__APP_TAG__` are substituted by `packer/scripts/03-app.sh` at build time.
  Passwords are injected at first boot by `crate-firstrun.service` via `--set`.
- Pod `securityContext` runs as UID 1000 (`crate` user). The Dockerfile
  creates that user to match.
- PostgreSQL and MinIO use inline templates (no bitnami dependency). Do not
  re-add bitnami as a subchart.

### Packer
- HCL2 format only (legacy JSON `template.json` is a stub — ignore it).
- **CI target is `qemu.crate_qemu`** — outputs QCOW2. GitHub Actions runner
  (`ubuntu-24.04`) has `/dev/kvm`; no nested virtualisation needed.
- CI then converts: QCOW2 → OVA (`create-ova.sh`) and QCOW2 → VHDX (`qemu-img`).
- Builders that need a local hypervisor (vmware, virtualbox, hyperv) only run
  when that hypervisor is present on the build machine.
- Cloud builders (aws, azure, gcp) need credentials in the environment.
- All ISO-based builders share `local.iso_boot_command` and `local.provision_scripts`.
- `APP_IMAGE` and `APP_VERSION` env vars are passed to provisioner scripts;
  set via `PKR_VAR_app_image` / `PKR_VAR_app_version` in CI.

### Versioning
- `VERSION` file at repo root is the single source of truth (plain `MAJOR.MINOR.PATCH`).
- On every PR merge to `main`, `.github/workflows/version-bump.yml` analyzes the
  PR's commit messages using **Conventional Commits** to determine the bump:
  - Any commit with `BREAKING CHANGE` in footer or `!` after type → **major**
  - Any `feat:` commit → **minor**
  - `fix:`, `chore:`, `docs:`, etc. → **patch**
- The workflow commits the new `VERSION` to main with `[skip ci]`, then
  dispatches `build-appliance.yml` with the new version string.
- The build workflow tags the container image and names all release artifacts
  using that version.

---

## What Is Complete

- [x] FastAPI application with health probes, full DB-backed auth, session cookies
- [x] Setup wizard, login, logout, settings (site name + password change) routes
- [x] Inventory CRUD with PostgreSQL persistence
- [x] Dark UI (setup, login, inventory, settings templates + style.css)
- [x] Dockerfile (python:3.12-slim, non-root UID 1000)
- [x] Full Helm chart (inline postgres + minio — no bitnami)
- [x] `values-local.yaml` for Docker Desktop
- [x] `values-appliance.yaml` for packaged VM
- [x] `Makefile` with `dev-deps`, `dev-up`, `dev-down`, `dev-logs`, `dev-testdata`, etc.
- [x] Packer HCL2 template covering all 8 platforms
- [x] Packer provisioning scripts (01–05 + 99 + create-ova.sh)
- [x] Ubuntu 24.04 autoinstall seed (`packer/http/user-data` + `meta-data`)
- [x] mDNS via Avahi (`pelico.local` resolves on LAN without DNS config)
- [x] First-boot systemd service (`pelico-firstrun.service`) — generates unique
      passwords, deploys Helm chart, runs exactly once
- [x] CI pipeline: `build-appliance.yml` builds app image + QEMU appliance,
      produces OVA / VHDX / QCOW2, uploads to GitHub Release
- [x] Automated semver version bumping on PR merge (`version-bump.yml`)
- [x] `VERSION` file as source of truth

## What Still Needs Work

- [ ] First-run wizard UI (currently a functional JSON/HTML form; needs richer UX)
- [ ] License management (validation, activation)
- [ ] TLS (cert-manager or self-signed, configurable via values)
- [ ] mDNS on Windows guests (Hyper-V VMs need Bonjour or similar for `.local`)

---

## Local Dev Quick Reference

```bash
# One-time setup
make dev-deps        # install ingress-nginx into Docker Desktop k8s
make hosts           # add 127.0.0.1 crate to /etc/hosts

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
| `POSTGRES_DB` | ConfigMap | default `crate` |
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
  disabled and replaced with nginx ingress (hostNetwork DaemonSet) for
  ecosystem consistency. nginx must listen on port 80 of the host interface.
- **PostgreSQL and MinIO use inline Helm templates** (not bitnami subcharts).
  Bitnami was removed due to image compatibility issues. Do not re-add it.
- **First-boot password generation**: `pelico-firstrun.service` runs once
  (guarded by `ConditionPathExists=!/etc/pelico/passwords.env`), generates
  random secrets with `openssl rand`, writes them to `/etc/pelico/passwords.env`
  (mode 600), then calls `helm upgrade --install` passing secrets via `--set`.
  This ensures every appliance instance has unique credentials.
- **All eight Packer builders share one provisioning script set.** The CI
  target is `qemu.pelico_qemu` (QCOW2 output). GitHub Actions converts it to
  OVA and VHDX after the build without re-running Packer.
- **Container images are pre-pulled** into k3s containerd during the Packer
  build (`02-k3s.sh`) so the appliance works fully air-gapped after first boot.
- **No Kubernetes namespaced RBAC is needed yet** — the ServiceAccount has
  `automountServiceAccountToken: false` and no ClusterRole bindings. Add only
  when a specific feature requires API access.
