# k0rdent Enterprise on OpenStack

Deploy a Kubernetes platform on OpenStack in **two phases**:

| Phase | Goal | Tooling | Documentation |
|-------|------|---------|---------------|
| **Phase 1** | Provision OpenStack infrastructure + a base Kubernetes cluster (k0s or MKE4K) | Terraform + `xctl.py` (imperative) | **this README** (below) |
| **Phase 2** | Turn the cluster into a **k0rdent Enterprise** management cluster, provision **child clusters**, and deploy the **MSR service stack** (Mirantis Secure Registry + Traefik + TLS) | `helm` + `kubectl` (declarative) | [`k0rdent/README.md`](k0rdent/README.md) |

**Phase 1** gets you a healthy k8s cluster on OpenStack with CCM/CSI — the foundation.
**Phase 2** builds on that cluster; it does **not** use `xctl.py` or any wrapper, and its
environment-specific values live in a private, gitignored `k0rdent/environment.local.md`.

> Start with Phase 1 below. Once `kubectl get nodes` is all `Ready`, continue to
> [Phase 2 → `k0rdent/README.md`](k0rdent/README.md).

---

# Phase 1 — Infrastructure & Base Cluster (MKE4K / k0s)

A deployment tool for managing Kubernetes clusters (MKE4K and k0s) on OpenStack infrastructure using Terraform and automated scripts.

##  Overview

This project provides a complete solution for deploying and managing Kubernetes clusters on OpenStack:

- **MKE4K** - Enterprise-grade Kubernetes distribution
- **k0s** - Zero-friction Kubernetes distribution
- **OpenStack Integration** - Full cloud provider integration with CCM and CSI
- **Automated Deployment** - Single-command deployment with comprehensive logging

##  Prerequisites

