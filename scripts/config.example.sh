#!/bin/bash
# =============================================================================
# Configuration for PostgreSQL HA Test Scripts
# =============================================================================
# Shared configuration used by all test scripts.
# Run from the project root directory.
#
# SETUP:
# 1. Copy this file to config.sh: cp config.example.sh config.sh
# 2. Edit config.sh with your local paths
# 3. config.sh is gitignored - your local settings won't be committed
# =============================================================================

set -e

# =============================================================================
# Colors for terminal output
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_action() {
    echo -e "${CYAN}[ACTION]${NC} $1"
}

log_wait() {
    echo -e "${YELLOW}[WAIT]${NC} $1"
}

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# =============================================================================
# CONFIGURE THESE VALUES FOR YOUR ENVIRONMENT
# =============================================================================
# SSH Key path - Git Bash on Windows uses /c/ prefix
# Example Windows: /c/Users/yourname/path/to/your-key.pem
# Example Linux/Mac: /home/yourname/.ssh/your-key.pem
SSH_KEY_PATH="/c/Users/YOUR_USERNAME/path/to/your-aws-key.pem"

# AWS CLI profile and region (must match terraform configuration)
AWS_PROFILE="postgresql-ha-profile"
AWS_REGION="us-east-1"
# =============================================================================

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15"

# Get Terraform output
get_terraform_output() {
    local output_name="$1"
    cd "$TERRAFORM_DIR"
    terraform output -raw "$output_name" 2>/dev/null
}

# Get Terraform JSON output
get_terraform_output_json() {
    local output_name="$1"
    cd "$TERRAFORM_DIR"
    terraform output -json "$output_name" 2>/dev/null
}

# Get NLB DNS
get_nlb_dns() {
    get_terraform_output "nlb_dns_name"
}

# Get Bastion public IP
get_bastion_ip() {
    get_terraform_output "bastion_public_ip"
}

# Get Patroni private IPs as array (no jq dependency)
get_patroni_ips() {
    get_terraform_output_json "patroni_private_ips" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

# Get etcd private IPs as array (no jq dependency)
get_etcd_ips() {
    get_terraform_output_json "etcd_private_ips" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

# Run SSH command via bastion to internal node
ssh_via_bastion() {
    local target_ip="$1"
    local command="$2"
    local bastion_ip=$(get_bastion_ip)

    # Use ProxyCommand to explicitly pass key to both bastion and target
    ssh $SSH_OPTS \
        -o "ProxyCommand=ssh $SSH_OPTS -i \"$SSH_KEY_PATH\" -W %h:%p ec2-user@$bastion_ip" \
        -i "$SSH_KEY_PATH" \
        "ec2-user@$target_ip" "$command"
}

# Run SSH command directly to bastion
ssh_to_bastion() {
    local command="$1"
    local bastion_ip=$(get_bastion_ip)

    ssh $SSH_OPTS -i "$SSH_KEY_PATH" "ec2-user@$bastion_ip" "$command"
}

log_info "Config loaded. Project: $PROJECT_ROOT"
