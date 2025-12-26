#!/bin/bash
# =============================================================================
# Monitor Cluster Script
# =============================================================================
# Continuously monitors the PostgreSQL HA cluster status.
# Updates every 2 seconds showing Patroni cluster state.
#
# Usage: ./scripts/monitor-cluster.sh
# Press Ctrl+C to stop
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo ""
echo "========================================"
echo " PostgreSQL HA Cluster Monitor"
echo "========================================"
echo ""
echo "Press Ctrl+C to stop monitoring"
echo ""

# Get infrastructure info
PATRONI_IPS=($(get_patroni_ips))
NLB_DNS=$(get_nlb_dns)
BASTION_IP=$(get_bastion_ip)

REFRESH_INTERVAL=2

while true; do
    clear

    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

    echo "========================================"
    echo " PostgreSQL HA Cluster Monitor"
    echo " $TIMESTAMP"
    echo "========================================"
    echo ""
    echo "NLB: $NLB_DNS"
    echo ""

    # Try to get status from any responding node
    GOT_STATUS=false

    for ip in "${PATRONI_IPS[@]}"; do
        if status=$(ssh_via_bastion "$ip" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
            if [[ -n "$status" ]] && [[ "$status" != *"not ready"* ]]; then
                echo "--- Patroni Cluster ---"
                echo "$status"
                GOT_STATUS=true
                break
            fi
        fi
    done

    if [[ "$GOT_STATUS" == "false" ]]; then
        echo "[WARN] Could not get cluster status. Cluster may be bootstrapping..."
    fi

    echo ""
    echo "--- Connection Test (via bastion) ---"

    # Test NLB connection via bastion
    test_5432=$(ssh_to_bastion "timeout 2 bash -c '</dev/tcp/$NLB_DNS/5432' 2>/dev/null && echo 'OK' || echo 'FAIL'")
    if [[ "$test_5432" == *"OK"* ]]; then
        echo "[OK] NLB :5432 reachable"
    else
        echo "[--] NLB :5432 not reachable"
    fi

    # Test read-only port via bastion
    test_5433=$(ssh_to_bastion "timeout 2 bash -c '</dev/tcp/$NLB_DNS/5433' 2>/dev/null && echo 'OK' || echo 'FAIL'")
    if [[ "$test_5433" == *"OK"* ]]; then
        echo "[OK] NLB :5433 (read-only) reachable"
    else
        echo "[--] NLB :5433 (read-only) not reachable"
    fi

    echo ""
    echo "Refreshing in $REFRESH_INTERVAL seconds... (Ctrl+C to stop)"

    sleep $REFRESH_INTERVAL
done
