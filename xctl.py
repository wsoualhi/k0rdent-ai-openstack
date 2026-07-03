#!/usr/bin/env python3
"""xctl - Deploy k0s or MKE4K management cluster on OpenStack."""

import json
import os
import re
import subprocess
import sys
import time
from base64 import b64decode
from pathlib import Path
from urllib.parse import urlparse

from dotenv import load_dotenv

# Project root = directory containing this script
ROOT = Path(__file__).resolve().parent
KUBECONFIG_DIR = ROOT / "kubeconfigs"           # all kubeconfigs live here (gitignored)
KUBECONFIG_PATH = KUBECONFIG_DIR / "management"  # this (management) cluster's kubeconfig

# --- Colors ---
RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
BLUE = "\033[0;34m"
NC = "\033[0m"


def print_status(msg: str) -> None:
    print(f"{BLUE}[INFO]{NC} {msg}")


def print_success(msg: str) -> None:
    print(f"{GREEN}[SUCCESS]{NC} {msg}")


def print_warning(msg: str) -> None:
    print(f"{YELLOW}[WARNING]{NC} {msg}")


def print_error(msg: str) -> None:
    print(f"{RED}[ERROR]{NC} {msg}")


# --- Helpers ---


def run(cmd: str | list[str], *, check: bool = True, capture: bool = False,
        env: dict | None = None, tee_file: str | None = None) -> subprocess.CompletedProcess:
    """Run a shell command. If tee_file is set, stream stdout+stderr to both console and file."""
    merged_env = {**os.environ, **(env or {})}
    shell = isinstance(cmd, str)

    if tee_file:
        proc = subprocess.Popen(
            cmd, shell=shell, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            env=merged_env, cwd=ROOT,
        )
        assert proc.stdout is not None  # guaranteed by stdout=PIPE
        with open(ROOT / tee_file, "a") as f:
            for line in proc.stdout:
                decoded = line.decode(errors="replace")
                sys.stdout.write(decoded)
                f.write(decoded)
        proc.wait()
        if check and proc.returncode != 0:
            raise subprocess.CalledProcessError(proc.returncode, cmd)
        return subprocess.CompletedProcess(cmd, proc.returncode)

    return subprocess.run(
        cmd, shell=shell, check=check, capture_output=capture,
        text=True, env=merged_env, cwd=ROOT,
    )


