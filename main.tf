# =============================================================================
# TERRAFORM CONFIGURATION
# =============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.54.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "openstack" {
  # Configuration will be taken from environment variables set by openrc.sh
  # or can be overridden by variables
  auth_url = var.openstack_auth_url != "" ? var.openstack_auth_url : null
  region   = var.openstack_region
}


# =============================================================================
# LOCAL VALUES & DATA SOURCES
# =============================================================================

# Local value to determine the image ID to use
locals {
  image_id = var.image_id != "" ? var.image_id : data.openstack_images_image_v2.ubuntu[0].id
  bastion_image_id = var.bastion_enabled ? (
    var.bastion_image_id != "" ? var.bastion_image_id : data.openstack_images_image_v2.bastion[0].id
  ) : ""
  full_cluster_name = "${var.resource_prefix}-${var.cluster_name}"
  
  # Network and subnet references based on whether we use existing or create new
  network_id = var.use_existing_network ? data.openstack_networking_network_v2.existing_network[0].id : openstack_networking_network_v2.k8s_network[0].id
  subnet_id  = var.use_existing_network ? data.openstack_networking_subnet_v2.existing_subnet[0].id : openstack_networking_subnet_v2.k8s_subnet[0].id
  
  # Auth URL for OpenStack configuration
  auth_url = var.openstack_auth_url
}

# Data sources for existing resources
data "openstack_images_image_v2" "ubuntu" {
  count       = var.image_id == "" ? 1 : 0
  name        = var.image_name
  most_recent = true
}

data "openstack_images_image_v2" "bastion" {
  count       = var.bastion_enabled && var.bastion_image_id == "" ? 1 : 0
  name        = var.bastion_image_name
  most_recent = true
}

data "openstack_compute_flavor_v2" "control_plane" {
  name = var.control_plane_flavor
}

data "openstack_compute_flavor_v2" "worker" {
  name = var.worker_flavor
}

data "openstack_compute_flavor_v2" "bastion" {
  count = var.bastion_enabled ? 1 : 0
  name  = var.bastion_flavor
}

data "openstack_networking_network_v2" "external" {
  name = var.external_network_name
}

# Data source for existing network (when use_existing_network = true)
data "openstack_networking_network_v2" "existing_network" {
  count = var.use_existing_network ? 1 : 0
  name  = var.existing_network_name
}

# Data source for existing subnet (when use_existing_network = true)
data "openstack_networking_subnet_v2" "existing_subnet" {
  count = var.use_existing_network ? 1 : 0
  name  = var.existing_subnet_name
}

# =============================================================================
# SSH KEY GENERATION
# =============================================================================

# Generate SSH key pair
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Save private key to local file
resource "local_file" "private_key" {
  content         = tls_private_key.ssh_key.private_key_pem
  filename        = "${path.cwd}/ssh-key"
  file_permission = "0600"
}

# Save public key to local file
resource "local_file" "public_key" {
  content         = tls_private_key.ssh_key.public_key_openssh
  filename        = "${path.cwd}/ssh-key.pub"
  file_permission = "0644"
}

# Key pair for SSH access
resource "openstack_compute_keypair_v2" "k8s_keypair" {
  name       = "${local.full_cluster_name}-key"
  public_key = tls_private_key.ssh_key.public_key_openssh
}

# =============================================================================
# OPENSTACK IDENTITY & CREDENTIALS
# =============================================================================

# Create application credential for Cloud Controller Manager
resource "openstack_identity_application_credential_v3" "ccm_credential" {
  name        = "${local.full_cluster_name}-ccm"
  description = "Application credential for ${local.full_cluster_name} Cloud Controller Manager"
  
  # Optional: Set expiration (e.g., 1 year from now)
  # expires_at = timeadd(timestamp(), "8760h")
  
  # Limit to specific roles if needed (optional)
  # roles = ["member"]
}

# =============================================================================
# NETWORKING INFRASTRUCTURE
# =============================================================================

# Create a network for the mke4k/k0s cluster
resource "openstack_networking_network_v2" "k8s_network" {
  count          = var.use_existing_network ? 0 : 1
  name           = "${local.full_cluster_name}-network"
  admin_state_up = "true"
}

