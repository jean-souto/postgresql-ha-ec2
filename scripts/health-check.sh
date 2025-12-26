#!/bin/bash
# =============================================================================
# Health Check Script
# =============================================================================
# Checks the status of the PostgreSQL HA cluster.
# Shows Patroni cluster status, etcd health, and NLB connectivity.
#
# Usage: ./scripts/health-check.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo ""
echo "========================================"
echo " PostgreSQL HA Cluster Health Check"
echo "========================================"
echo ""

# Get infrastructure info
NLB_DNS=$(get_nlb_dns)
BASTION_IP=$(get_bastion_ip)
PATRONI_IPS=($(get_patroni_ips))
ETCD_IPS=($(get_etcd_ips))

echo "[INFO] NLB DNS: $NLB_DNS"
echo "[INFO] Bastion IP: $BASTION_IP"
echo "[INFO] Patroni IPs: ${PATRONI_IPS[*]}"
echo "[INFO] etcd IPs: ${ETCD_IPS[*]}"
echo ""

# Check etcd cluster health
echo "--- etcd Cluster Status ---"
ETCD_IP="${ETCD_IPS[0]}"
echo "[INFO] Checking etcd via $ETCD_IP..."

if etcd_status=$(ssh_via_bastion "$ETCD_IP" "etcdctl endpoint status --cluster -w table 2>/dev/null"); then
    echo "$etcd_status"
else
    echo "[WARN] Could not connect to etcd. Instance may still be bootstrapping."
fi
echo ""

# Check Patroni cluster status
echo "--- Patroni Cluster Status ---"
PATRONI_IP="${PATRONI_IPS[0]}"
echo "[INFO] Checking Patroni via $PATRONI_IP..."

if patroni_status=$(ssh_via_bastion "$PATRONI_IP" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
    echo "$patroni_status"
else
    echo "[WARN] Could not connect to Patroni. Instance may still be bootstrapping."
fi
echo ""

# Check NLB connectivity (via bastion since NLB is internal)
echo "--- NLB Connectivity ---"
echo "[INFO] Testing PostgreSQL connection via NLB (from bastion)..."

if nlb_test=$(ssh_to_bastion "timeout 5 bash -c '</dev/tcp/$NLB_DNS/5432' 2>/dev/null && echo 'OK' || echo 'FAIL'"); then
    if [[ "$nlb_test" == *"OK"* ]]; then
        echo "[OK] NLB port 5432 is reachable"
    else
        echo "[WARN] NLB port 5432 not reachable yet (health checks may still be pending)"
    fi
else
    echo "[WARN] Could not test NLB connectivity"
fi

echo ""
echo "========================================"
echo " Health check complete"
echo "========================================"
echo ""
echo "Next steps:"
echo "  - If cluster not ready, wait 5-10 minutes and try again"
echo "  - Run ./scripts/insert-loop.sh to test writes"
echo "  - Run ./scripts/chaos-test.sh to test failover"