### Required Tools
- **uv** (Python package manager) - [install](https://docs.astral.sh/uv/)
- **Terraform** >= 1.0
- **kubectl** - [install](https://kubernetes.io/docs/tasks/tools/)
- **k0sctl** (k0s clusters only — auto-installed if missing)
- **mkectl** >= 4.1.1 (MKE4K clusters only — auto-installed if missing)
- **Helm** >= 3 (MKE4K clusters only, for CCM/CSI) - [install](https://helm.sh/docs/intro/install/)
- **OpenStack CLI** (optional, for manual operations)

### OpenStack Requirements
- OpenStack project with sufficient quotas + user credentials (openstack.rc)
- Network access to OpenStack API endpoints

##  Quick Start

### 0. Install dependencies

Create the virtual environment and install the Python dependencies:

```bash
uv sync
```

(`uv run` also syncs automatically, so this step is optional but recommended.)

### 1. Environment Setup

Copy the example `.env` file and fill in your OpenStack credentials:

```bash
cp .env.example .env
# Edit .env with your OpenStack credentials and password
```

The `.env` file is automatically loaded by `xctl.py` (via python-dotenv) — no need to manually source any openrc file.

### 2. Configuration

Copy the example tfvars file (it is gitignored and won't exist on a fresh clone), then edit it to configure your deployment:

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars for your environment
```

Key settings in `terraform.tfvars`:

```bash
# Cluster Configuration
cluster_type = "k0s"  # mke4k or k0s
resource_prefix = "your initials" # Prefix for all resource names, use your initials so the OpenStack admin can track resources
cluster_name = "k0s"              # Name of the k8s cluster 

# OpenStack Configuration
openstack_auth_url = "https://your-keystone-url"

# Infrastructure Configuration
controller_count = 3
worker_count = 3 # use 0 if you need a minimala k0rdent setup
control_plane_flavor = "m1.xlarge"
worker_flavor = "m1.xlarge"
image_name = "ubuntu-22.04"
```

### 3. Deploy all / Destroy all - fully automated

| Command | Description |
|---------|-------------|
| `uv run xctl.py deploy_all` | Complete deployment: checks → infra → cluster → CCM/CSI → cleanup |
| `uv run xctl.py destroy_all` | Complete destruction of all resources |

```bash
# One command to deploy all the infra, the kubernetes, the ccm and to display the access 
uv run xctl.py deploy_all

# One command to destroy all and remove all the created manifests, logs, artifacts...
uv run xctl.py destroy_all
```

## 🛠️ Optional if you want to deploy step by step

### Step-by-Step Functions

| Command | Description |
|---------|-------------|
| `uv run xctl.py check_prerequisites` | Run pre-deployment checks |
| `uv run xctl.py deploy_infra` | Deploy OpenStack infrastructure |
| `uv run xctl.py deploy_k8s` | Deploy k0s or MKE4K cluster |
| `uv run xctl.py setup_kubeconfig` | Generate kubeconfig file |
| `uv run xctl.py deploy_ccm` | Deploy OpenStack CCM and CSI |
| `uv run xctl.py remove_floating_ips` | Remove floating IPs from OpenStack |
| `uv run xctl.py verify_cluster` | Verify cluster deployment |

### Utility Functions

| Command | Description |
|---------|-------------|
| `uv run xctl.py remove_from_known_hosts` | Clean SSH known_hosts entries |
| `uv run xctl.py cluster_access` | Display cluster access credentials |
| `uv run xctl.py extract_openstack_ca_cert` | Extracts CA certificate from OpenStack |

## 📊 Deployment Process

### Complete Deployment Flow (`deploy_all`)

1. **Pre-flight Checks** - Verify tools, credentials, and infrastructure status
2. **Infrastructure Deployment** - Create OpenStack resources (networks, instances, etc.)
3. **Cluster Deployment** - Deploy k0s or MKE4K using generated configuration
4. **Kubeconfig Setup** - Generate and configure cluster access
5. **Cluster Verification** - Verify nodes and basic functionality
6. **CCM/CSI Deployment** - Install OpenStack Cloud Controller Manager and CSI
7. **Floating IP Cleanup** - Remove floating IPs to reduce costs
8. **Access Summary** - Display all access credentials and URLs

### Cluster Types

#### MKE4K Deployment
- Uses `mkectl` for deployment
- Generates admin credentials automatically
- Provides web UI, Grafana, MinIO, and Dex
- Logs saved to `mkectl.logs`

#### k0s Deployment
- Uses `k0sctl` for deployment
- Standard Kubernetes distribution
- Logs saved to `k0sctl.logs`

## 🔐 Access Credentials

### MKE4K Access Details - will be displayed after the end of the deployment

After successful deployment, you'll get access to:

- **Admin Portal**: `https://<load-balancer-ip>`
  - Username: `admin`
  - Password: Auto-generated

- **Grafana Dashboard**: `https://<load-balancer-ip>/grafana/`
  - Credentials extracted from Kubernetes secrets

- **MinIO Storage**: `https://<load-balancer-ip>/minio/`
  - Credentials extracted from Kubernetes secrets

- **Dex Authentication**: `https://<load-balancer-ip>/dex`
  - Configure with external identity provider

### k0s Access

- **Kubeconfig**: `./kubeconfigs/management`
- **API Endpoint**: `https://<load-balancer-ip>:6443`

## 📁 Generated Files

| File | Description |
|------|-------------|
| `kubeconfigs/management` | Cluster access configuration |
| `mkectl.logs` | MKE4K deployment logs |
| `k0sctl.logs` | k0s deployment logs |
| `ssh-key` | Private SSH key for node access |
| `ssh-key.pub` | Public SSH key injected into instances |
| `terraform.tfstate` | Terraform state file |

##  OpenStack Integration

### Cloud Controller Manager (CCM)
- Automatically configures node addresses
- Manages load balancers
- Handles node lifecycle events

### Container Storage Interface (CSI)
- Provides block storage via OpenStack Cinder
- Supports volume provisioning and attachment
- Enables persistent volume claims

### Network Configuration
- Creates private network with router
- Configures security groups
- Sets up floating IPs for external access

### Log Files

- **MKE4K**: Check `mkectl.logs` for deployment issues
- **k0s**: Check `k0sctl.logs` for deployment issues
- **Terraform**: Use `terraform plan` and `terraform apply` for infrastructure issues

##  Cleanup

### Complete Cleanup
```bash
uv run xctl.py destroy_all
```

This will:
- Destroy all OpenStack resources
- Remove all generated files
- Clean up logs and configurations

### Partial Cleanup
```bash
# Remove only floating IPs
uv run xctl.py remove_floating_ips

# Clean SSH known_hosts
uv run xctl.py remove_from_known_hosts
```

## Architecture Diagrams

### High Availability Setup for mke4k
```
                        ┌───────────────────┐
                        │  Load Balancer    │
                        │  (Octavia LB)     │
                        │                   │
                        │ Ports: 6443       │
                        │        443 (nginx)│
                        │        9443       │
                        └───────────────────┘
                                 │
            ┌────────────────────┼────────────────────┐
            │                    │                    │
   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
   │  Controller 1    │ │  Controller 2    │ │  Controller 3    │
   │                  │ │                  │ │                  │
   │ - k0s controller │ │ - k0s controller │ │ - k0s controller │
   └──────────────────┘ └──────────────────┘ └──────────────────┘
            │                    │                    │
            └────────────────────┼────────────────────┘
                                 │
                       ┌──────────────────┐
                       │  Cluster Network │
                       │ e.g 10.0.1.0/24  │
                       └──────────────────┘
                                 │
        ┌─────────────────┐      │      ┌─────────────────┐
        │    Worker 1     │──────┼──────│    Worker 2     │
        │                 │      │      │                 │
        │ - k0s worker    │      │      │ - k0s worker    │
        └─────────────────┘      │      └─────────────────┘
                                 │
                        ┌─────────────────┐
                        │   Bastion Host  │
                        │    (Ubuntu)     │
                        │   SSH Gateway   │
                        │    (optional)   │
                        └─────────────────┘
```

### High Availability Setup for k0s
```
                        ┌─────────────────┐
                        │  Load Balancer  │
                        │  (Octavia LB)   │
                        │                 │
                        │ Ports: 6443     │
                        │        8132     │
                        │        9443     │
                        └─────────────────┘
                                 │
            ┌────────────────────┼────────────────────┐
            │                    │                    │
   ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
   │  Controller 1    │ │  Controller 2    │ │  Controller 3    │
   │                  │ │                  │ │                  │
   │ - k0s controller │ │ - k0s controller │ │ - k0s controller │
   └──────────────────┘ └──────────────────┘ └──────────────────┘
            │                    │                    │
            └────────────────────┼────────────────────┘
                                 │
                       ┌──────────────────┐
                       │  Cluster Network │
                       │ e.g 10.0.1.0/24  │
                       └──────────────────┘
                                 │
        ┌─────────────────┐      │      ┌─────────────────┐
        │    Worker 1     │──────┼──────│    Worker 2     │
        │                 │      │      │                 │
        │ - k0s worker    │      │      │ - k0s worker    │
        └─────────────────┘      │      └─────────────────┘
                                 │
                        ┌─────────────────┐
                        │   Bastion Host  │
                        │    (Ubuntu)     │
                        │   SSH Gateway   │
                        │    (optional)   │
                        └─────────────────┘
```

## ➡️ Next: Phase 2 — k0rdent Enterprise

Once Phase 1 is complete and `kubectl get nodes` shows all nodes `Ready`, continue to
**[`k0rdent/README.md`](k0rdent/README.md)** to:

1. Install **k0rdent Enterprise** (KCM) on this cluster — the management cluster
2. Configure OpenStack **credentials** so k0rdent can provision **child clusters**
3. Provision a **child cluster** on OpenStack
4. Deploy the **MSR service stack** (cert-manager → Traefik → MSR) onto the child

> Tip: for a minimal k0rdent management cluster, set `worker_count = 0` in `terraform.tfvars`
> (controllers are schedulable).

## Support & Documentation

- **k0rdent Enterprise**: [k0rdent Enterprise documentation](https://docs.mirantis.com/k0rdent-enterprise/latest/)
- **k0s**: [k0s documentation](https://docs.k0sproject.io/)
- **MKE4k**: [MKE4k documentation](https://docs.mirantis.com/mke/4.0/)
- **k0sctl**: [k0sctl repository](https://github.com/k0sproject/k0sctl)
- **OpenStack CCM**: [cloud-provider-openstack](https://github.com/kubernetes/cloud-provider-openstack)
- **Terraform OpenStack**: [terraform-provider-openstack](https://registry.terraform.io/providers/terraform-provider-openstack/openstack)

---

**Note**: This tool is designed for development and testing environments. For production use, ensure proper security hardening and backup procedures are in place.