# Create a subnet for the mke4k/k0s cluster
resource "openstack_networking_subnet_v2" "k8s_subnet" {
  count           = var.use_existing_network ? 0 : 1
  name            = "${local.full_cluster_name}-subnet"
  network_id      = openstack_networking_network_v2.k8s_network[0].id
  cidr            = var.network_cidr
  ip_version      = 4
  #dns_nameservers = var.dns_nameservers
}

# Create a router
resource "openstack_networking_router_v2" "k8s_router" {
  count               = var.use_existing_network ? 0 : 1
  name                = "${local.full_cluster_name}-router"
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.external.id
}

# Attach the subnet to the router
resource "openstack_networking_router_interface_v2" "k8s_router_interface" {
  count     = var.use_existing_network ? 0 : 1
  router_id = openstack_networking_router_v2.k8s_router[0].id
  subnet_id = openstack_networking_subnet_v2.k8s_subnet[0].id
}

# =============================================================================
# SECURITY GROUPS - MKE4K/K0S CLUSTER
# =============================================================================

# Security group for mke4K/k0s cluster
resource "openstack_networking_secgroup_v2" "k8s_secgroup" {
  name        = "${local.full_cluster_name}-secgroup"
  description = "Security group for mke4k/k0s cluster"
}

# SSH access
resource "openstack_networking_secgroup_rule_v2" "ssh" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# mke4k/k0s API server
resource "openstack_networking_secgroup_rule_v2" "k8s_api" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# k0s konnectivity - only for k0s clusters
resource "openstack_networking_secgroup_rule_v2" "k0s_konnectivity" {
  count             = var.cluster_type == "k0s" && var.konnectivity_enabled ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8132
  port_range_max    = 8132
  remote_ip_prefix  = var.network_cidr
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# mke4k ingress - only for mke4k clusters
resource "openstack_networking_secgroup_rule_v2" "mke4k_ingress" {
  count             = var.cluster_type == "mke4k" ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 33001
  port_range_max    = 33001
  remote_ip_prefix  = var.network_cidr
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}


# mke4k/k0s join API
resource "openstack_networking_secgroup_rule_v2" "k8s_join" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 9443
  port_range_max    = 9443
  remote_ip_prefix  = var.network_cidr
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# k0s konnectivity (external access for load balancer)
resource "openstack_networking_secgroup_rule_v2" "k0s_konnectivity_external" {
  count             = var.load_balancer_enabled && var.controller_count > 1 && var.cluster_type == "k0s" && var.konnectivity_enabled ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8132
  port_range_max    = 8132
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}


# mke4k/k0s join API (external access for load balancer)
resource "openstack_networking_secgroup_rule_v2" "k8s_join_external" {
  count             = var.load_balancer_enabled && var.controller_count > 1 ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 9443
  port_range_max    = 9443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Kubelet API
resource "openstack_networking_secgroup_rule_v2" "kubelet" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 10250
  port_range_max    = 10250
  remote_ip_prefix  = var.network_cidr
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# NodePort services
resource "openstack_networking_secgroup_rule_v2" "nodeport" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 30000
  port_range_max    = 32767
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Cilium VXLAN overlay (UDP 8472)
resource "openstack_networking_secgroup_rule_v2" "cilium_vxlan" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 8472
  port_range_max    = 8472
  remote_ip_prefix  = var.network_cidr
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Etcd client API (port 2379)
resource "openstack_networking_secgroup_rule_v2" "etcd_client" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 2379
  port_range_max    = 2379
  remote_ip_prefix  = var.network_cidr
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Etcd peer communication (port 2380)
resource "openstack_networking_secgroup_rule_v2" "etcd_peer" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 2380
  port_range_max    = 2380
  remote_ip_prefix  = var.network_cidr
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Allow all traffic within cluster network for pod-to-pod communication
resource "openstack_networking_secgroup_rule_v2" "cluster_internal" {
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_ip_prefix  = var.network_cidr
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# HTTP/HTTPS for ingress
resource "openstack_networking_secgroup_rule_v2" "http" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

resource "openstack_networking_secgroup_rule_v2" "https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# =============================================================================
# SECURITY GROUPS - BASTION HOST
# =============================================================================

# Security group for bastion host
resource "openstack_networking_secgroup_v2" "bastion_secgroup" {
  count       = var.bastion_enabled ? 1 : 0
  name        = "${local.full_cluster_name}-bastion-secgroup"
  description = "Security group for bastion host"
}

# SSH access to bastion from internet
resource "openstack_networking_secgroup_rule_v2" "bastion_ssh" {
  count             = var.bastion_enabled ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.bastion_secgroup[0].id
}

# Allow bastion to access cluster network
resource "openstack_networking_secgroup_rule_v2" "bastion_to_cluster" {
  count             = var.bastion_enabled ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  remote_group_id   = openstack_networking_secgroup_v2.bastion_secgroup[0].id
  security_group_id = openstack_networking_secgroup_v2.k8s_secgroup.id
}

# Allow ICMP to bastion for debugging
resource "openstack_networking_secgroup_rule_v2" "bastion_icmp_ingress" {
  count             = var.bastion_enabled ? 1 : 0
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.bastion_secgroup[0].id
}

# Allow ICMP from bastion for debugging
resource "openstack_networking_secgroup_rule_v2" "bastion_icmp_egress" {
  count             = var.bastion_enabled ? 1 : 0
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "icmp"
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = openstack_networking_secgroup_v2.bastion_secgroup[0].id
}

# =============================================================================
# BLOCK STORAGE VOLUMES
# =============================================================================

# Boot volumes for controllers
resource "openstack_blockstorage_volume_v3" "controller_volumes" {
  count       = var.controller_count
  name        = "${local.full_cluster_name}-controller-${count.index + 1}-volume"
  size        = var.volume_size
  volume_type = var.volume_type != "" ? var.volume_type : null
  image_id    = local.image_id
}

# Boot volumes for workers
resource "openstack_blockstorage_volume_v3" "worker_volumes" {
  count       = var.worker_count
  name        = "${local.full_cluster_name}-worker-${count.index + 1}-volume"
  size        = var.volume_size
  volume_type = var.volume_type != "" ? var.volume_type : null
  image_id    = local.image_id
}

# Boot volume for bastion host
resource "openstack_blockstorage_volume_v3" "bastion_volume" {
  count                = var.bastion_enabled ? 1 : 0
  name                 = "${local.full_cluster_name}-bastion-volume"
  size                 = 60  # Smaller volume for bastion
  volume_type          = var.volume_type != "" ? var.volume_type : null
  image_id             = local.bastion_image_id
  enable_online_resize = true
}

# =============================================================================
# COMPUTE INSTANCES
# =============================================================================

# Controller nodes
resource "openstack_compute_instance_v2" "k8s_controllers" {
  count           = var.controller_count
  name            = "${local.full_cluster_name}-controller-${count.index + 1}"
  flavor_id       = data.openstack_compute_flavor_v2.control_plane.id
  key_pair        = openstack_compute_keypair_v2.k8s_keypair.name
  security_groups = [openstack_networking_secgroup_v2.k8s_secgroup.name]

  network {
    uuid = local.network_id
  }

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.controller_volumes[count.index].id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/artifacts/cloud-init.yaml.tpl", {
    node_name = "${local.full_cluster_name}-controller-${count.index + 1}"
    openstack_services_ip = var.openstack_services_ip
    is_controller         = true
    use_custom_ca         = var.openstack_custom_ca
    manifest_content      = var.openstack_custom_ca ? file("${path.module}/manifests/secret-ca-cert.yaml") : ""
  })

  tags = var.tags
}

# Worker nodes
resource "openstack_compute_instance_v2" "k8s_workers" {
  count           = var.worker_count
  name            = "${local.full_cluster_name}-worker-${count.index + 1}"
  flavor_id       = data.openstack_compute_flavor_v2.worker.id
  key_pair        = openstack_compute_keypair_v2.k8s_keypair.name
  security_groups = [openstack_networking_secgroup_v2.k8s_secgroup.name]

  network {
    uuid = local.network_id
  }

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.worker_volumes[count.index].id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/artifacts/cloud-init.yaml.tpl", {
    node_name = "${local.full_cluster_name}-worker-${count.index + 1}"
    openstack_services_ip = var.openstack_services_ip
    is_controller         = false
    use_custom_ca         = false  # Workers don't need the manifest
    manifest_content      = ""
  })

  tags = var.tags
}

