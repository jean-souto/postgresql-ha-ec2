#!/bin/bash
# =============================================================================
# Insert Loop Script
# =============================================================================
# Continuously inserts data into PostgreSQL via NLB to test HA.
# Run this in one terminal while running chaos-test.sh in another.
#
# Usage: ./scripts/insert-loop.sh
# Press Ctrl+C to stop
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo ""
echo "========================================"
echo " PostgreSQL HA Insert Loop Test"
echo "========================================"
echo ""

# Get NLB DNS and Bastion IP
NLB_DNS=$(get_nlb_dns)
BASTION_IP=$(get_bastion_ip)

echo "[INFO] NLB: $NLB_DNS"
echo "[INFO] Connecting via bastion: $BASTION_IP"
echo ""

# Get postgres password from SSM (via bastion)
echo "[INFO] Retrieving postgres password..."
PG_PASSWORD=$(ssh_to_bastion "aws ssm get-parameter --name /pgha/postgres-password --with-decryption --query Parameter.Value --output text 2>/dev/null")

if [[ -z "$PG_PASSWORD" ]]; then
    echo "[ERROR] Failed to retrieve postgres password from SSM"
    exit 1
fi

# Create table if not exists
echo "[INFO] Creating table if not exists..."
CREATE_RESULT=$(ssh_to_bastion "PGPASSWORD='$PG_PASSWORD' psql -h '$NLB_DNS' -U postgres -c 'CREATE TABLE IF NOT EXISTS test_ha (id SERIAL PRIMARY KEY, ts TIMESTAMP DEFAULT NOW(), data TEXT)' 2>&1")

if [[ "$CREATE_RESULT" == *"CREATE TABLE"* ]] || [[ "$CREATE_RESULT" == *"already exists"* ]]; then
    echo "[OK] Table ready"
else
    echo "[WARN] Table creation result: $CREATE_RESULT"
fi

echo ""
echo "[INFO] Starting insert loop via bastion -> NLB..."
echo "[INFO] Press Ctrl+C to stop"
echo ""

# Run insert loop on bastion with TTY for live output
ssh -t $SSH_OPTS -i "$SSH_KEY_PATH" "ec2-user@$BASTION_IP" bash -c "'
export PGPASSWORD=\"$PG_PASSWORD\"
NLB=\"$NLB_DNS\"
counter=0
while true; do
    counter=\$((counter + 1))
    ts=\$(date \"+%Y-%m-%d %H:%M:%S\")
    result=\$(psql -h \"\$NLB\" -U postgres -t -c \"INSERT INTO test_ha (data) VALUES (\"insert-\$counter\") RETURNING id\" 2>&1)
    if [ \$? -eq 0 ]; then
        id=\$(echo \"\$result\" | tr -d \" \")
        echo \"[\$ts] INSERT #\$counter -> id=\$id\"
    else
        echo \"[\$ts] INSERT #\$counter FAILED: \$result\"
    fi
    sleep 1
done
'"
