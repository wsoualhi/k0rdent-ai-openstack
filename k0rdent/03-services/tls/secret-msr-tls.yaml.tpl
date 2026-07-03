# TEMPLATE — the TLS Secret for MSR, applied to the CHILD cluster in the `msr` namespace.
# Prefer the imperative `kubectl create secret tls` in NOTES.md; this file is for a GitOps-style apply.
# Rendered file (secret-msr-tls.yaml) is gitignored.
#
# Fill with base64 of the CA-signed cert chain and your private key:
#   tls.crt = base64 -w0 msr.crt     (leaf + intermediates)
#   tls.key = base64 -w0 msr.key
apiVersion: v1
kind: Secret
metadata:
  name: msr-tls
  namespace: msr
type: kubernetes.io/tls
data:
  tls.crt: <BASE64_MSR_CRT_CHAIN>
  tls.key: <BASE64_MSR_KEY>