# Bastion host instance
resource "openstack_compute_instance_v2" "bastion" {
  count           = var.bastion_enabled ? 1 : 0
  name            = "${local.full_cluster_name}-bastion"
  flavor_id       = data.openstack_compute_flavor_v2.bastion[0].id
  key_pair        = openstack_compute_keypair_v2.k8s_keypair.name
  security_groups = [openstack_networking_secgroup_v2.bastion_secgroup[0].name]

  network {
    uuid = local.network_id
  }

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.bastion_volume[0].id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = true
  }

  # Ubuntu cloud-init for bastion host with SSH forwarding and tools
  user_data = base64encode(<<-EOF
    #cloud-config
    hostname: ${local.full_cluster_name}-bastion
    manage_etc_hosts: true
    package_update: false
    package_upgrade: false
    
    packages:
      - openssh-client
      - openssh-server
    
    ssh_pwauth: false
    disable_root: true
    
    users:
      - default
      - name: ubuntu
        groups: sudo
        shell: /bin/bash
        sudo: ['ALL=(ALL) NOPASSWD:ALL']
        ssh_authorized_keys:
          - ${tls_private_key.ssh_key.public_key_openssh}
    
    write_files:
      - path: /etc/ssh/sshd_config.d/99-bastion.conf
        content: |
          Port 22
          PermitRootLogin no
          PasswordAuthentication no
          PubkeyAuthentication yes
          AuthorizedKeysFile .ssh/authorized_keys
          
      - path: /etc/ssh/ssh_config.d/99-bastion.conf
        content: |
          Host *
              StrictHostKeyChecking no
              UserKnownHostsFile /dev/null
              ForwardAgent yes
              ServerAliveInterval 60
              ServerAliveCountMax 3
    
    runcmd:
      - systemctl enable ssh
      - systemctl restart ssh
      - systemctl status ssh
    EOF
  )

  tags = concat(var.tags, ["bastion", "ubuntu"])
}

