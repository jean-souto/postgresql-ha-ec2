#!/bin/bash
# =============================================================================
# Patroni/PostgreSQL Bootstrap Script
# =============================================================================
# Installs and configures PostgreSQL 17, Patroni, and PgBouncer.
# Template variables are injected by Terraform templatefile().
# =============================================================================

set -euxo pipefail

# Log all output
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=== Starting Patroni bootstrap ==="
echo "Instance Name: ${instance_name}"
echo "Cluster Name: ${cluster_name}"

# -----------------------------------------------------------------------------
# System Configuration
# -----------------------------------------------------------------------------

# Set hostname
hostnamectl set-hostname ${instance_name}

# Update system packages
dnf update -y

# Install required packages
dnf install -y jq python3 python3-pip gcc python3-devel

# -----------------------------------------------------------------------------
# Get Instance Metadata
# -----------------------------------------------------------------------------

# Get IMDSv2 token
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# Get private IP
PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

echo "Private IP: $PRIVATE_IP"

# -----------------------------------------------------------------------------
# Fetch Secrets from SSM Parameter Store
# -----------------------------------------------------------------------------

echo "=== Fetching secrets from SSM ==="

POSTGRES_PASSWORD=$(aws ssm get-parameter \
  --name "/pgha/postgres-password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region})

REPLICATION_PASSWORD=$(aws ssm get-parameter \
  --name "/pgha/replication-password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region})

PGBOUNCER_PASSWORD=$(aws ssm get-parameter \
  --name "/pgha/pgbouncer-password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region})

PATRONI_API_PASSWORD=$(aws ssm get-parameter \
  --name "/pgha/patroni-api-password" \
  --with-decryption \
  --query 'Parameter.Value' \
  --output text \
  --region ${aws_region})

echo "Secrets fetched successfully"

# -----------------------------------------------------------------------------
# Install PostgreSQL 17
# -----------------------------------------------------------------------------

echo "=== Installing PostgreSQL 17 ==="

# Amazon Linux 2023 compatibility: Create /etc/redhat-release for PGDG repo
# AL2023 is Fedora-based but lacks this file that PGDG expects
if [ ! -f /etc/redhat-release ]; then
  echo "Red Hat Enterprise Linux release 9.4 (Plow)" > /etc/redhat-release
fi

# Download and install PGDG repo RPM bypassing dependency check
# The RPM requires /etc/redhat-release but we just created it above
curl -Lo /tmp/pgdg-repo.rpm https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
rpm -ivh --nodeps /tmp/pgdg-repo.rpm

# Fix PGDG repo URLs: Amazon Linux 2023 reports $releasever as "2023" but we need "9"
# This replaces the variable with hardcoded "9" in all PGDG repo files
sed -i 's/\$releasever/9/g' /etc/yum.repos.d/pgdg-redhat-all.repo

# Clean dnf cache to pick up the corrected repo URLs
dnf clean all

# Disable built-in PostgreSQL module (ignore errors if not present)
dnf -qy module disable postgresql 2>/dev/null || true

# Install PostgreSQL 17
dnf install -y postgresql17-server postgresql17-contrib

# Create data directory with correct permissions
# PostgreSQL requires 0700 on data directory
mkdir -p /var/lib/pgsql/17/data
chown -R postgres:postgres /var/lib/pgsql/17
chmod 700 /var/lib/pgsql/17/data

# -----------------------------------------------------------------------------
# Install Patroni
# -----------------------------------------------------------------------------

echo "=== Installing Patroni ==="

pip3 install patroni[etcd3] psycopg2-binary

# Create Patroni directories
mkdir -p /etc/patroni
mkdir -p /var/log/patroni
chown postgres:postgres /var/log/patroni

# -----------------------------------------------------------------------------
# Configure Patroni
# -----------------------------------------------------------------------------

echo "=== Configuring Patroni ==="

cat > /etc/patroni/patroni.yml << EOF
scope: ${cluster_name}
name: ${instance_name}

restapi:
  listen: 0.0.0.0:8008
  connect_address: $${PRIVATE_IP}:8008
  authentication:
    username: admin
    password: '$${PATRONI_API_PASSWORD}'

etcd3:
  hosts: ${etcd_hosts}

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        # Memory settings for t2.micro (1GB RAM)
        shared_buffers: 128MB
        effective_cache_size: 384MB
        work_mem: 4MB
        maintenance_work_mem: 64MB

        # WAL settings
        wal_level: replica
        hot_standby: on
        max_wal_senders: 5
        max_replication_slots: 5
        wal_keep_size: 512MB

        # Logging
        logging_collector: on
        log_directory: /var/log/postgresql
        log_filename: 'postgresql-%Y-%m-%d.log'
        log_rotation_age: 1d
        log_rotation_size: 100MB
        log_min_duration_statement: 1000
        log_checkpoints: on
        log_connections: on
        log_disconnections: on
        log_lock_waits: on

  initdb:
    - encoding: UTF8
    - data-checksums

  pg_hba:
    - local   all             all                                     trust
    - host    all             all             127.0.0.1/32            scram-sha-256
    - host    all             all             0.0.0.0/0               scram-sha-256
    - host    replication     replicator      0.0.0.0/0               scram-sha-256

  users:
    admin:
      password: '$${POSTGRES_PASSWORD}'
      options:
        - superuser
        - createrole
        - createdb
    replicator:
      password: '$${REPLICATION_PASSWORD}'
      options:
        - replication

postgresql:
  listen: 0.0.0.0:5432
  connect_address: $${PRIVATE_IP}:5432
  data_dir: /var/lib/pgsql/17/data
  bin_dir: /usr/bin
  pgpass: /var/lib/pgsql/.pgpass
  authentication:
    superuser:
      username: postgres
      password: '$${POSTGRES_PASSWORD}'
    replication:
      username: replicator
      password: '$${REPLICATION_PASSWORD}'
    rewind:
      username: postgres
      password: '$${POSTGRES_PASSWORD}'

watchdog:
  mode: off

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF

chown postgres:postgres /etc/patroni/patroni.yml
chmod 600 /etc/patroni/patroni.yml

# Create PostgreSQL log directory
mkdir -p /var/log/postgresql
chown postgres:postgres /var/log/postgresql

# -----------------------------------------------------------------------------
# Create Patroni systemd Service
# -----------------------------------------------------------------------------

cat > /etc/systemd/system/patroni.service << 'EOF'
[Unit]
Description=Patroni PostgreSQL Cluster Manager
Documentation=https://patroni.readthedocs.io/
After=network.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/usr/local/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
# Install PgBouncer
# -----------------------------------------------------------------------------

echo "=== Installing PgBouncer ==="

dnf install -y pgbouncer

# Configure PgBouncer
cat > /etc/pgbouncer/pgbouncer.ini << EOF
[databases]
* = host=127.0.0.1 port=5432

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
admin_users = pgbouncer
pool_mode = transaction
max_client_conn = 100
default_pool_size = 20
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3
server_lifetime = 3600
server_idle_timeout = 600
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
EOF

# Create PgBouncer userlist
cat > /etc/pgbouncer/userlist.txt << EOF
"postgres" "$${POSTGRES_PASSWORD}"
"pgbouncer" "$${PGBOUNCER_PASSWORD}"
"admin" "$${POSTGRES_PASSWORD}"
EOF

chown pgbouncer:pgbouncer /etc/pgbouncer/userlist.txt
chmod 600 /etc/pgbouncer/userlist.txt

# -----------------------------------------------------------------------------
# Start Services
# -----------------------------------------------------------------------------

echo "=== Starting services ==="

systemctl daemon-reload

# Start Patroni
systemctl enable patroni
systemctl start patroni

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
sleep 30

# Start PgBouncer
systemctl enable pgbouncer
systemctl start pgbouncer

# -----------------------------------------------------------------------------
# Verify Installation
# -----------------------------------------------------------------------------

echo "=== Verifying installation ==="

# Check Patroni status
curl -s http://localhost:8008/patroni || echo "Patroni API not ready yet"

# Check PostgreSQL is running
su - postgres -c "/usr/bin/pg_isready -h localhost -p 5432" || echo "PostgreSQL not ready yet"

echo "=== Patroni bootstrap completed ==="
