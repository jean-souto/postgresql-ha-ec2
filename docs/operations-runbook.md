# Operations Runbook

> **[English](#english)** | **[Português](#portugues)**

---

<a name="english"></a>
## English

Operational procedures for the PostgreSQL HA cluster on AWS EC2.

## Quick Reference Card

| Action | Command |
|--------|---------|
| Check cluster health | `./scripts/health-check.sh` |
| Run failover tests | `./scripts/chaos-test.sh` |
| Monitor in real-time | `./scripts/monitor-cluster.sh` |
| View Patroni status | `patronictl -c /etc/patroni/patroni.yml list` |
| Manual switchover | `patronictl -c /etc/patroni/patroni.yml switchover` |

---

## Cluster Health Checks

### Check Overall Health

```bash
./scripts/health-check.sh
```

### Check etcd Cluster

```bash
# SSH to any etcd node
etcdctl endpoint health --cluster
etcdctl member list
etcdctl endpoint status --cluster --write-out=table
```

Expected healthy output:
```
+---------------------------+--------+------------+-------+
|         ENDPOINT          | HEALTH |    TOOK    | ERROR |
+---------------------------+--------+------------+-------+
| http://10.0.1.10:2379     |   true |  5.12345ms |       |
| http://10.0.1.11:2379     |   true |  5.23456ms |       |
| http://10.0.1.12:2379     |   true |  5.34567ms |       |
+---------------------------+--------+------------+-------+
```

### Check Patroni Cluster

```bash
# SSH to any Patroni node
patronictl -c /etc/patroni/patroni.yml list
```

Expected healthy output:
```
+ Cluster: pgha-cluster (7428392847291234) ----+
| Member    | Host       | Role    | State     |
+-----------+------------+---------+-----------+
| patroni-1 | 10.0.1.20  | Leader  | running   |
| patroni-2 | 10.0.1.21  | Replica | streaming |
| patroni-3 | 10.0.1.22  | Replica | streaming |
+-----------+------------+---------+-----------+
```

### Check Replication Lag

```bash
# Connect to Primary
psql -h <NLB_DNS> -p 5432 -U postgres -c "
SELECT
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;"
```

Healthy: `lag_bytes` should be close to 0 (< 1MB).

---

## Failover Procedures

### Automatic Failover (Normal Operation)

The cluster handles failover automatically. When the primary fails:

1. **T+0s**: Primary becomes unavailable
2. **T+10s**: NLB health check fails, Patroni detects via etcd TTL
3. **T+12s**: Replica acquires leader lock
4. **T+15s**: Patroni promotes replica (`pg_ctl promote`)
5. **T+20s**: NLB routes traffic to new primary

**No action required** - just monitor:

```bash
./scripts/monitor-cluster.sh
```

### Planned Switchover

For maintenance or testing, use Patroni's switchover:

```bash
# SSH to any Patroni node
patronictl -c /etc/patroni/patroni.yml switchover

# Follow prompts:
# 1. Confirm current leader
# 2. Select candidate (or leave blank for automatic)
# 3. Confirm switchover
```

### Manual Failover (Force)

Use when automatic failover is stuck:

```bash
# SSH to any Patroni node
patronictl -c /etc/patroni/patroni.yml failover --force

# This bypasses safety checks - use only when necessary
```

### Reinitialize Failed Node

When a node fails to rejoin:

```bash
# SSH to the failed node
patronictl -c /etc/patroni/patroni.yml reinit pgha-cluster patroni-1

# Confirm when prompted
```

This will:
1. Stop PostgreSQL
2. Delete data directory
3. Clone from current primary
4. Start as replica

---

## Common Operations

### View Patroni Logs

```bash
# SSH to Patroni node
sudo journalctl -u patroni -f

# Last 100 lines
sudo journalctl -u patroni -n 100

# Since specific time
sudo journalctl -u patroni --since "1 hour ago"
```

### View PostgreSQL Logs

```bash
# SSH to Patroni node
sudo tail -f /var/lib/pgsql/17/data/log/postgresql-*.log
```

### Restart Patroni Service

```bash
# SSH to Patroni node
sudo systemctl restart patroni

# Check status
sudo systemctl status patroni
```

### Check PgBouncer

```bash
# SSH to Patroni node (PgBouncer runs on each node)
sudo -u pgbouncer psql -p 6432 -U pgbouncer pgbouncer -c "SHOW POOLS;"
sudo -u pgbouncer psql -p 6432 -U pgbouncer pgbouncer -c "SHOW STATS;"
```

### Update PostgreSQL Configuration

Patroni manages PostgreSQL configuration. To change settings:

```bash
# SSH to any Patroni node
patronictl -c /etc/patroni/patroni.yml edit-config

# Editor opens with YAML config
# Make changes and save
# Patroni applies changes across cluster
```

---

## Incident Response

### Priority Levels

| Priority | Description | Response Time | Example |
|----------|-------------|---------------|---------|
| P1 | Complete outage | Immediate | All nodes down |
| P2 | Degraded (1 node down) | 15 min | Replica failed |
| P3 | Warning | 1 hour | High replication lag |
| P4 | Informational | Next business day | Disk 70% full |

### P1: Complete Outage

**Symptoms:**
- NLB shows 0 healthy targets
- Application cannot connect to PostgreSQL
- All Patroni nodes show as failed

**Steps:**

1. **Check AWS infrastructure:**
   ```bash
   aws ec2 describe-instances \
     --filters "Name=tag:Project,Values=postgresql-ha-ec2" \
     --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
     --profile postgresql-ha-profile
   ```

2. **Check etcd cluster:**
   ```bash
   etcdctl endpoint health --cluster
   ```

3. **If etcd is down:** Restart etcd on all nodes:
   ```bash
   sudo systemctl restart etcd
   ```

4. **If Patroni is down:** Restart Patroni:
   ```bash
   sudo systemctl restart patroni
   ```

### P2: Single Node Failure

**Symptoms:**
- 2/3 Patroni nodes healthy
- Cluster still operational
- One target unhealthy in NLB

**Steps:**

1. **Identify failed node:**
   ```bash
   patronictl -c /etc/patroni/patroni.yml list
   ```

2. **SSH and check logs:**
   ```bash
   sudo journalctl -u patroni -n 100
   ```

3. **If Patroni crashed:** Restart:
   ```bash
   sudo systemctl restart patroni
   ```

4. **If data corruption:** Reinitialize:
   ```bash
   patronictl -c /etc/patroni/patroni.yml reinit pgha-cluster <node-name>
   ```

---

## Maintenance Windows

### Planned Maintenance Procedure

1. **Notify stakeholders** (if production)

2. **Switch to maintenance mode:**
   ```bash
   sudo -u pgbouncer psql -p 6432 pgbouncer -c "PAUSE;"
   ```

3. **Drain connections:**
   ```bash
   sudo -u pgbouncer psql -p 6432 pgbouncer -c "SHOW CLIENTS;"
   ```

4. **Perform maintenance**

5. **Resume operations:**
   ```bash
   sudo -u pgbouncer psql -p 6432 pgbouncer -c "RESUME;"
   ```

### Rolling Restart

To restart all nodes without downtime:

1. **Restart replicas first:**
   ```bash
   sudo systemctl restart patroni
   patronictl list
   ```

2. **Switchover to a replica:**
   ```bash
   patronictl switchover
   ```

3. **Restart old primary (now replica):**
   ```bash
   sudo systemctl restart patroni
   ```

---

<a name="portugues"></a>
## Português

Procedimentos operacionais para o cluster PostgreSQL HA na AWS EC2.

## Cartão de Referência Rápida

| Ação | Comando |
|------|---------|
| Verificar saúde do cluster | `./scripts/health-check.sh` |
| Executar testes de failover | `./scripts/chaos-test.sh` |
| Monitorar em tempo real | `./scripts/monitor-cluster.sh` |
| Ver status Patroni | `patronictl -c /etc/patroni/patroni.yml list` |
| Switchover manual | `patronictl -c /etc/patroni/patroni.yml switchover` |

---

## Verificações de Saúde

### Verificar Saúde Geral

```bash
./scripts/health-check.sh
```

### Verificar Cluster etcd

```bash
# SSH para qualquer nó etcd
etcdctl endpoint health --cluster
etcdctl member list
etcdctl endpoint status --cluster --write-out=table
```

### Verificar Cluster Patroni

```bash
# SSH para qualquer nó Patroni
patronictl -c /etc/patroni/patroni.yml list
```

### Verificar Lag de Replicação

```bash
# Conectar ao Primary
psql -h <NLB_DNS> -p 5432 -U postgres -c "
SELECT
    client_addr,
    state,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;"
```

Saudável: `lag_bytes` deve estar próximo de 0 (< 1MB).

---

## Procedimentos de Failover

### Failover Automático (Operação Normal)

O cluster lida com failover automaticamente. Quando o primary falha:

1. **T+0s**: Primary fica indisponível
2. **T+10s**: Health check NLB falha, Patroni detecta via TTL etcd
3. **T+12s**: Replica adquire leader lock
4. **T+15s**: Patroni promove replica (`pg_ctl promote`)
5. **T+20s**: NLB roteia tráfego para novo primary

**Nenhuma ação necessária** - apenas monitore:

```bash
./scripts/monitor-cluster.sh
```

### Switchover Planejado

Para manutenção ou testes, use o switchover do Patroni:

```bash
# SSH para qualquer nó Patroni
patronictl -c /etc/patroni/patroni.yml switchover

# Siga os prompts:
# 1. Confirme o líder atual
# 2. Selecione candidato (ou deixe em branco para automático)
# 3. Confirme switchover
```

### Failover Manual (Forçado)

Use quando failover automático está travado:

```bash
# SSH para qualquer nó Patroni
patronictl -c /etc/patroni/patroni.yml failover --force

# Isto ignora verificações de segurança - use apenas quando necessário
```

### Reinicializar Nó com Falha

Quando um nó não consegue reintegrar:

```bash
# SSH para o nó com falha
patronictl -c /etc/patroni/patroni.yml reinit pgha-cluster patroni-1

# Confirme quando solicitado
```

Isto irá:
1. Parar PostgreSQL
2. Deletar diretório de dados
3. Clonar do primary atual
4. Iniciar como replica

---

## Operações Comuns

### Ver Logs do Patroni

```bash
# SSH para nó Patroni
sudo journalctl -u patroni -f

# Últimas 100 linhas
sudo journalctl -u patroni -n 100

# Desde horário específico
sudo journalctl -u patroni --since "1 hour ago"
```

### Ver Logs do PostgreSQL

```bash
# SSH para nó Patroni
sudo tail -f /var/lib/pgsql/17/data/log/postgresql-*.log
```

### Reiniciar Serviço Patroni

```bash
# SSH para nó Patroni
sudo systemctl restart patroni

# Verificar status
sudo systemctl status patroni
```

### Verificar PgBouncer

```bash
# SSH para nó Patroni (PgBouncer roda em cada nó)
sudo -u pgbouncer psql -p 6432 -U pgbouncer pgbouncer -c "SHOW POOLS;"
sudo -u pgbouncer psql -p 6432 -U pgbouncer pgbouncer -c "SHOW STATS;"
```

---

## Resposta a Incidentes

### Níveis de Prioridade

| Prioridade | Descrição | Tempo de Resposta | Exemplo |
|------------|-----------|-------------------|---------|
| P1 | Outage completo | Imediato | Todos os nós down |
| P2 | Degradado (1 nó down) | 15 min | Replica falhou |
| P3 | Alerta | 1 hora | Alto lag de replicação |
| P4 | Informativo | Próximo dia útil | Disco 70% cheio |

### P1: Outage Completo

**Sintomas:**
- NLB mostra 0 targets saudáveis
- Aplicação não consegue conectar ao PostgreSQL
- Todos os nós Patroni mostram como falhos

**Passos:**

1. **Verificar infraestrutura AWS:**
   ```bash
   aws ec2 describe-instances \
     --filters "Name=tag:Project,Values=postgresql-ha-ec2" \
     --query 'Reservations[].Instances[].[InstanceId,State.Name]' \
     --profile postgresql-ha-profile
   ```

2. **Verificar cluster etcd:**
   ```bash
   etcdctl endpoint health --cluster
   ```

3. **Se etcd está down:** Reinicie etcd em todos os nós:
   ```bash
   sudo systemctl restart etcd
   ```

4. **Se Patroni está down:** Reinicie Patroni:
   ```bash
   sudo systemctl restart patroni
   ```

### P2: Falha de Nó Único

**Sintomas:**
- 2/3 nós Patroni saudáveis
- Cluster ainda operacional
- Um target não saudável no NLB

**Passos:**

1. **Identificar nó com falha:**
   ```bash
   patronictl -c /etc/patroni/patroni.yml list
   ```

2. **SSH e verificar logs:**
   ```bash
   sudo journalctl -u patroni -n 100
   ```

3. **Se Patroni crashou:** Reinicie:
   ```bash
   sudo systemctl restart patroni
   ```

4. **Se corrupção de dados:** Reinicialize:
   ```bash
   patronictl -c /etc/patroni/patroni.yml reinit pgha-cluster <nome-nó>
   ```

---

## Janelas de Manutenção

### Procedimento de Manutenção Planejada

1. **Notifique stakeholders** (se produção)

2. **Entre em modo de manutenção:**
   ```bash
   sudo -u pgbouncer psql -p 6432 pgbouncer -c "PAUSE;"
   ```

3. **Drene conexões:**
   ```bash
   sudo -u pgbouncer psql -p 6432 pgbouncer -c "SHOW CLIENTS;"
   ```

4. **Execute manutenção**

5. **Retome operações:**
   ```bash
   sudo -u pgbouncer psql -p 6432 pgbouncer -c "RESUME;"
   ```

### Rolling Restart

Para reiniciar todos os nós sem downtime:

1. **Reinicie replicas primeiro:**
   ```bash
   sudo systemctl restart patroni
   patronictl list
   ```

2. **Switchover para uma replica:**
   ```bash
   patronictl switchover
   ```

3. **Reinicie antigo primary (agora replica):**
   ```bash
   sudo systemctl restart patroni
   ```