# =============================================================================
# FLOATING IPS & ASSOCIATIONS
# =============================================================================

# Floating IP for bastion host (SSH access)
resource "openstack_networking_floatingip_v2" "bastion_fip" {
  count = var.bastion_enabled ? 1 : 0
  pool  = var.external_network_name
  tags  = var.tags
}

resource "openstack_compute_floatingip_associate_v2" "bastion_fip" {
  count       = var.bastion_enabled ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.bastion_fip[0].address
  instance_id = openstack_compute_instance_v2.bastion[0].id
}

resource "openstack_networking_floatingip_v2" "controller_fip" {
  count     = var.controller_floating_ips_enabled ? var.controller_count : 0
  pool      = var.external_network_name
  tags      = var.tags
}

resource "openstack_compute_floatingip_associate_v2" "controller_fip_assoc" {
  count       = var.controller_floating_ips_enabled ? var.controller_count : 0
  floating_ip = openstack_networking_floatingip_v2.controller_fip[count.index].address
  instance_id = openstack_compute_instance_v2.k8s_controllers[count.index].id
}

# Floating IPs for workers (optional, for direct access)
resource "openstack_networking_floatingip_v2" "worker_fip" {
  count = var.worker_floating_ips_enabled ? var.worker_count : 0
  pool  = var.external_network_name
  tags  = var.tags
}

resource "openstack_compute_floatingip_associate_v2" "worker_fip_assoc" {
  count       = var.worker_floating_ips_enabled ? var.worker_count : 0
  floating_ip = openstack_networking_floatingip_v2.worker_fip[count.index].address
  instance_id = openstack_compute_instance_v2.k8s_workers[count.index].id
}

# =============================================================================
# LOAD BALANCER (HIGH AVAILABILITY)
# =============================================================================

# Load balancer for control plane HA
resource "openstack_lb_loadbalancer_v2" "k8s_api_lb" {
  count          = var.load_balancer_enabled && var.controller_count > 1 ? 1 : 0
  name           = "${local.full_cluster_name}-api-lb"
  description    = "ws viasat PoC"
  vip_subnet_id  = var.load_balancer_vip_subnet_id != "" ? var.load_balancer_vip_subnet_id : local.subnet_id
  tags           = var.tags
}

# Floating IP for load balancer
resource "openstack_networking_floatingip_v2" "lb_fip" {
  count = var.load_balancer_enabled && var.controller_count > 1 && var.load_balancer_floating_ip_enabled ? 1 : 0
  pool  = var.external_network_name
  tags  = var.tags
}

# Associate floating IP with load balancer
resource "openstack_networking_floatingip_associate_v2" "lb_fip" {
  count       = var.load_balancer_enabled && var.controller_count > 1 && var.load_balancer_floating_ip_enabled ? 1 : 0
  floating_ip = openstack_networking_floatingip_v2.lb_fip[0].address
  port_id     = openstack_lb_loadbalancer_v2.k8s_api_lb[0].vip_port_id
}

