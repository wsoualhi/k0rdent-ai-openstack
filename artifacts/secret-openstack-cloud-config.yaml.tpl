---
apiVersion: v1
kind: Secret
metadata:
  name: openstack-cloud-config
  namespace: kube-system
type: Opaque
stringData:
  cloud.conf: |
    [Global]
    auth-url="${openstack_config.auth_url}"
    application-credential-id="${openstack_config.application_credential_id}"
    application-credential-secret="${openstack_config.application_credential_secret}"
    region="${openstack_config.region}"
%{ if openstack_config.insecure ~}
    tls-insecure="${openstack_config.insecure}"
%{ endif ~}
%{ if openstack_config.custom_ca ~}
    ca-file="/etc/ssl/certs/ca.crt"
%{ endif ~}

    [LoadBalancer]
    floating-network-id="${openstack_config.floating_network_id}"
    subnet-id="${openstack_config.subnet_id}"
    create-monitor=true
    [Networking]
    public-network-name="${openstack_config.network_id}"