def run_capture(cmd: str) -> str:
    """Run a command and return stripped stdout, or empty string on failure."""
    result = run(cmd, check=False, capture=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def terraform_output(name: str, *, raw: bool = False) -> str | None:
    """Get a Terraform output value."""
    flag = "-raw" if raw else "-json"
    result = run(f"terraform output {flag} {name}", check=False, capture=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def terraform_output_json(name: str):
    """Get a Terraform output as parsed JSON."""
    raw = terraform_output(name)
    if not raw or raw == "null":
        return None
    return json.loads(raw)


def get_cluster_type() -> str:
    """Read cluster_type from terraform.tfvars."""
    tfvars = ROOT / "terraform.tfvars"
    if not tfvars.exists():
        print_error("xctl:terraform.tfvars not found")
        sys.exit(1)
    content = tfvars.read_text()
    match = re.search(r'cluster_type\s*=\s*"([^"]+)"', content)
    if not match:
        print_error("xctl:cluster_type not found in terraform.tfvars")
        sys.exit(1)
    return match.group(1)


def tfvar(name: str, default: str = "") -> str:
    """Read a single value from terraform.tfvars (strips quotes/comments). Best-effort."""
    tfvars = ROOT / "terraform.tfvars"
    if not tfvars.exists():
        return default
    m = re.search(rf'^\s*{re.escape(name)}\s*=\s*"?([^"\n#]+?)"?\s*(?:#.*)?$',
                  tfvars.read_text(), re.M)
    return m.group(1).strip() if m else default


def fmt_duration(seconds: float) -> str:
    """Format a duration as 'Xm Ys'."""
    s = int(seconds)
    return f"{s // 60}m {s % 60}s"


def target_cloud() -> str:
    """Describe the OpenStack cloud the loaded .env targets (guardrail for multi-env use)."""
    auth = os.environ.get("OS_AUTH_URL") or "(OS_AUTH_URL not set)"
    project = os.environ.get("OS_PROJECT_NAME") or "?"
    return f"{auth}  (project: {project})"


def command_exists(cmd: str) -> bool:
    """Check if a command is available on PATH."""
    return subprocess.run(
        ["which", cmd], capture_output=True, text=True
    ).returncode == 0


def load_env() -> None:
    """Load .env file and export variables to os.environ."""
    env_file = ROOT / ".env"
    if not env_file.exists():
        print_error("xctl:.env file not found. Please create it with your OpenStack credentials (see .env.example).")
        sys.exit(1)
    load_dotenv(env_file, override=True)


# --- Functions ---


def show_help() -> None:
    project = os.environ.get("OS_PROJECT_NAME", "N/A")
    user = os.environ.get("OS_USERNAME", "N/A")
    auth = os.environ.get("OS_AUTH_URL", "N/A")

    print("--------------------------------------------------------")
    print("Deploy k0s or MKE4K management cluster on OpenStack")
    print("--------------------------------------------------------")
    print()
    print(f"  OpenStack project : {project}")
    print(f"  OpenStack user    : {user}")
    print(f"  Auth URL          : {auth}")
    print()
    print("  Tip: 'set -a; source .env; set +a' to load env vars for manual openstack CLI use")
    print()
    print("Usage: xctl [COMMAND]")
    print()
    print("Fully automated:")
    print("  deploy_all                 Full deployment pipeline")
    print("  destroy_all                Destroy all resources")
    print()
    print("Step by step:")
    print("  check_prerequisites        Run pre-deployment checks")
    print("  deploy_infra               Deploy infrastructure with Terraform")
    print("  deploy_k8s                 Deploy k0s or MKE4K cluster")
    print("  setup_kubeconfig           Generate kubeconfig")
    print("  deploy_custom_ca_secret    Deploy custom CA secret")
    print("  extract_openstack_ca_cert  Extract OpenStack CA certificate")
    print("  deploy_ccm                 Deploy CCM and CSI")
    print("  remove_floating_ips        Remove floating IPs")
    print("  verify_cluster             Verify cluster deployment")
    print("  cluster_access             Display cluster access credentials")
    print("  remove_from_known_hosts    Clean SSH known_hosts entries")
    print("--------------------------------------------------------")


def remove_from_known_hosts() -> None:
    """Remove every IP the deploy will SSH to from known_hosts.

    Covers bastion / load balancer / node floating IPs *and* the private node
    IPs (k0sctl/mkectl connect to those through the bastion). Stale host keys on
    any of these cause host-key-verification failures, so clear them all before
    deploying.
    """
    print_status("xctl:Removing deployment IPs from known_hosts...")

    if not (ROOT / ".terraform").is_dir():
        print_warning("Terraform not initialized, skipping known_hosts cleanup")
        return

    if not (ROOT / "terraform.tfstate").exists():
        print_warning("No Terraform state found, skipping known_hosts cleanup")
        return

    targets = [
        ("bastion_floating_ip", "bastion floating IP"),
        ("load_balancer_floating_ip", "load balancer floating IP"),
        ("controller_floating_ip", "controller floating IP"),
        ("worker_floating_ips", "worker floating IP"),
        ("controller_private_ips", "controller private IP"),
        ("worker_private_ips", "worker private IP"),
    ]

    for output_name, label in targets:
        value = terraform_output_json(output_name)
        # Outputs may be a scalar string or a list; normalize to a list of IPs.
        ips = value if isinstance(value, list) else [value]
        ips = [ip for ip in ips if ip and ip != "null"]
        if not ips:
            print_status(f"xctl:No {label}s found in Terraform state")
            continue
        for ip in ips:
            run(f'ssh-keygen -R "{ip}"', check=False)
            print_success(f"xctl:Removed {label} {ip} from known_hosts")


def remove_floating_ips() -> None:
    """Remove worker and master floating IPs using Terraform."""
    print_status("xctl:Removing worker and master floating IPs using Terraform...")

    if not (ROOT / ".terraform").is_dir():
        print_error("xctl:Terraform not initialized. Please run 'terraform init' first.")
        sys.exit(1)

    state_list = run_capture("terraform state list")
    fip_resources = [
        line for line in state_list.splitlines()
        if re.search(r"openstack_networking_floatingip_v2\.(worker_fip|controller_fip)", line)
    ]

    if not fip_resources:
        print_warning("No worker or controller floating IPs found in Terraform state")
        return

    print_status("xctl:Found floating IP resources to remove:")
    for r in fip_resources:
        print(f"  {r}")

    run(
        "terraform destroy "
        "-target=openstack_networking_floatingip_v2.worker_fip "
        "-target=openstack_networking_floatingip_v2.controller_fip "
        "-auto-approve"
    )
    print_success("xctl:Worker and master floating IPs removed successfully")


def deploy_ccm() -> None:
    """Deploy OpenStack Cloud Controller Manager and CSI."""
    cluster_type = get_cluster_type()
    if cluster_type == "k0s":
        print_status("xctl:Skipping CCM/CSI deployment — k0s installs them via embedded Helm charts in k0sctl.yaml")
        return

    print_status("xctl:Deploying OpenStack Cloud Controller Manager and CSI...")

    kubeconfig = KUBECONFIG_PATH
    if not kubeconfig.exists():
        print_error("xctl:kubeconfig not found. Please run setup_kubeconfig first.")
        sys.exit(1)

    env = {"KUBECONFIG": str(kubeconfig)}

    print_status("xctl:Applying OpenStack cloud config secret...")
    run("kubectl apply -f manifests/secret-openstack-cloud-config.yaml", env=env)

    print_status("xctl:Adding OpenStack Helm repository...")
    run("helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack", env=env)

    print_status("xctl:Deploying OpenStack Cloud Controller Manager...")
    run("helm upgrade -i openstack-ccm cpo/openstack-cloud-controller-manager --values artifacts/values-openstack-ccm.yaml -n kube-system", env=env)

    print_status("xctl:Deploying OpenStack Cinder CSI...")
    run("helm upgrade -i openstack-csi cpo/openstack-cinder-csi --values artifacts/values-openstack-csi.yaml -n kube-system", env=env)

    print_success("xctl:OpenStack Cloud Controller Manager and CSI deployed successfully")


def check_prerequisites() -> None:
    """Check required tools, credentials, and infrastructure status."""
    print_status("xctl:Running the checks:")
    (ROOT / "manifests").mkdir(exist_ok=True)

    # Check .env file exists
    if not (ROOT / ".env").exists():
        print_error("xctl:.env file not found. Please create it with your OpenStack credentials (see .env.example).")
        sys.exit(1)

    # Determine which cluster we are deploying (also verifies terraform.tfvars exists)
    cluster_type = get_cluster_type()

    # Tools required regardless of cluster type
    if not command_exists("terraform"):
        print_error("xctl:Terraform is not installed. Please install Terraform >= 1.0")
        sys.exit(1)

    if not command_exists("kubectl"):
        print_error("xctl:kubectl is not installed. Please install kubectl (https://kubernetes.io/docs/tasks/tools/).")
        sys.exit(1)

    # Cluster-type specific tools
    tools = ["terraform", "kubectl"]
    if cluster_type == "k0s":
        if not command_exists("k0sctl"):
            print_warning("k0sctl not found. Installing k0sctl...")
            run("curl -sSLf https://get.k0sctl.sh | sudo sh", check=True)
            if not command_exists("k0sctl"):
                print_error("xctl:Failed to install k0sctl")
                sys.exit(1)
        tools.append("k0sctl")
        # k0s installs CCM/CSI via embedded Helm charts in k0sctl.yaml — no helm CLI needed.

    elif cluster_type == "mke4k":
        if not command_exists("mkectl"):
            print_warning("mkectl not found. Installing mkectl...")
            run("curl -sSLf https://get.mkectl.sh | sudo sh", check=True)
            if not command_exists("mkectl"):
                print_error("xctl:Failed to install mkectl")
                sys.exit(1)

        # Check mkectl version
        mkectl_version = run_capture("mkectl version")
        version_match = re.search(r"(\d+\.\d+\.\d+)", mkectl_version)
        mkectl_ver = version_match.group(1) if version_match else "0.0.0"

        ver_tuple = tuple(int(x) for x in mkectl_ver.split("."))
        if ver_tuple < (4, 1, 1):
            print_error(f"xctl:mkectl version {mkectl_ver} is not supported. Please install version 4.1.1 or above")
            sys.exit(1)
        tools.append(f"mkectl (version {mkectl_ver})")

        # helm is required to deploy CCM/CSI for MKE4K.
        if not command_exists("helm"):
            print_error("xctl:helm is not installed. Please install Helm >= 3 (https://helm.sh/docs/intro/install/).")
            sys.exit(1)
        tools.append("helm")

    else:
        print_error(f"xctl:Unknown cluster type: {cluster_type}")
        sys.exit(1)

    # Check OpenStack credentials
    if not all(os.environ.get(v) for v in ("OS_AUTH_URL", "OS_PROJECT_NAME", "OS_USERNAME")):
        print_error("xctl:OpenStack credentials not found! Please check your .env file.")
        sys.exit(1)

    # Check Terraform state
    if not (ROOT / ".terraform").is_dir():
        print_status("xctl:Initializing Terraform...")
        run("terraform init")

    resource_count = len(run_capture("terraform state list").splitlines())
    if resource_count > 0:
        print_success(f"xctl:Infrastructure already exists ({resource_count} resources found)")
    else:
        print_status("xctl:No existing infrastructure found")

    print_success(f"xctl:All dependencies are available for {cluster_type}: {', '.join(tools)}")
    print_success(f"xctl:OpenStack credentials found for project: {os.environ.get('OS_PROJECT_NAME')}")
    print_success("xctl:All checks passed")


def deploy_infra() -> None:
    """Deploy infrastructure with Terraform."""
    print_status("xctl:Deploying infrastructure with Terraform...")
    run("terraform init")
    run("terraform plan -out=tfplan")
    run("terraform apply tfplan")
    (ROOT / "tfplan").unlink(missing_ok=True)
    print_success("xctl:Infrastructure deployed successfully")


def deploy_k0s() -> None:
    """Deploy k0s cluster using k0sctl."""
    print_status("xctl:Deploying k0s cluster using k0sctl.yaml...")

    if not (ROOT / "k0sctl.yaml").exists():
        print_error("xctl:k0sctl.yaml not found.")
        sys.exit(1)

    remove_from_known_hosts()

    print_status("xctl:Starting k0s cluster deployment (this may take several minutes)...")
    print_status("xctl:Logs will be saved to k0sctl.logs")
    # Clear SSH_AUTH_SOCK so k0sctl/rig authenticates with the explicit keyPath in
    # k0sctl.yaml instead of falling back to a (possibly stale) ssh-agent key,
    # which causes silent auth failures at the "Connect to hosts" phase.
    #
    # Single apply, no retry: re-running `k0sctl apply` on an already-initialized
    # controller triggers a k0s "Reinstall" that can corrupt control-plane state, so
    # we never auto-retry. A first-try success is guaranteed by the LB health monitor
    # being fast enough to mark the first controller ONLINE before the join phase
    # (delay=5/max_retries=2, see main.tf) and by the Calico config pinning the VXLAN
    # tunnel to the node IP (see k0sctl.yaml.tpl). If apply fails, the real error is
    # surfaced; recover with 'destroy_all' + redeploy rather than re-running apply.
    run("k0sctl apply --config k0sctl.yaml", tee_file="k0sctl.logs", env={"SSH_AUTH_SOCK": ""})


def deploy_mke4k() -> None:
    """Deploy MKE4K cluster using mkectl."""
    print_status("xctl:Deploying MKE4K cluster using mkectl.yaml...")

    if not (ROOT / "mkectl.yaml").exists():
        print_error("xctl:mkectl.yaml not found.")
        sys.exit(1)

    remove_from_known_hosts()

    print_status("xctl:Starting MKE4K cluster deployment (this may take several minutes)...")
    print_status("xctl:Logs will be saved to mkectl.logs")
    # See deploy_k0s: clear SSH_AUTH_SOCK so the explicit keyPath is used rather
    # than a stale ssh-agent key.
    run("mkectl apply -f mkectl.yaml -l debug", tee_file="mkectl.logs", env={"SSH_AUTH_SOCK": ""})


def deploy_k8s() -> None:
    """Deploy k0s or MKE4K cluster based on cluster_type."""
    cluster_type = get_cluster_type()
    if cluster_type == "k0s":
        deploy_k0s()
    elif cluster_type == "mke4k":
        deploy_mke4k()
    else:
        print_error(f"xctl:Unknown cluster type: {cluster_type}")
        sys.exit(1)


def setup_kubeconfig() -> None:
    """Generate kubeconfig file."""
    cluster_type = get_cluster_type()
    print_status(f"xctl:Setting up kubeconfig for {cluster_type} cluster...")

    if cluster_type == "k0s":
        # Same SSH_AUTH_SOCK fix as deploy_k0s: k0sctl kubeconfig also SSHes to the
        # hosts and must use the explicit keyPath, not a stale ssh-agent key.
        result = run("k0sctl kubeconfig --config k0sctl.yaml", capture=True,
                     env={"SSH_AUTH_SOCK": ""})
        (KUBECONFIG_PATH).write_text(result.stdout)
    elif cluster_type == "mke4k":
        print_status("xctl:The mkectl apply command configures the mke context in ~/.mke/mke.kubeconf")
        src = Path.home() / ".mke" / "mke.kubeconf"
        if src.exists():
            (KUBECONFIG_PATH).write_text(src.read_text())
        else:
            print_error("xctl:~/.mke/mke.kubeconf not found")
            sys.exit(1)

    os.environ["KUBECONFIG"] = str(KUBECONFIG_PATH)
    print_success("xctl:Kubeconfig generated: ./kubeconfigs/management")
    print_status("xctl:To use kubectl with this cluster:")
    print_status("xctl:  export KUBECONFIG=./kubeconfigs/management")
    print_status("xctl:  kubectl get nodes")


def deploy_custom_ca_secret() -> None:
    """Deploy custom CA secret if enabled in terraform.tfvars."""
    print_status("xctl:Deploying custom CA secret...")

    tfvars = (ROOT / "terraform.tfvars").read_text()
    if not re.search(r"openstack_custom_ca\s*=\s*true", tfvars):
        print_status("xctl:Custom CA not enabled - skipping secret deployment")
        return

    print_status("xctl:Custom CA enabled - applying secret directly...")
    env = {"KUBECONFIG": str(KUBECONFIG_PATH)}

    print_status("xctl:Creating custom CA secret from manifests/secret-ca-cert.yaml...")
    run("kubectl apply -f manifests/secret-ca-cert.yaml", env=env)

    result = run("kubectl get secret custom-ca-cert -n kube-system", check=False, env=env)
    if result.returncode == 0:
        print_success("xctl:Custom CA secret 'custom-ca-cert' created successfully")
    else:
        print_error("xctl:Failed to create custom CA secret")
        sys.exit(1)


def extract_openstack_ca_cert() -> None:
    """Extract OpenStack CA certificate and create Kubernetes secret."""
    print_status("xctl:This function extracts the CA certificate for custom CA setups (self-signed certificates)")

    (ROOT / "manifests").mkdir(exist_ok=True)
    secret_file = ROOT / "manifests" / "secret-ca-cert.yaml"
    temp_cert = Path("/tmp/keystone_ca.crt")

    auth_url = os.environ.get("OS_AUTH_URL", "")
    parsed = urlparse(auth_url)
    fqdn = parsed.hostname
    if not fqdn:
        print_error("xctl:Cannot parse OS_AUTH_URL hostname")
        sys.exit(1)

    print_status(f"xctl:Connecting to {auth_url} to extract SSL certificate...")

    # Extract certificate chain
    result = run(
        f'openssl s_client -connect "{fqdn}:443" -servername "{fqdn}" -showcerts < /dev/null 2>/dev/null '
        f"| awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/'",
        check=False, capture=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        print_error(f"xctl:Failed to extract certificate from {auth_url}")
        sys.exit(1)

    temp_cert.write_text(result.stdout)

    # Validate
    validate = run(f'openssl x509 -in "{temp_cert}" -text -noout', check=False, capture=True)
    if validate.returncode != 0:
        print_error("xctl:The certificate was extracted but is invalid")
        sys.exit(1)

    # Get PEM and base64 encode
    pem_result = run(
        f'openssl x509 -in "{temp_cert}" -outform PEM 2>/dev/null | awk \'/BEGIN CERTIFICATE/,/END CERTIFICATE/\'',
        capture=True,
    )
    ca_cert = pem_result.stdout.strip()
    if not ca_cert:
        print_error("xctl:Failed to extract CA certificate from chain")
        sys.exit(1)

    import base64
    ca_cert_b64 = base64.b64encode(ca_cert.encode()).decode()

    # Write secret manifest
    secret_file.write_text(
        f"apiVersion: v1\n"
        f"kind: Secret\n"
        f"metadata:\n"
        f"  name: custom-ca-cert\n"
        f"  namespace: kube-system\n"
        f"type: Opaque\n"
        f"data:\n"
        f"  ca.crt: {ca_cert_b64}\n"
    )

    # Show certificate details
    print_status("xctl:Certificate details:")
    for field, flag in [("Subject", "-subject"), ("Issuer", "-issuer"), ("Valid from", "-startdate"), ("Valid until", "-enddate")]:
        val = run_capture(f'echo "{ca_cert}" | openssl x509 -noout {flag}')
        val = re.sub(r"^[^=]+=", "", val)
        print(f"      * {field}: {val}")

    temp_cert.unlink(missing_ok=True)
    print_status(f"xctl:CA certificate extracted and saved under: {secret_file}")


def verify_cluster() -> None:
    """Verify cluster deployment."""
    print_status("xctl:Verifying cluster...")
    env = {"KUBECONFIG": str(KUBECONFIG_PATH)}

    print_status("xctl:Waiting for nodes to be ready...")
    run("kubectl wait --for=condition=Ready nodes --all --timeout=300s", env=env)

    print_status("xctl:Checking OpenStack Cloud Controller Manager...")
    run("kubectl get pods -n kube-system -l app=openstack-cloud-controller-manager", env=env)

    print_status("xctl:Cluster status:")
    run("kubectl get nodes -o wide", env=env)

    print_success("xctl:Cluster verification completed!")


def cluster_access() -> None:
    """Extract and display cluster access credentials."""
    cluster_type = get_cluster_type()

    if cluster_type != "mke4k" or not (ROOT / "mkectl.logs").exists():
        return

    lb_ip = terraform_output("load_balancer_floating_ip", raw=True)
    if not lb_ip:
        print_warning("xctl:Could not get load balancer IP")
        return

    # Extract admin credentials from mkectl.logs
    logs = (ROOT / "mkectl.logs").read_text()
    cred_match = re.search(r"Generated username:password\s*\n\s*(.+)", logs)
    credentials = cred_match.group(1).strip() if cred_match else ""

    if not credentials:
        print_warning("xctl:No admin credentials found in mkectl.logs")
        return

    password = credentials.split(":", 1)[1] if ":" in credentials else credentials
    env = {"KUBECONFIG": str(KUBECONFIG_PATH)}

    def kubectl_secret(secret: str, namespace: str, key: str) -> str:
        result = run(
            f"kubectl get secret {secret} -n {namespace} -o jsonpath='{{.data.{key}}}'",
            check=False, capture=True, env=env,
        )
        if result.returncode == 0 and result.stdout:
            return b64decode(result.stdout.strip("'")).decode()
        return "N/A"

    grafana_user = kubectl_secret("monitoring-grafana", "mke", "admin-user")
    grafana_pass = kubectl_secret("monitoring-grafana", "mke", "admin-password")
    minio_user = kubectl_secret("minio-credentials", "mke", "root-user")
    minio_pass = kubectl_secret("minio-credentials", "mke", "root-password")

    print()
    print("=" * 60)
    print("                   MKE4K Access Details")
    print("=" * 60)
    print_success("xctl:Admin Portal")
    print(f"  URL:      https://{lb_ip}")
    print(f"  Username: admin")
    print(f"  Password: {password}")
    print("-" * 60)
    print_success("xctl:Grafana Dashboard")
    print(f"  URL:      https://{lb_ip}/grafana/")
    print(f"  Username: {grafana_user}")
    print(f"  Password: {grafana_pass}")
    print("-" * 60)
    print_success("xctl:MinIO Storage")
    print(f"  URL:      https://{lb_ip}/minio/")
    print(f"  Username: {minio_user}")
    print(f"  Password: {minio_pass}")
    print("-" * 60)
    print_success("xctl:Dex Authentication")
    print(f"  URL:      https://{lb_ip}/dex")
    print(f"  Note:     Configure with external identity provider")
    print("=" * 60)
    print()


def _k0s_chart_version(chartname: str) -> str:
    """Read a Helm chart version from the generated k0sctl.yaml. Best-effort."""
    f = ROOT / "k0sctl.yaml"
    if not f.exists():
        return "n/a"
    m = re.search(rf'chartname:\s*{re.escape(chartname)}\s*\n\s*version:\s*"?([^"\n]+)"?',
                  f.read_text())
    return m.group(1).strip() if m else "n/a"


def deployment_summary(cluster_type: str, timings: list, total: float) -> None:
    """Print a concise recap of what was deployed, how to connect, and timings.

    Built only from sources that survive a full deploy_all (terraform.tfvars, the
    generated k0sctl.yaml, the kubeconfig, and terraform state) — terraform outputs
    are NOT used because remove_floating_ips wipes the ones that reference FIPs.
    Best-effort: never raises, so it cannot fail an otherwise-successful deploy.
    """
    try:
        prefix = tfvar("resource_prefix")
        name = tfvar("cluster_name")
        full_name = f"{prefix}-{name}".strip("-")
        controllers = tfvar("controller_count", "?")
        workers = tfvar("worker_count", "0")
        cp_flavor = tfvar("control_plane_flavor", "?")
        wrk_flavor = tfvar("worker_flavor", "?")
        bastion = tfvar("bastion_enabled", "false")
        image = tfvar("image_name", "?")
        calico_mode = tfvar("calico_mode", "vxlan")
        calico_mtu = tfvar("calico_mtu", "1450")

        # API endpoint: read from the kubeconfig (most reliable post-deploy).
        api_endpoint = "n/a"
        kc = KUBECONFIG_PATH
        if kc.exists():
            m = re.search(r"server:\s*(\S+)", kc.read_text())
            if m:
                api_endpoint = m.group(1)

        # Actual deployed resource counts from terraform state.
        state = run_capture("terraform state list")
        cnt = lambda pat: sum(1 for ln in state.splitlines() if pat in ln)
        vms = cnt("openstack_compute_instance_v2")
        lbs = cnt("openstack_lb_loadbalancer_v2")
        sgs = cnt("openstack_networking_secgroup_v2")
        vols = cnt("openstack_blockstorage_volume_v3")

        if cluster_type == "k0s":
            version = tfvar("k0s_version", "n/a")
            ccm = _k0s_chart_version("cpo/openstack-cloud-controller-manager")
            csi = _k0s_chart_version("cpo/openstack-cinder-csi")
            addons = f"OpenStack CCM {ccm}, Cinder CSI {csi} (embedded Helm)"
        else:
            version = "MKE4K (see mkectl.logs)"
            addons = "OpenStack CCM + Cinder CSI (Helm)"

        line = "=" * 60
        print()
        print(line)
        print("Deployment summary")
        print(line)
        print(f"Cluster:       {cluster_type}  ({full_name})  {version}")
        print(f"Nodes:         {controllers} controllers ({cp_flavor}), "
              f"{workers} workers ({wrk_flavor}), bastion: {bastion}")
        print(f"Image:         {image}")
        print(f"CNI:           Calico ({calico_mode}, MTU {calico_mtu})")
        print(f"Networking:    pod {tfvar('pod_cidr','?')}  "
              f"service {tfvar('service_cidr','?')}  node {tfvar('network_cidr','?')}")
        print(f"Add-ons:       {addons}")
        print(f"OpenStack:     {vms} VMs, {lbs} load balancer(s), "
              f"{sgs} security group(s), {vols} volume(s)")
        print(f"Cloud:         {target_cloud()}")
        print(f"API endpoint:  {api_endpoint}")
        print()
        print("Connect:")
        print(f"  export KUBECONFIG={ROOT / 'kubeconfig'}")
        print("  kubectl get nodes")
        if cluster_type == "mke4k":
            print("  (MKE4K admin/Grafana/MinIO credentials shown above)")
        print()
        print("Timings:")
        for label, secs in timings:
            print(f"  {label:<22} {fmt_duration(secs)}")
        print(f"  {'Total':<22} {fmt_duration(total)}")
        print(line)
        print()
    except Exception as exc:  # never let the recap break a successful deploy
        print_warning(f"Could not render deployment summary: {exc}")


def deploy_all() -> None:
    """Complete deployment process."""
    cluster_type = get_cluster_type()
    start = time.time()

    print_status(f"xctl:Script will now deploy {cluster_type} cluster. You can select the cluster type in terraform.tfvars")
    print_warning(f"Target OpenStack cloud: {target_cloud()}")
    reply = input("Do you want to proceed? (y/N): ").strip().lower()
    if reply != "y":
        print_warning("Deployment cancelled by user")
        return

    print_status("xctl:Starting complete deployment process...")

    timings: list = []

    def step(num: int, label: str, fn) -> None:
        print_status(f"xctl:Step {num}/8: {label}...")
        t0 = time.time()
        fn()
        timings.append((label, time.time() - t0))

    step(1, "Running pre-deployment checks", check_prerequisites)
    step(2, "Deploying infrastructure", deploy_infra)
    step(3, f"Deploying {cluster_type} cluster", deploy_k8s)
    step(4, "Setting up kubeconfig", setup_kubeconfig)
    step(5, "Verifying cluster", verify_cluster)
    step(6, "Deploying CCM/CSI", deploy_ccm)
    step(7, "Removing floating IPs", remove_floating_ips)
    step(8, "Summarizing cluster access", cluster_access)

    elapsed = int(time.time() - start)
    deployment_summary(cluster_type, timings, elapsed)
    print_success(f"xctl:Complete deployment finished successfully in {fmt_duration(elapsed)}!")


def destroy_all() -> None:
    """Destroy all resources."""
    print()
    print_status("xctl:WARNING: DESTRUCTIVE OPERATION")
    print()
    print("This operation will:")
    print("  - Destroy all infrastructure and cloud resources")
    print("  - Remove all logs and audit trails")
    print("  - Delete all access credentials")
    print("  - Clean up configuration manifests")
    print()
    print("This action cannot be undone.")
    print()
    print_warning(f"Target OpenStack cloud: {target_cloud()}")
    print()

    reply = input("Are you sure you want to proceed with destruction? [y/N] ").strip().lower()
    if reply != "y":
        print_status("xctl:Destruction averted - cluster lives another day")
        return

    start = time.time()

    # Count resources before teardown so we can report what was removed.
    resource_count = len(run_capture("terraform state list").splitlines())

    print_status("xctl:Destroying all resources...")
    run("terraform destroy -auto-approve")

    removed_files = []
    for name in ["mkectl.logs", "k0sctl.logs", "mkectl.yaml", "k0sctl.yaml", "ssh-key", "ssh-key.pub"]:
        p = ROOT / name
        if p.exists():
            removed_files.append(name)
        p.unlink(missing_ok=True)

    # Remove all generated kubeconfigs (kubeconfigs/ directory)
    if KUBECONFIG_DIR.is_dir():
        for f in KUBECONFIG_DIR.iterdir():
            if f.is_file():
                removed_files.append(f"kubeconfigs/{f.name}")
                f.unlink(missing_ok=True)
        KUBECONFIG_DIR.rmdir()

    # Clean manifests
    manifests = ROOT / "manifests"
    if manifests.is_dir():
        for f in manifests.iterdir():
            if f.is_file():
                removed_files.append(f"manifests/{f.name}")
            f.unlink(missing_ok=True)

    elapsed = int(time.time() - start)
    line = "=" * 60
    print()
    print(line)
    print("Teardown summary")
    print(line)
    print(f"OpenStack resources destroyed: {resource_count}")
    print(f"Generated files removed:       {len(removed_files)}")
    if removed_files:
        print(f"  {', '.join(removed_files)}")
    print(f"Total:                         {fmt_duration(elapsed)}")
    print(line)
    print()
    print_success(f"xctl:All resources destroyed successfully in {fmt_duration(elapsed)}")


# --- CLI ---

COMMANDS = {
    "deploy_all": deploy_all,
    "destroy_all": destroy_all,
    "check_prerequisites": check_prerequisites,
    "deploy_infra": deploy_infra,
    "deploy_k8s": deploy_k8s,
    "setup_kubeconfig": setup_kubeconfig,
    "deploy_custom_ca_secret": deploy_custom_ca_secret,
    "extract_openstack_ca_cert": extract_openstack_ca_cert,
    "deploy_ccm": deploy_ccm,
    "remove_floating_ips": remove_floating_ips,
    "verify_cluster": verify_cluster,
    "cluster_access": cluster_access,
    "remove_from_known_hosts": remove_from_known_hosts,
}


def main():
    load_env()
    os.chdir(ROOT)

    args = sys.argv[1:]
    if not args:
        show_help()
        sys.exit(0)

    command = args[0]
    if command in ("-h", "--help", "help"):
        show_help()
        sys.exit(0)

    func = COMMANDS.get(command)
    if not func:
        print_error(f"xctl:Unknown command '{command}'")
        show_help()
        sys.exit(1)

    func()


if __name__ == "__main__":
    main()