# -----------------------------------------------------------------------------
# KUBERNETES API SERVER (6443)
# -----------------------------------------------------------------------------

# Listener for Kubernetes API (6443)
resource "openstack_lb_listener_v2" "k8s_api_listener" {
  count           = var.load_balancer_enabled && var.controller_count > 1 ? 1 : 0
  name            = "${local.full_cluster_name}-api-listener"
  protocol        = "TCP"
  protocol_port   = 6443
  loadbalancer_id = openstack_lb_loadbalancer_v2.k8s_api_lb[0].id
}

# Pool for control plane nodes
resource "openstack_lb_pool_v2" "k8s_api_pool" {
  count       = var.load_balancer_enabled && var.controller_count > 1 ? 1 : 0
  name        = "${local.full_cluster_name}-api-pool"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.k8s_api_listener[0].id
}

# Health monitor for API server
# delay/max_retries are kept low so the first controller is marked ONLINE quickly
# after its API starts (~10s worst case). Joining controllers validate the API
# through this LB VIP, so a slow promotion would race the k0sctl join phase and
# fail with "failed to connect ... to kubernetes api". See deploy_k0s() retry.
resource "openstack_lb_monitor_v2" "k8s_api_monitor" {
  count       = var.load_balancer_enabled && var.controller_count > 1 ? 1 : 0
  name        = "${local.full_cluster_name}-api-monitor"
  pool_id     = openstack_lb_pool_v2.k8s_api_pool[0].id
  type        = "TCP"
  delay       = 5
  timeout     = 3
  max_retries = 2
}

# Pool members (control plane nodes)
resource "openstack_lb_member_v2" "k8s_api_members" {
  count         = var.load_balancer_enabled && var.controller_count > 1 ? var.controller_count : 0
  name          = "${local.full_cluster_name}-controller-${count.index + 1}"
  pool_id       = openstack_lb_pool_v2.k8s_api_pool[0].id
  address       = openstack_compute_instance_v2.k8s_controllers[count.index].network[0].fixed_ip_v4
  protocol_port = 6443
}

# -----------------------------------------------------------------------------
# KONNECTIVITY (8132) - Only for k0s clusters
# -----------------------------------------------------------------------------

# Listener for Konnectivity (8132)
resource "openstack_lb_listener_v2" "k0s_konnectivity_listener" {
  count           = var.load_balancer_enabled && var.controller_count > 1 && var.cluster_type == "k0s" && var.konnectivity_enabled ? 1 : 0
  name            = "${local.full_cluster_name}-konnectivity-listener"
  protocol        = "TCP"
  protocol_port   = 8132
  loadbalancer_id = openstack_lb_loadbalancer_v2.k8s_api_lb[0].id
}

# Pool for Konnectivity
resource "openstack_lb_pool_v2" "k0s_konnectivity_pool" {
  count       = var.load_balancer_enabled && var.controller_count > 1 && var.cluster_type == "k0s" && var.konnectivity_enabled ? 1 : 0
  name        = "${local.full_cluster_name}-konnectivity-pool"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.k0s_konnectivity_listener[0].id
}

# Health monitor for Konnectivity
resource "openstack_lb_monitor_v2" "k0s_konnectivity_monitor" {
  count       = var.load_balancer_enabled && var.controller_count > 1 && var.cluster_type == "k0s" && var.konnectivity_enabled ? 1 : 0
  name        = "${local.full_cluster_name}-konnectivity-monitor"
  pool_id     = openstack_lb_pool_v2.k0s_konnectivity_pool[0].id
  type        = "TCP"
  delay       = 10
  timeout     = 5
  max_retries = 3
}

# Pool members for Konnectivity - modified temporarily by ws to replace the ingress_controller need for mke4k
resource "openstack_lb_member_v2" "k0s_konnectivity_members" {
  count         = var.load_balancer_enabled && var.controller_count > 1 && var.cluster_type == "k0s" && var.konnectivity_enabled ? var.controller_count : 0
  name          = "${local.full_cluster_name}-controller-${count.index + 1}-konnectivity"
  pool_id       = openstack_lb_pool_v2.k0s_konnectivity_pool[0].id
  address       = openstack_compute_instance_v2.k8s_controllers[count.index].network[0].fixed_ip_v4
  protocol_port = 8132
}

