# k0rdent Enterprise on OpenStack — Phase 2 Deployment

> **Phase 1** (Terraform infra + k0s via `xctl.py`) is documented in the root [`README.md`](../README.md).
> This is **Phase 2**: turning the k0s cluster into a **k0rdent Enterprise management cluster**,
> then using it to provision **child clusters** on OpenStack and deploy the **MSR service stack**
> (Mirantis Secure Registry + Traefik + TLS) onto them.
>
> Phase 2 is **declarative** — `kubectl apply` of manifests + a single `helm install` for the manager.
> It does **not** use `xctl.py`, `make`, or any wrapper.
>
> **All values live in the repo-root `.env`** (gitignored). Every manifest is committed with `${VAR}`
> placeholders and rendered at apply time with `envsubst` — you only ever edit `.env`, never a manifest.

---

## 1. Overview

```
                       ┌────────────────────────────────────────────────┐
                       │  MANAGEMENT CLUSTER  (this k0s cluster)        │
                       │  - k0rdent Enterprise (KCM) v1.4.0             │
                       │  - Cluster API + OpenStack provider (CAPO)     │
                       │  - OpenStack Credential + templates            │
                       └───────────────┬────────────────────────────────┘
                                       │ provisions (CAPI)
                                       ▼
                       ┌────────────────────────────────────────────────┐
                       │  CHILD CLUSTER  (OpenStack)                    │
                       │  service stack (delivered via k0rdent/Sveltos):│
                       │    cert-manager → Traefik → MSR                │
                       │    Other components as needed                  │
                       └────────────────────────────────────────────────┘
```

| Layer | What | How delivered |
|-------|------|---------------|
| Manager | k0rdent Enterprise (KCM) | `helm install` (the **only** helm step) |
| Credentials | OpenStack `clouds.yaml` + `Credential` + resource template | `kubectl apply` |
| Child cluster | `ClusterDeployment` on OpenStack | `kubectl apply` |
| Services | cert-manager, Traefik, MSR | k0rdent `ServiceTemplate` → `spec.serviceSpec` (Sveltos pushes to child) |
| Glue on child | `IngressRoute`, TLS `Secret` | `kubectl apply` **against child kubeconfig** |

---

## 2. Prerequisites & licensing

- Phase 1 complete — healthy k0s management cluster (`kubectl get nodes` all `Ready`).
- `helm` (OCI support), `kubectl`, and `envsubst` (from `gettext`) installed locally.
- `KUBECONFIG` pointing at the **management** cluster (repo root `./kubeconfigs/management`).
- OpenStack auth available in the repo-root **`.env`** (gitignored) — reused to create the provider
  credentials. Username/password by default; an application credential is supported as hardening.
- Request licensing from Mirantis if you would like to run k0rdent Enterprise, otherwise use k0rdent OSS.

---

## 3. Install k0rdent Enterprise

```bash
set -a; source ../.env; set +a            # KCM_VERSION, MIRANTIS_* from .env
export KUBECONFIG=../kubeconfigs/management   # management cluster

# only if registry.mirantis.com requires auth:
# kubectl create ns kcm-system
# kubectl create secret docker-registry mirantis-registry \
#   --docker-server=registry.mirantis.com \
#   --docker-username="$MIRANTIS_REGISTRY_USER" --docker-password="$MIRANTIS_REGISTRY_TOKEN" \
#   -n kcm-system

helm install kcm oci://registry.mirantis.com/k0rdent-enterprise/charts/k0rdent-enterprise \
  --version "$KCM_VERSION" \
  -n kcm-system --create-namespace \
  --set kordent-ui.enabled=true
```

**Verify** the manager is Ready:
```bash
kubectl get management.k0rdent kcm            # STATUS should become Ready
kubectl -n kcm-system get pods
kubectl get clustertemplate -n kcm-system     # note the OpenStack template version for Step 3
```
### Reference
- Install:  https://docs.mirantis.com/k0rdent-enterprise/latest/admin/installation/install-k0rdent/
- Verify:   https://docs.mirantis.com/k0rdent-enterprise/latest/admin/installation/verify-install/
- Airgap:   https://docs.mirantis.com/k0rdent-enterprise/latest/admin/installation/airgap/

---

## 4. OpenStack credentials  → [`01-credentials/`](01-credentials/)

Three objects in `kcm-system`, all committed with `${OS_*}` placeholders and rendered from the
repo-root **`.env`**. Render each into the gitignored **`rendered/`** folder first so you can
inspect it, then apply — the rendered secret holds the real password, so `rendered/` is never committed.

1. Secret `openstack-cloud-config` — `clouds.yaml`, filled from `.env` (needs `envsubst`)
2. `Credential` → `identityRef` → the Secret
3. ConfigMap `openstack-cloud-config-resource-template` — Go template (do **not** envsubst)

```bash
# from the k0rdent/ directory; .env lives one level up (repo root) and stays gitignored
set -a; source ../.env; set +a
mkdir -p rendered

# ONLY the secret has ${OS_*} vars → render to file, inspect, then apply:
envsubst < 01-credentials/openstack-clouds-secret.yaml > rendered/openstack-clouds-secret.yaml
kubectl apply -f rendered/openstack-clouds-secret.yaml
kubectl get secret openstack-cloud-config -n kcm-system      # verify

# The other two have no ${} vars → apply directly.
# Never run envsubst on the resource-template: its Go $vars would be erased.
kubectl apply -f 01-credentials/openstack-credential.yaml
kubectl apply -f 01-credentials/openstack-resource-template.yaml

# Verify the Credential is ready:
kubectl -n kcm-system get credential.k0rdent.mirantis.com openstack-cluster-identity-cred
# READY should be true
```

