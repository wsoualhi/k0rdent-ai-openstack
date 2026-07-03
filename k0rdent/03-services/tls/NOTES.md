# MSR TLS — CA-signed public certificate (CSR flow)

No Let's Encrypt, no self-signed CA. We generate a key + CSR, your CA signs it, we load the
returned cert as a `kubernetes.io/tls` Secret on the **child** cluster. Works fully offline.

All values come from the repo-root `.env` (MSR_FQDN, CSR_ORG, …) — do not edit `msr-csr.cnf`.

## 1. Generate key + CSR

```bash
set -a; source ../../.env; set +a          # MSR_FQDN + CSR_* from .env

openssl req -new -newkey rsa:2048 -nodes \
  -keyout msr.key \
  -out msr.csr \
  -config <(envsubst < msr-csr.cnf)

# sanity-check the CSR (CN + SAN)
openssl req -in msr.csr -noout -text | grep -A1 "Subject:\|Subject Alternative Name"
```

- `msr.key` **stays local** (gitignored). Only send `msr.csr` to your CA.

## 2. Send `msr.csr` to your CA → receive `msr.crt` (+ chain)

Ask your CA for the **full chain** (leaf + intermediates). If they send them separately, concatenate:
```bash
cat leaf.crt intermediate.crt > msr.crt
```

## 3. Create the TLS Secret on the CHILD cluster

```bash
set -a; source ../../.env; set +a          # MSR_NAMESPACE from .env
export KUBECONFIG=../../child-kubeconfig

kubectl create namespace "$MSR_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret tls msr-tls --cert=msr.crt --key=msr.key -n "$MSR_NAMESPACE"
```

The Traefik `IngressRoute` in `../child-glue/ingressroute-msr.yaml` references `msr-tls`.