# ---------------------------------------------------------------------------------------
# Ingress (443/33001) - Only for mke4k clusters / duplicate to create 80/33000 if needed
# ---------------------------------------------------------------------------------------

# Listener for Ingress (443)
resource "openstack_lb_listener_v2" "mke4k_ingress_listener" {
  count           = var.load_balancer_enabled && var.controller_count > 1 && var.cluster_type == "mke4k" ? 1 : 0
  name            = "${local.full_cluster_name}-ingress-listener"
  protocol        = "TCP"
  protocol_port   = 443
  loadbalancer_id = openstack_lb_loadbalancer_v2.k8s_api_lb[0].id
}

# Pool for Ingress
resource "openstack_lb_pool_v2" "mke4k_ingress_pool" {
  count       = var.load_balancer_enabled && var.controller_count > 1 && var.cluster_type == "mke4k" ? 1 : 0
  name        = "${local.full_cluster_name}-ingress-pool"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.mke4k_ingress_listener[0].id
}

# Health monitor for Ingress
resource "openstack_lb_monitor_v2" "mke4k_ingress_monitor" {
  count       = var.load_balancer_enabled && var.controller_count > 1 && var.cluster_type == "mke4k" ? 1 : 0
  name        = "${local.full_cluster_name}-ingress-monitor"
  pool_id     = openstack_lb_pool_v2.mke4k_ingress_pool[0].id
  type        = "TCP"
  delay       = 10
  timeout     = 5
  max_retries = 3
}

# Pool members for Ingress
resource "openstack_lb_member_v2" "mke4k_ingress_members" {
  count         = var.load_balancer_enabled && var.controller_count > 1 && var.cluster_type == "mke4k" ? var.controller_count : 0
  name          = "${local.full_cluster_name}-controller-${count.index + 1}-ingress"
  pool_id       = openstack_lb_pool_v2.mke4k_ingress_pool[0].id
  address       = openstack_compute_instance_v2.k8s_controllers[count.index].network[0].fixed_ip_v4
  protocol_port = 33001
}

# -----------------------------------------------------------------------------
# CONTROLLER JOIN API (9443)
# -----------------------------------------------------------------------------

# Listener for Controller join API (9443)
resource "openstack_lb_listener_v2" "k8s_join_listener" {
  count           = var.load_balancer_enabled && var.controller_count > 1 ? 1 : 0
  name            = "${local.full_cluster_name}-join-listener"
  protocol        = "TCP"
  protocol_port   = 9443
  loadbalancer_id = openstack_lb_loadbalancer_v2.k8s_api_lb[0].id
}

# Pool for Controller join API
resource "openstack_lb_pool_v2" "k8s_join_pool" {
  count       = var.load_balancer_enabled && var.controller_count > 1 ? 1 : 0
  name        = "${local.full_cluster_name}-join-pool"
  protocol    = "TCP"
  lb_method   = "ROUND_ROBIN"
  listener_id = openstack_lb_listener_v2.k8s_join_listener[0].id
}

# Health monitor for Controller join API
resource "openstack_lb_monitor_v2" "k8s_join_monitor" {
  count       = var.load_balancer_enabled && var.controller_count > 1 ? 1 : 0
  name        = "${local.full_cluster_name}-join-monitor"
  pool_id     = openstack_lb_pool_v2.k8s_join_pool[0].id
  type        = "TCP"
  delay       = 10
  timeout     = 5
  max_retries = 3
}

# Pool members for Controller join API
resource "openstack_lb_member_v2" "k8s_join_members" {
  count         = var.load_balancer_enabled && var.controller_count > 1 ? var.controller_count : 0
  name          = "${local.full_cluster_name}-controller-${count.index + 1}-join"
  pool_id       = openstack_lb_pool_v2.k8s_join_pool[0].id
  address       = openstack_compute_instance_v2.k8s_controllers[count.index].network[0].fixed_ip_v4
  protocol_port = 9443
}

# =============================================================================
# K0SCTL CONFIGURATION FILE GENERATION
# =============================================================================