---

## 5. Provision child cluster  → [`02-child-cluster/`](02-child-cluster/)

```bash
export CHILD_CLUSTER_NAME="k0rdent-child-tooling"
export OPENSTACK_CLUSTER_TEMPLATE="openstack-standalone-cp-1-0-37"   # confirm: kubectl get clustertemplate -n kcm-system
export CHILD_IMAGE_NAME="Ubuntu-24.04"                              # matches Phase-1 terraform.tfvars
export OPENSTACK_EXTERNAL_NETWORK="intranet-highmed-ha"            # Kiel: 'public' is restricted (per tfvars)
export CHILD_CP_FLAVOR="m1.medium"                                 # control plane (etcd+API) — smaller flavor is enough
export CHILD_CP_COUNT="3"                                          # 3 = HA etcd quorum (use 1 for a lean PoC)
export CHILD_WORKER_FLAVOR="m1.large100"                           # workers run MSR / Keycloak / tooling
export CHILD_WORKER_COUNT="2"                                      # 2 large workers cover the tooling with headroom 

set -a; source ../.env; set +a
mkdir -p rendered
kubectl get clustertemplate -n kcm-system     # confirm $OPENSTACK_CLUSTER_TEMPLATE exists

# render to file, inspect, then apply:
envsubst < 02-child-cluster/clusterdeployment.yaml > rendered/clusterdeployment.yaml
kubectl apply -f rendered/clusterdeployment.yaml
```

**Watch provisioning & get kubeconfig:**
```bash
kubectl -n kcm-system get clusterdeployment.k0rdent.mirantis.com --watch
clusterctl describe cluster <name> -n kcm-system --show-conditions all
kubectl -n kcm-system get secret <name>-kubeconfig -o jsonpath='{.data.value}' | base64 -d > ../kubeconfigs/$CHILD_CLUSTER_NAME
```

**Get the child cluster**
```bash
clusterctl get kubeconfig $CHILD_CLUSTER_NAME -n kcm-system > ../kubeconfigs/$CHILD_CLUSTER_NAME
KUBECONFIG=../kubeconfigs/$CHILD_CLUSTER_NAME kubectl get nodes
```

---

## 6. MSR service stack  → [`03-services/`](03-services/)

Order: **cert-manager → (TLS cert from your CA) → Traefik → MSR**.

```bash
set -a; source ../.env; set +a
```

1. Register the ServiceTemplates on the management cluster (they carry `${VAR}` → envsubst).
   Render into `rendered/servicetemplates/`, inspect, then apply:
   ```bash
   mkdir -p rendered/servicetemplates
   for f in 03-services/servicetemplates/*.yaml; do
     envsubst < "$f" > "rendered/servicetemplates/$(basename "$f")"
   done
   kubectl apply -f rendered/servicetemplates/
   ```
2. Attach them to the child via `spec.serviceSpec.services[]` (already referenced in
   `02-child-cluster/clusterdeployment.yaml`).
3. TLS — generate CSR, get it signed, create the Secret on the child: see
   [`03-services/tls/NOTES.md`](03-services/tls/NOTES.md).
4. Apply the child-side glue (IngressRoute) against the child kubeconfig:
   ```bash
   envsubst < 03-services/child-glue/ingressroute-msr.yaml > rendered/ingressroute-msr.yaml
   KUBECONFIG=../kubeconfigs/$CHILD_CLUSTER_NAME kubectl apply -f rendered/ingressroute-msr.yaml
   ```

---

## 7. Verify & access

```bash
KUBECONFIG=../kubeconfigs/$CHILD_CLUSTER_NAME kubectl get pods -A
KUBECONFIG=../kubeconfigs/$CHILD_CLUSTER_NAME kubectl -n <msr-ns> get pods,ingressroute,secret

# test the registry (cert is publicly trusted → no --insecure needed)
docker login <MSR_FQDN>
docker pull hello-world && docker tag hello-world <MSR_FQDN>/test/hello-world && docker push <MSR_FQDN>/test/hello-world
```

---

## 8. Troubleshooting

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| `Management` never Ready | pull-secret/license missing | `kubectl -n kcm-system get pods`, describe failing pods |
| Credential not ready | `identityRef.name` ≠ Secret name; wrong namespace | `kubectl -n kcm-system describe credential …` |
| ClusterDeployment stuck | OpenStack quota / flavor / network / creds | `clusterctl describe cluster <name> -n kcm-system --show-conditions all` |
| Child pods `ImagePullBackOff` | child egress / registry auth | check child node egress + MSR pull-secret |
| Child can't resolve DNS | OpenStack subnet DNS not applied to child | inspect child subnet `dns_nameservers`; set resolvers if needed |
| MSR cert errors | wrong SAN/CN, chain missing | verify `msr-tls` secret cert matches `<MSR_FQDN>` incl. full chain |

---

## 9. Teardown (reverse order)

```bash
# services first (remove from serviceSpec), then child, then manager
kubectl -n kcm-system delete clusterdeployment.k0rdent.mirantis.com <name>
kubectl delete management.k0rdent kcm
helm uninstall kcm -n kcm-system
kubectl delete ns kcm-system
```

---

### Open items tracked in this doc (resolve while building, not blocking structure)
- [ ] Registry pull-secret + license mechanism (Step 1)
- [ ] OpenStack cluster template version (read live after Step 1)
- [ ] MSR + Traefik helm chart coordinates for custom ServiceTemplates (Step 4)
- [ ] Whether cert-manager is a hard MSR dependency (Step 4)
- [ ] Final MSR FQDN + any extra SANs (TLS)
