#cloud-config
hostname: ${node_name}
fqdn: ${node_name}.local

# Update packages and install basic dependencies
package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - git
  - jq
  - unzip
  - apt-transport-https
  - ca-certificates
  - gnupg
  - lsb-release

# Ensure SSH key authentication works
ssh_authorized_keys: []

runcmd:
  # Apply sysctl settings
  - sysctl --system
  # Ensure the system is ready for k0s installation
  - systemctl enable ssh
  - systemctl start ssh

final_message: "Node ${node_name} is ready for k0s installation!"