# Generate k0sctl configuration file
resource "local_file" "k0sctl_config" {
  count   = var.cluster_type == "k0s" ? 1 : 0
  content = templatefile("${path.module}/artifacts/k0sctl.yaml.tpl", {
    k0s_version            = var.k0s_version
    cluster_name           = var.cluster_name
    resource_prefix        = var.resource_prefix
    controller_count       = var.controller_count
    controller_private_ips = openstack_compute_instance_v2.k8s_controllers[*].network[0].fixed_ip_v4
    worker_fips            = var.worker_floating_ips_enabled ? openstack_networking_floatingip_v2.worker_fip[*].address : []
    controller_fips        = var.controller_floating_ips_enabled ? openstack_networking_floatingip_v2.controller_fip[*].address : []
    worker_private_ips    = openstack_compute_instance_v2.k8s_workers[*].network[0].fixed_ip_v4
    ssh_key_path          = "${path.cwd}/ssh-key"
    pod_cidr              = var.pod_cidr
    service_cidr          = var.service_cidr
    network_cidr          = var.network_cidr
    external_network_name = var.external_network_name
    
    # Network name for OpenStack CCM
    network_name          = var.use_existing_network ? var.existing_network_name : "${local.full_cluster_name}-network"
    
    # Bastion configuration
    bastion_enabled       = var.bastion_enabled
    bastion_ip           = var.bastion_enabled ? openstack_networking_floatingip_v2.bastion_fip[0].address : ""
    bastion_user         = var.bastion_user
    
    # Load balancer or single controller endpoint
    api_endpoint = var.load_balancer_enabled && var.controller_count > 1 ? (
      var.load_balancer_floating_ip_enabled ? 
        openstack_networking_floatingip_v2.lb_fip[0].address :
        openstack_lb_loadbalancer_v2.k8s_api_lb[0].vip_address
    ) : (
      var.controller_count == 1 && !var.load_balancer_enabled ? (
        openstack_networking_floatingip_v2.controller_fip[0].address
      ) : openstack_compute_instance_v2.k8s_controllers[0].network[0].fixed_ip_v4
    )
    
    # API sans (Subject Alternative Names)
    api_sans = compact([
      var.load_balancer_enabled && var.controller_count > 1 && var.load_balancer_floating_ip_enabled ? openstack_networking_floatingip_v2.lb_fip[0].address : null,
      var.load_balancer_enabled && var.controller_count > 1 ? openstack_lb_loadbalancer_v2.k8s_api_lb[0].vip_address : null,
      var.controller_count == 1 && !var.load_balancer_enabled ? openstack_networking_floatingip_v2.controller_fip[0].address : null,
      openstack_compute_instance_v2.k8s_controllers[0].network[0].fixed_ip_v4
    ])
    
    openstack_config = {
      auth_url    = local.auth_url
      region      = var.openstack_region
      subnet_id   = local.subnet_id
      network_id  = local.network_id
      floating_network_id = data.openstack_networking_network_v2.external.id
      # Application credential for CCM authentication
      application_credential_id = openstack_identity_application_credential_v3.ccm_credential.id
      application_credential_secret = openstack_identity_application_credential_v3.ccm_credential.secret
      # SSL/TLS configuration
      insecure = var.openstack_insecure
      custom_ca = var.openstack_custom_ca
    }
    
    # Calico configuration
    calico_mode = "vxlan"
    calico_mtu = 1450
  })
  filename = "${path.cwd}/k0sctl.yaml"
  
  depends_on = [
    openstack_compute_instance_v2.k8s_controllers,
    openstack_compute_instance_v2.k8s_workers,
    openstack_compute_instance_v2.bastion,
    openstack_networking_floatingip_v2.bastion_fip,
    openstack_networking_floatingip_v2.controller_fip,
    openstack_networking_floatingip_v2.lb_fip,
    openstack_identity_application_credential_v3.ccm_credential,
    local_file.private_key
  ]
}

# =============================================================================
# MKECTL/MKE4 CONFIGURATION FILE GENERATION
# =============================================================================

