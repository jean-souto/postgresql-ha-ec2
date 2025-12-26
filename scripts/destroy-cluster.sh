#!/bin/bash
# =============================================================================
# Destroy PostgreSQL HA Cluster
# =============================================================================
# Destroys all infrastructure. Use to save costs when not testing.
#
# Usage:
#   ./destroy-cluster.sh              # Interactive (asks confirmation)
#   ./destroy-cluster.sh --force      # Skip confirmation
#
# Requirements:
#   - Terraform installed and in PATH
#   - AWS credentials configured (profile: postgresql-ha-profile)
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

echo ""
echo "=========================================="
echo " PostgreSQL HA Cluster - DESTROY"
echo "=========================================="
echo ""

cd "$TERRAFORM_DIR"

# Check Terraform is initialized
if [[ ! -d ".terraform" ]]; then
    log_info "Initializing Terraform..."
    terraform init -input=false
fi

# Check if there's infrastructure to destroy
if ! terraform state list 2>/dev/null | grep -q .; then
    log_info "No infrastructure to destroy (state is empty)"
    exit 0
fi

# Show what will be destroyed
log_info "Resources to be destroyed:"
terraform state list 2>/dev/null | head -20
RESOURCE_COUNT=$(terraform state list 2>/dev/null | wc -l)
echo "... ($RESOURCE_COUNT resources total)"
echo ""

# Confirmation
if [[ "$FORCE" != "true" ]]; then
    echo -e "${RED}WARNING: This will DESTROY all infrastructure!${NC}"
    echo -e "${RED}All data will be permanently lost!${NC}"
    echo ""
    read -p "Type 'destroy' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "destroy" ]]; then
        log_warn "Aborted. No changes made."
        exit 1
    fi
fi

# Destroy
log_info "Destroying infrastructure..."
START_TIME=$(date +%s)

terraform destroy -auto-approve

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "=========================================="
log_success "Infrastructure destroyed in ${DURATION}s"
echo "=========================================="
echo ""
echo "To recreate: ./scripts/create-cluster.sh"
echo ""
