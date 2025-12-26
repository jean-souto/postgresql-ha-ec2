#!/bin/bash
# =============================================================================
# Verify Data Script
# =============================================================================
# Verifies data integrity after failover tests.
# Shows row counts, latest entries, and any gaps in the sequence.
#
# Usage: ./scripts/verify-data.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo ""
echo "========================================"
echo " PostgreSQL HA Data Verification"
echo "========================================"
echo ""

# Get Patroni IPs
PATRONI_IPS=($(get_patroni_ips))
PATRONI_IP="${PATRONI_IPS[0]}"

echo "[INFO] Connecting via Patroni node ($PATRONI_IP)"
echo ""

# Check if table exists
TABLE_CHECK=$(ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -t -c '\dt test_ha' 2>/dev/null")

if [[ -z "$TABLE_CHECK" ]] || [[ "$TABLE_CHECK" != *"test_ha"* ]]; then
    echo "[WARN] Table 'test_ha' does not exist. Run insert-loop.sh first."
    exit 0
fi

# Get max ID (row count approximation)
echo "--- Data Statistics ---"
MAX_ID=$(ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -t -c 'SELECT COALESCE(MAX(id), 0) FROM test_ha' 2>/dev/null" | tr -d ' ')
TOTAL_ROWS=$(ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -t -c 'SELECT COUNT(*) FROM test_ha' 2>/dev/null" | tr -d ' ')

echo "Max ID:      $MAX_ID"
echo "Total Rows:  $TOTAL_ROWS"

# Check for gaps
if [[ "$MAX_ID" != "$TOTAL_ROWS" ]]; then
    GAPS=$((MAX_ID - TOTAL_ROWS))
    echo "Gaps:        $GAPS (some inserts may have failed during failover)"
else
    echo "Gaps:        None (all sequential)"
fi
echo ""

# Get last 10 entries
echo "--- Last 10 Entries ---"
ssh_via_bastion "$PATRONI_IP" "sudo -u postgres psql -c 'SELECT * FROM test_ha ORDER BY id DESC LIMIT 10' 2>/dev/null"

echo ""
echo "========================================"
echo " Verification complete"
echo "========================================"