# Generate mkectl configuration file
resource "local_file" "mkectl_config" {
  count   = var.cluster_type == "mke4k" ? 1 : 0
  content = templatefile("${path.module}/artifacts/mkectl.yaml.tpl", {
    cluster_name           = var.cluster_name
    controller_count       = var.controller_count
    controller_private_ips = openstack_compute_instance_v2.k8s_controllers[*].network[0].fixed_ip_v4
    worker_fips            = var.worker_floating_ips_enabled ? openstack_networking_floatingip_v2.worker_fip[*].address : []
    controller_fips        = var.controller_floating_ips_enabled ? openstack_networking_floatingip_v2.controller_fip[*].address : []
    worker_private_ips    = openstack_compute_instance_v2.k8s_workers[*].network[0].fixed_ip_v4
    ssh_key_path          = "${path.cwd}/ssh-key"
    pod_cidr              = var.pod_cidr
    service_cidr          = var.service_cidr
    network_cidr          = var.network_cidr
    external_network_name = var.external_network_name
    external_address      = var.external_address
    external_floating_ip  = var.load_balancer_enabled && var.controller_count > 1 && var.load_balancer_floating_ip_enabled ? openstack_networking_floatingip_v2.lb_fip[0].address : ""
    ingress_http_port     = var.ingress_http_port
    ingress_https_port    = var.ingress_https_port
    oidc_enabled          = var.oidc_enabled
    oidc_issuer_url       = var.oidc_issuer_url
    oidc_client_id        = var.oidc_client_id
    oidc_client_secret_id = var.oidc_client_secret_id
    
    # Network name for OpenStack CCM
    network_name          = var.use_existing_network ? var.existing_network_name : "${local.full_cluster_name}-network"
    
    # Bastion configuration
    bastion_enabled       = var.bastion_enabled
    bastion_ip           = var.bastion_enabled ? openstack_networking_floatingip_v2.bastion_fip[0].address : ""
    bastion_user         = var.bastion_user
    
    # Load balancer or single controller endpoint
    api_endpoint = var.load_balancer_enabled && var.controller_count > 1 ? (
      var.load_balancer_floating_ip_enabled ? 
        openstack_networking_floatingip_v2.lb_fip[0].address :
        openstack_lb_loadbalancer_v2.k8s_api_lb[0].vip_address
    ) : (
      var.controller_count == 1 && !var.load_balancer_enabled ? (
        openstack_networking_floatingip_v2.controller_fip[0].address
      ) : openstack_compute_instance_v2.k8s_controllers[0].network[0].fixed_ip_v4
    )

    openstack_config = {
      auth_url    = local.auth_url
      region      = var.openstack_region
      subnet_id   = local.subnet_id
      network_id  = local.network_id
      floating_network_id = data.openstack_networking_network_v2.external.id
      # Application credential for CCM authentication
      application_credential_id = openstack_identity_application_credential_v3.ccm_credential.id
      application_credential_secret = openstack_identity_application_credential_v3.ccm_credential.secret
      # SSL/TLS configuration
      insecure = var.openstack_insecure
      custom_ca = var.openstack_custom_ca
    }
    
    # Calico configuration
    calico_mode = "vxlan"
    calico_mtu = 1450
  })
  filename = "${path.cwd}/mkectl.yaml"
  
  depends_on = [
    openstack_compute_instance_v2.k8s_controllers,
    openstack_compute_instance_v2.k8s_workers,
    openstack_compute_instance_v2.bastion,
    openstack_networking_floatingip_v2.bastion_fip,
    openstack_networking_floatingip_v2.controller_fip,
    openstack_networking_floatingip_v2.lb_fip,
    openstack_identity_application_credential_v3.ccm_credential,
    local_file.private_key
  ]
} 

# ================================================================================================================= 
# CCM CONFIGURATION FILE GENERATION - Useful only because mke4k does not support CCM integration in the mkectl file
# =================================================================================================================

# Generate ccm configuration file
resource "local_file" "ccm_config" {
  count   = var.cluster_type == "mke4k" ? 1 : 0
  content = templatefile("${path.module}/artifacts/secret-openstack-cloud-config.yaml.tpl", {
    openstack_config = {
      auth_url    = var.openstack_auth_url != "" ? var.openstack_auth_url : "$${OS_AUTH_URL}"
      region      = var.openstack_region
      subnet_id   = local.subnet_id
      network_id  = local.network_id
      floating_network_id = data.openstack_networking_network_v2.external.id
      # Application credential for CCM authentication
      application_credential_id = openstack_identity_application_credential_v3.ccm_credential.id
      application_credential_secret = openstack_identity_application_credential_v3.ccm_credential.secret
      # SSL/TLS configuration
      insecure = var.openstack_insecure
      custom_ca = var.openstack_custom_ca
    }
  })
  filename = "${path.cwd}/manifests/secret-openstack-cloud-config.yaml"
  
  depends_on = [
    openstack_identity_application_credential_v3.ccm_credential,
    openstack_networking_subnet_v2.k8s_subnet,
    openstack_networking_network_v2.k8s_network,
    data.openstack_networking_network_v2.external
  ]
} 