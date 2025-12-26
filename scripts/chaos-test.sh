#!/bin/bash
# =============================================================================
# Chaos Test Script
# =============================================================================
# Tests PostgreSQL HA failover by killing the primary node.
# Run insert-loop.sh in another terminal to observe behavior.
#
# Usage: ./scripts/chaos-test.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo ""
echo "========================================"
echo " PostgreSQL HA Chaos Test"
echo "========================================"
echo ""

# Get infrastructure info
BASTION_IP=$(get_bastion_ip)
PATRONI_IPS=($(get_patroni_ips))

echo "[INFO] Patroni IPs: ${PATRONI_IPS[*]}"
echo ""

# Find current leader
echo "[INFO] Finding current cluster leader..."

LEADER_IP=""
LEADER_NAME=""
CLUSTER_OUTPUT=""

for ip in "${PATRONI_IPS[@]}"; do
    if CLUSTER_OUTPUT=$(ssh_via_bastion "$ip" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
        # Parse text output: find line with "Leader" and extract the member name
        LEADER_NAME=$(echo "$CLUSTER_OUTPUT" | grep -E '\|\s*Leader\s*\|' | awk -F'|' '{print $2}' | tr -d ' ')
        if [[ -n "$LEADER_NAME" ]]; then
            # Extract index from name (e.g., pgha-dev-patroni-1 -> 0)
            LEADER_IDX=$(echo "$LEADER_NAME" | grep -oE '[0-9]+$')
            LEADER_IDX=$((LEADER_IDX - 1))
            LEADER_IP="${PATRONI_IPS[$LEADER_IDX]}"
            break
        fi
    fi
done

if [[ -z "$LEADER_IP" ]]; then
    echo "[ERROR] Could not find cluster leader. Is the cluster running?"
    exit 1
fi

echo "[OK] Current leader: $LEADER_NAME ($LEADER_IP)"
echo ""

# Show cluster status before
echo "--- Cluster Status BEFORE Chaos ---"
ssh_via_bastion "${PATRONI_IPS[0]}" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"
echo ""

# Menu
echo "Select chaos action:"
echo "  1. Stop Patroni service (graceful)"
echo "  2. Kill PostgreSQL process (crash)"
echo "  3. Patroni failover command (planned)"
echo "  4. Just monitor (no chaos)"
echo ""

read -p "Enter choice (1-4): " choice

case $choice in
    1)
        echo ""
        echo "[ACTION] Stopping Patroni on $LEADER_NAME..."
        ssh_via_bastion "$LEADER_IP" "sudo systemctl stop patroni"
        echo "[OK] Patroni stopped. Failover should occur in ~10-30 seconds."
        ;;
    2)
        echo ""
        echo "[ACTION] Killing PostgreSQL on $LEADER_NAME..."
        ssh_via_bastion "$LEADER_IP" "sudo pkill -9 postgres"
        echo "[OK] PostgreSQL killed. Patroni should restart it or trigger failover."
        ;;
    3)
        echo ""
        echo "[ACTION] Triggering Patroni failover..."

        # Get candidate (first replica) - parse text output
        CANDIDATE=$(echo "$CLUSTER_OUTPUT" | grep -E '\|\s*(Replica|Sync Standby)\s*\|' | head -1 | awk -F'|' '{print $2}' | tr -d ' ')

        if [[ -n "$CANDIDATE" ]]; then
            echo "[INFO] Failing over to $CANDIDATE..."
            ssh_via_bastion "${PATRONI_IPS[0]}" "sudo patronictl -c /etc/patroni/patroni.yml failover --candidate $CANDIDATE --force 2>/dev/null"
        else
            ssh_via_bastion "${PATRONI_IPS[0]}" "sudo patronictl -c /etc/patroni/patroni.yml failover --force 2>/dev/null"
        fi
        echo "[OK] Failover initiated."
        ;;
    4)
        echo ""
        echo "[INFO] Monitor mode - no chaos action taken."
        ;;
    *)
        echo "[ERROR] Invalid choice."
        exit 1
        ;;
esac

# Wait and show status after
if [[ "$choice" != "4" ]]; then
    echo ""
    echo "[INFO] Waiting 15 seconds for failover..."

    for i in $(seq 15 -1 1); do
        echo -ne "\r[WAIT] $i seconds remaining..."
        sleep 1
    done
    echo ""
fi

echo ""
echo "--- Cluster Status AFTER Chaos ---"

# Try each IP until one responds
for ip in "${PATRONI_IPS[@]}"; do
    if status_after=$(ssh_via_bastion "$ip" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
        echo "$status_after"
        break
    fi
done

echo ""
echo "========================================"
echo " Chaos test complete"
echo "========================================"

if [[ "$choice" == "1" ]]; then
    echo ""
    echo "To restore the stopped node (via bastion):"
    echo "  ssh -J ec2-user@$BASTION_IP -i \"$SSH_KEY_PATH\" ec2-user@$LEADER_IP"
    echo "  sudo systemctl start patroni"
fi
