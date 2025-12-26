# =============================================================================
# EC2 Instances: Patroni/PostgreSQL Cluster
# =============================================================================
# Creates EC2 instances for PostgreSQL HA managed by Patroni.
# Each instance runs PostgreSQL 17, Patroni, and PgBouncer.
# Instance type and count are configurable via variables.
# =============================================================================

# -----------------------------------------------------------------------------
# Local values for Patroni configuration
# -----------------------------------------------------------------------------

locals {
  # Patroni instance configurations
  patroni_instances = {
    0 = { name = "${local.name_prefix}-patroni-1" }
    1 = { name = "${local.name_prefix}-patroni-2" }
    2 = { name = "${local.name_prefix}-patroni-3" }
  }

  # Patroni cluster name
  patroni_cluster_name = "${local.name_prefix}-postgres"

  # etcd hosts string for Patroni configuration
  # Using fixed IPs from local.etcd_instances for predictable configuration
  etcd_hosts_list = join(",", [
    for idx, inst in local.etcd_instances :
    "${inst.private_ip}:2379"
  ])
}

# -----------------------------------------------------------------------------
# EC2 Instances for Patroni/PostgreSQL
# -----------------------------------------------------------------------------

resource "aws_instance" "patroni" {
  for_each = local.patroni_instances

  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.patroni.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance.name

  # 30GB gp2 root volume for PostgreSQL data
  root_block_device {
    volume_size           = var.patroni_root_volume_size
    volume_type           = "gp2"
    delete_on_termination = true
    encrypted             = true

    tags = merge(local.common_tags, {
      Name = "${each.value.name}-root"
    })
  }

  # User data script for Patroni bootstrap
  user_data = templatefile("${path.module}/scripts/user-data-patroni.sh.tpl", {
    instance_name = each.value.name
    cluster_name  = local.patroni_cluster_name
    aws_region    = var.aws_region
    etcd_hosts    = local.etcd_hosts_list
  })

  # Ensure etcd instances are created first
  depends_on = [
    aws_instance.etcd,
    aws_security_group.patroni,
    aws_iam_instance_profile.ec2_instance,
    aws_ssm_parameter.postgres_password,
    aws_ssm_parameter.replication_password,
    aws_ssm_parameter.pgbouncer_password,
    aws_ssm_parameter.patroni_api_password
  ]

  tags = merge(local.common_tags, {
    Name = each.value.name
    Role = "patroni"
  })

  lifecycle {
    # Prevent accidental destruction
    prevent_destroy = false

    # Ignore changes to user_data after creation (requires instance replacement)
    ignore_changes = [user_data]
  }
}

# -----------------------------------------------------------------------------
# Elastic IPs for Patroni instances - REMOVED
# -----------------------------------------------------------------------------
# EIPs removed to improve security. Access Patroni/PostgreSQL via:
# 1. NLB for database connections (ports 5432, 5433)
# 2. SSH through bastion host for administration
# 3. SSM Session Manager for remote access
# -----------------------------------------------------------------------------
