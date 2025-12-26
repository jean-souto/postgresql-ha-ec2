#!/bin/bash
# =============================================================================
# Create PostgreSQL HA Cluster
# =============================================================================
# Creates (or recreates) all infrastructure from Terraform.
#
# Usage:
#   ./create-cluster.sh              # Interactive (asks confirmation)
#   ./create-cluster.sh --force      # Skip confirmation
#
# Requirements:
#   - Terraform installed and in PATH
#   - AWS credentials configured (profile: postgresql-ha-profile)
#   - config.sh configured (for health verification)
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
FORCE=false
for arg in "$@"; do
    case $arg in
        --force|-f)
            FORCE=true
            ;;
        --help|-h)
            echo "Usage: $0 [--force]"
            echo ""
            echo "Options:"
            echo "  --force, -f  Skip confirmation prompt"
            exit 0
            ;;
    esac
done

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# -----------------------------------------------------------------------------
# Wait Functions
# -----------------------------------------------------------------------------

wait_for_instances() {
    local max_attempts=30
    local attempt=1
    local wait_seconds=20

    log_info "Waiting for instances to be ready (SSM connectivity)..."

    while [[ $attempt -le $max_attempts ]]; do
        cd "$TERRAFORM_DIR"
        local patroni_ids=$(terraform output -json patroni_instance_ids 2>/dev/null | grep -oE 'i-[a-z0-9]+' || true)

        if [[ -z "$patroni_ids" ]]; then
            log_warn "Waiting for Terraform outputs... (attempt $attempt/$max_attempts)"
            sleep $wait_seconds
            ((attempt++))
            continue
        fi

        local first_id=$(echo "$patroni_ids" | head -1)
        local ssm_status=$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$first_id" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text \
            --profile postgresql-ha-profile 2>/dev/null || echo "Unknown")

        if [[ "$ssm_status" == "Online" ]]; then
            log_success "Instances are ready (SSM Online)"
            return 0
        fi

        log_info "Waiting for SSM... (attempt $attempt/$max_attempts, status: $ssm_status)"
        sleep $wait_seconds
        ((attempt++))
    done

    log_warn "Timeout waiting for SSM. Instances may still be starting."
    return 0
}

wait_for_patroni() {
    local max_attempts=20
    local attempt=1
    local wait_seconds=15

    log_info "Waiting for Patroni cluster to form..."

    while [[ $attempt -le $max_attempts ]]; do
        cd "$TERRAFORM_DIR"
        local patroni_id=$(terraform output -json patroni_instance_ids 2>/dev/null | grep -oE 'i-[a-z0-9]+' | head -1 || true)

        if [[ -z "$patroni_id" ]]; then
            sleep $wait_seconds
            ((attempt++))
            continue
        fi

        local cmd_id=$(aws ssm send-command \
            --instance-ids "$patroni_id" \
            --document-name "AWS-RunShellScript" \
            --parameters 'commands=["curl -s http://localhost:8008/patroni 2>/dev/null || echo ERROR"]' \
            --output text \
            --query 'Command.CommandId' \
            --profile postgresql-ha-profile 2>/dev/null || true)

        if [[ -n "$cmd_id" ]]; then
            sleep 3
            local result=$(aws ssm get-command-invocation \
                --command-id "$cmd_id" \
                --instance-id "$patroni_id" \
                --query 'StandardOutputContent' \
                --output text \
                --profile postgresql-ha-profile 2>/dev/null || echo "ERROR")

            if [[ "$result" != *"ERROR"* ]] && [[ "$result" == *"running"* ]]; then
                log_success "Patroni is running"
                return 0
            fi
        fi

        log_info "Waiting for Patroni... (attempt $attempt/$max_attempts)"
        sleep $wait_seconds
        ((attempt++))
    done

    log_warn "Patroni may not be fully ready. Run ./scripts/health-check.sh to verify."
    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

echo ""
echo "=========================================="
echo " PostgreSQL HA Cluster - CREATE"
echo "=========================================="
echo ""

cd "$TERRAFORM_DIR"

# Check Terraform is initialized
if [[ ! -d ".terraform" ]]; then
    log_info "Initializing Terraform..."
    terraform init -input=false
fi

# Show plan summary
log_info "Planning infrastructure..."
terraform plan -out=tfplan -input=false > /dev/null 2>&1 || true

PLAN_SUMMARY=$(terraform show -no-color tfplan 2>/dev/null | grep -E "Plan:|No changes" | head -1 || echo "Plan ready")
echo "$PLAN_SUMMARY"
echo ""

# Confirmation
if [[ "$FORCE" != "true" ]]; then
    echo -e "${YELLOW}This will create/update the PostgreSQL HA infrastructure.${NC}"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warn "Aborted. No changes made."
        rm -f tfplan
        exit 1
    fi
fi

# Apply
log_info "Creating infrastructure..."
START_TIME=$(date +%s)

terraform apply -auto-approve tfplan
rm -f tfplan

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log_success "Terraform apply completed in ${DURATION}s"

# Wait for services
echo ""
wait_for_instances
echo ""
wait_for_patroni

# Show connection info
echo ""
echo "=========================================="
echo -e "${GREEN}Infrastructure Created Successfully!${NC}"
echo "=========================================="
echo ""

cd "$TERRAFORM_DIR"
BASTION_IP=$(terraform output -raw bastion_public_ip 2>/dev/null || echo "N/A")
NLB_DNS=$(terraform output -raw nlb_dns_name 2>/dev/null || echo "N/A")

echo "Bastion IP:  $BASTION_IP"
echo "NLB DNS:     $NLB_DNS"
echo ""
echo "Commands:"
echo "  # SSH to Bastion"
echo "  ssh -i \"\$SSH_KEY\" ec2-user@$BASTION_IP"
echo ""
echo "  # PostgreSQL (from Bastion)"
echo "  psql -h $NLB_DNS -p 5432 -U postgres  # R/W (Primary)"
echo "  psql -h $NLB_DNS -p 5433 -U postgres  # RO (Replicas)"
echo ""
echo "  # Health check"
echo "  ./scripts/health-check.sh"
echo ""
echo "=========================================="
echo "  Create time: ${DURATION}s"
echo "=========================================="
echo ""
