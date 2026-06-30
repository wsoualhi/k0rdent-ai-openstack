---
apiVersion: mke.mirantis.com/v1alpha1
kind: MkeConfig
metadata:
  creationTimestamp: null
  name: ${cluster_name}
  namespace: mke
spec:
  airgap:
    enabled: false
  apiServer:
    audit:
      enabled: false
      level: Metadata
      logPath: /var/log/k0s/audit/mke4_audit.log
      maxAge: 30
      maxBackup: 10
      maxSize: 10
      policyFile: /var/lib/k0s/mke4_audit_policy.yaml
    encryptionProvider: /var/lib/k0s/encryption.cfg
    eventRateLimit:
      enabled: false
    externalAddress: ${external_address != "" ? external_address : external_floating_ip}
    requestTimeout: 1m0s
  authentication:
    replicaCount: 2
    expiry: {}
    ldap:
      enabled: false
    oidc:
      enabled: ${ oidc_enabled }
      %{ if oidc_enabled }
      issuer: ${ oidc_issuer_url }
      clientID: ${ oidc_client_id }
      %{ if oidc_client_secret_id != "" }
      clientSecret: ${ oidc_client_secret_id }
      %{ endif }
      %{~ endif }
    saml:
      enabled: false
  cloudProvider:
    enabled: false
  controllerManager:
    terminatedPodGCThreshold: 12500
  devicePlugins:
    nvidiaGPU:
      enabled: false
      mig: {}
  dns:
    lameduck: {}
  envoyGateway:
    replicaCount: 2
    tolerations:
    - effect: NoSchedule
      key: node-role.kubernetes.io/master
      operator: Exists
      value: ""
  etcd: {}
  gatewayMKEIngress:
    nodePorts:
      http: 33000
      https: 33001
    ports:
      http: 80
      https: 443
  hosts:
%{ for i, controller_private_ip in controller_private_ips ~}
  - ssh:
%{ if length(controller_fips) > 0 ~}
      address: ${controller_fips[i]}
%{ else ~}
      address: ${controller_private_ip}
%{ if bastion_enabled ~}
      bastion:
        address: ${bastion_ip}
        user: ${bastion_user}
        port: 22
        keyPath: ${ssh_key_path}
%{ endif ~}
%{ endif ~}
      user: ubuntu
      port: 22
      keyPath: ${ssh_key_path}
    role: controller+worker
    privateInterface: eth0
    privateAddress: ${controller_private_ip}
    hostname: ${cluster_name}-controller-${i + 1}
%{ if length(worker_private_ips) == 0 ~}
    noTaints: true
%{ endif ~}
    installFlags:
      - --debug
%{ endfor ~}
%{ for i, worker_private_ip in worker_private_ips ~}
  - ssh:
%{ if length(worker_fips) > 0 ~}
      address: ${worker_fips[i]}
%{ else ~}
      address: ${worker_private_ip}
%{ if bastion_enabled ~}
      bastion:
        address: ${bastion_ip}
        user: ${bastion_user}
        port: 22
        keyPath: ${ssh_key_path}
%{ endif ~}
%{ endif ~}
      user: ubuntu
      port: 22
      keyPath: ${ssh_key_path}
    role: worker
    privateInterface: eth0
    privateAddress: ${worker_private_ip}
    hostname: ${cluster_name}-worker-${i + 1}
    installFlags:
      - --debug
%{ endfor ~}
  ingressController:
    affinity:
      nodeAffinity: {}
    enabled: false
    extraArgs:
      enableSslPassthrough: false
    nodePorts: {}
    ports: {}
  kubelet:
    eventRecordQPS: 50
    kubeletRootDir: /var/lib/kubelet
    managerKubeReserved:
      cpu: 250m
      ephemeral-storage: 4Gi
      memory: 2Gi
    maxPods: 110
    podPidsLimit: -1
    podsPerCore: 0
    protectKernelDefaults: false
    seccompDefault: false
    workerKubeReserved:
      cpu: 50m
      ephemeral-storage: 500Mi
      memory: 300Mi
  license:
    token: ""
  monitoring:
    enableCAdvisor: false
    grafana:
      ingress: {}
    prometheus: {}
  network:
    kubeProxy:
      iptables:
        minSyncPeriod: 0s
        syncPeriod: 0s
      ipvs:
        minSyncPeriod: 0s
        syncPeriod: 0s
        tcpFinTimeout: 0s
        tcpTimeout: 0s
        udpTimeout: 0s
      metricsBindAddress: 0.0.0.0:10249
      mode: iptables
      nftables:
        minSyncPeriod: 0s
        syncPeriod: 0s
    multus:
      enabled: false
    nodePortRange: 32768-35535
    providers:
    - enabled: true
      extraConfig:
        cidrV4: 192.168.0.0/16
        linuxDataplane: Iptables
        loglevel: Info
      provider: calico
    - enabled: false
      provider: custom
    - enabled: false
      extraConfig:
        cidrV4: 192.168.0.0/16
        v: "5"
      provider: kuberouter
    serviceCIDR: 10.96.0.0/16
  nodeLocalDNS:
    enabled: false
    nodeLocalConfigPersist: false
    resources:
      requests: {}
  policyController:
    opaGatekeeper:
      enabled: false
  registries:
    chartRegistry:
      url: oci://registry.mirantis.com/mke
    imageRegistry:
      url: registry.mirantis.com/mke
  scheduler: {}
  tracking:
    enabled: true
  version: v4.1.3