# CLAUDE.md - Project Guide

## Project Overview

Deployment tool for Kubernetes clusters (MKE4K or k0s) on OpenStack infrastructure. Single entry point `xctl.py` (Python) orchestrates Terraform provisioning + cluster deployment + post-install configuration (CCM/CSI).

## Tooling

- **Python 3.12+** managed via **uv** (package manager + venv)
- Virtual environment: `.venv/` (created by `uv sync`)
- Dependencies in `pyproject.toml`, locked in `uv.lock`
- Only runtime dependency: `python-dotenv`
- Run commands: `uv run xctl.py <command>`

## Architecture

```
.env              → OpenStack credentials (auto-loaded by xctl.py via python-dotenv)
terraform.tfvars  → Terraform (main.tf) → OpenStack resources
                                         → Generated configs (k0sctl.yaml / mkectl.yaml)
                                         → SSH keys
                                         ↓
xctl.py → k0sctl apply / mkectl apply   → Kubernetes cluster
        → Helm install CCM/CSI          → OpenStack cloud integration
        → kubeconfig generation          → Cluster access
```

Two cluster types: `mke4k` (Mirantis enterprise K8s) and `k0s` (lightweight K8s). Selected via `cluster_type` in `terraform.tfvars`.

## Key Files

| File | Purpose |
|------|---------|
| `xctl.py` | Main orchestration script (Python) — all deploy/destroy/utility commands |
| `pyproject.toml` | Python project config (dependencies, scripts entry point) |
| `.env` | OpenStack credentials (gitignored, auto-loaded) |
| `.env.example` | Template for `.env` (safe to commit) |
| `main.tf` | Terraform config: networking, security groups, instances, LB, SSH keys |
| `variables.tf` | All Terraform variable definitions with validation |
| `outputs.tf` | Terraform outputs (IPs, paths, credentials) |
| `terraform.tfvars` | User configuration (cluster type, counts, flavors, network) |
| `artifacts/k0sctl.yaml.tpl` | k0s cluster config template (includes Helm charts for CCM/CSI) |
| `artifacts/mkectl.yaml.tpl` | MKE4K cluster config template |
| `artifacts/cloud-init.yaml.tpl` | Node initialization template |
| `artifacts/secret-openstack-cloud-config.yaml.tpl` | CCM/CSI credentials secret template |
| `artifacts/values-openstack-ccm.yaml` | Helm values for OpenStack CCM |
| `artifacts/values-openstack-csi.yaml` | Helm values for OpenStack Cinder CSI |
| `manifests/` | Generated Kubernetes manifests (gitignored) |

## Generated Files (gitignored)

`kubeconfig`, `ssh-key`, `ssh-key.pub`, `k0sctl.yaml`, `mkectl.yaml`, `*.logs`, `terraform.tfstate`, `terraform.tfvars`, `manifests/secret-*.yaml`, `.venv/`

`uv.lock` and `.terraform.lock.hcl` are intentionally committed (reproducible installs + pinned provider versions). Copy `terraform.tfvars.example` → `terraform.tfvars` to configure.

## Resource Naming Convention

`${resource_prefix}-${cluster_name}-${resource_type}` (e.g., `ws-mke-controller-1`)

## xctl.py Commands

| Command | What it does |
|---------|-------------|
| `deploy_all` | Full pipeline: checks → infra → cluster → kubeconfig → verify → CCM/CSI → cleanup IPs → show access |
| `destroy_all` | Terraform destroy + remove all generated files |
| `check_prerequisites` | Validates tools (terraform, k0sctl/mkectl), OpenStack credentials, infra state |
| `deploy_infra` | `terraform init/plan/apply` |
| `deploy_k8s` | Runs `k0sctl apply` or `mkectl apply` based on cluster_type |
| `setup_kubeconfig` | Generates kubeconfig (different logic per cluster type) |
| `deploy_ccm` | Deploys OpenStack CCM + Cinder CSI via Helm (MKE4K only, k0s uses embedded Helm) |
| `verify_cluster` | kubectl checks for node readiness |
| `remove_floating_ips` | Terraform-targeted removal of floating IPs post-deploy |
| `cluster_access` | Displays MKE4K admin/Grafana/MinIO credentials |

## Terraform Infrastructure

- **Networking**: Private network + subnet (10.0.1.0/24), router to external network, optional existing network reuse
- **Security groups**: k8s_secgroup (API 6443, SSH 22, Konnectivity 8132, NodePort 30000-32767, Cilium 8472, etcd 2379-2380) + bastion_secgroup
- **Compute**: Controllers (1-3), Workers (0-10), optional Bastion host. Boot from volume (Cinder)
- **Load Balancer**: Octavia LB with listeners for API (6443), Konnectivity (8132, k0s only), Ingress (443→33001, MKE4K only), Join API (9443)
- **Floating IPs**: Optional per node type + LB. Removed post-deployment to reduce costs
- **SSH**: RSA 4096 key pair auto-generated via TLS provider

## Development Notes

- Terraform >= 1.0 required, uses OpenStack + TLS + Local providers
- Templates use `templatefile()` with conditional blocks for cluster type differentiation
- k0s CCM/CSI deployed via embedded Helm charts in k0sctl.yaml; MKE4K deploys them separately via xctl.py
- OpenStack application credentials (not user credentials) used for CCM/CSI
- Custom CA support for OpenStack endpoints with self-signed certificates
- Calico CNI with VXLAN mode, MTU 1450 (OpenStack encapsulation overhead)
- Future plan: convert xctl.py to an MCP server (each command becomes an MCP tool)

## Common Commands

```bash
# First time setup
cp .env.example .env                       # Then edit .env with your credentials
cp terraform.tfvars.example terraform.tfvars  # Then edit for your environment
uv sync                                    # Create venv and install dependencies

# Usage
uv run xctl.py deploy_all      # Full deployment
uv run xctl.py destroy_all     # Full teardown
uv run xctl.py cluster_access  # Show access credentials (MKE4K)
uv run xctl.py verify_cluster  # Check cluster health
```

## Important Constraints

- Never commit sensitive files: `.env`, `terraform.tfvars`, `ssh-key`, `kubeconfig`, `*.tfstate`, `secret-*.yaml`
- `controller_count` validated: 1-3 only
- `worker_count` validated: 0-10 only
- MKE4K requires mkectl >= v4.1.1
- Load balancer only created when `load_balancer_enabled = true` AND `controller_count > 1`
