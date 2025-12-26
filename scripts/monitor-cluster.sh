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
echo -e "${BOLD}========================================${NC}"
echo -e "${BOLD} PostgreSQL HA Cluster Monitor${NC}"
echo -e "${BOLD}========================================${NC}"
echo ""
log_info "Press Ctrl+C to stop monitoring"
echo ""

# Get infrastructure info
PATRONI_IPS=($(get_patroni_ips))
NLB_DNS=$(get_nlb_dns)
BASTION_IP=$(get_bastion_ip)

REFRESH_INTERVAL=2

while true; do
    clear

    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD} PostgreSQL HA Cluster Monitor${NC}"
    echo -e " ${CYAN}$TIMESTAMP${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""
    echo -e "NLB: ${CYAN}$NLB_DNS${NC}"
    echo ""

    # Try to get status from any responding node
    GOT_STATUS=false

    for ip in "${PATRONI_IPS[@]}"; do
        if status=$(ssh_via_bastion "$ip" "sudo patronictl -c /etc/patroni/patroni.yml list 2>/dev/null"); then
            if [[ -n "$status" ]] && [[ "$status" != *"not ready"* ]]; then
                echo -e "${CYAN}--- Patroni Cluster ---${NC}"
                echo "$status"
                GOT_STATUS=true
                break
            fi
        fi
    done

    if [[ "$GOT_STATUS" == "false" ]]; then
        log_warn "Could not get cluster status. Cluster may be bootstrapping..."
    fi

    echo ""
    echo -e "${CYAN}--- Connection Test (via bastion) ---${NC}"

    # Test NLB connection via bastion
    test_5432=$(ssh_to_bastion "timeout 2 bash -c '</dev/tcp/$NLB_DNS/5432' 2>/dev/null && echo 'OK' || echo 'FAIL'")
    if [[ "$test_5432" == *"OK"* ]]; then
        echo -e "${GREEN}[OK]${NC} NLB :5432 reachable"
    else
        echo -e "${RED}[--]${NC} NLB :5432 not reachable"
    fi

    # Test read-only port via bastion
    test_5433=$(ssh_to_bastion "timeout 2 bash -c '</dev/tcp/$NLB_DNS/5433' 2>/dev/null && echo 'OK' || echo 'FAIL'")
    if [[ "$test_5433" == *"OK"* ]]; then
        echo -e "${GREEN}[OK]${NC} NLB :5433 (read-only) reachable"
    else
        echo -e "${RED}[--]${NC} NLB :5433 (read-only) not reachable"
    fi

    echo ""
    echo -e "${YELLOW}Refreshing in $REFRESH_INTERVAL seconds... (Ctrl+C to stop)${NC}"

    sleep $REFRESH_INTERVAL
done
