# Setup Guide

> **[English](#english)** | **[Português](#portugues)**

---

<a name="english"></a>
## English

Complete guide for deploying the PostgreSQL HA cluster on AWS EC2.

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| AWS Account | - | AWS resources |
| AWS CLI | >= 2.0 | AWS API access |
| Terraform | >= 1.6.0 | Infrastructure as Code |
| SSH Key Pair | - | EC2 instance access |
| Git Bash | - | Shell on Windows |

### Step 1: AWS CLI Configuration

This project uses the AWS CLI profile `postgresql-ha-profile`.

```bash
# Configure the profile
aws configure --profile postgresql-ha-profile
```

Enter when prompted:
- **AWS Access Key ID**: Your access key
- **AWS Secret Access Key**: Your secret key
- **Default region name**: `us-east-1`
- **Default output format**: `json`

**Verify configuration:**

```bash
aws sts get-caller-identity --profile postgresql-ha-profile
```

Expected output:
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-user"
}
```

<details>
<summary><strong>Using a different profile name</strong></summary>

To use a different profile, update these files:

1. **`terraform/providers.tf`**:
   ```hcl
   provider "aws" {
     region  = var.aws_region
     profile = "your-profile-name"
   }
   ```

2. **`scripts/config.sh`**:
   ```bash
   export AWS_PROFILE="your-profile-name"
   ```

3. **All scripts in `scripts/`**: Replace `--profile postgresql-ha-profile`

</details>

### Step 2: Clone Repository

```bash
git clone https://github.com/jean-souto/postgresql-ha-ec2.git
cd postgresql-ha-ec2
```

### Step 3: Configure Terraform Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# Your AWS Account ID (12 digits)
aws_account_id = "123456789012"

# Name of your EC2 key pair in AWS
key_name = "your-ssh-key"

# Your public IP for SSH access (get from https://checkip.amazonaws.com/)
admin_ip = "YOUR_IP/32"
```

### Step 4: Configure Scripts

```bash
cd ../scripts
cp config.example.sh config.sh
```

Edit `config.sh`:

```bash
# Path to your SSH private key
SSH_KEY_PATH="$HOME/.ssh/your-key.pem"

# AWS profile (must match terraform/providers.tf)
export AWS_PROFILE="postgresql-ha-profile"
```

### Step 5: Deploy Infrastructure

```bash
# From project root
./scripts/create-cluster.sh
```

The script will:
1. Initialize Terraform
2. Create S3 bucket for state (if not exists)
3. Create DynamoDB table for locking (if not exists)
4. Run `terraform apply`
5. Wait for instances to be ready
6. Display connection information

**Expected duration:** ~5-7 minutes

### Step 6: Verify Deployment

```bash
# Check cluster health
./scripts/health-check.sh
```

Expected output:
```
=== etcd Cluster Status ===
etcd-1: healthy
etcd-2: healthy
etcd-3: healthy
Cluster: 3/3 members healthy

=== Patroni Cluster Status ===
+ Cluster: pgha-cluster (12345678901234567) ---+
| Member     | Host         | Role    | State   |
+------------+--------------+---------+---------+
| patroni-1  | 10.0.1.x     | Leader  | running |
| patroni-2  | 10.0.1.x     | Replica | running |
| patroni-3  | 10.0.1.x     | Replica | running |
+------------+--------------+---------+---------+

=== NLB Target Health ===
Primary (5432): 1 healthy target
Replicas (5433): 2 healthy targets
```

### Step 7: Connect to Services

#### SSH to Bastion

```bash
# Get Bastion IP
cd terraform
BASTION_IP=$(terraform output -raw bastion_public_ip)

# Connect
ssh -i ~/.ssh/your-key.pem ec2-user@$BASTION_IP
```

#### SSH to Cluster Nodes (via Bastion)

```bash
# Get Patroni private IP
PATRONI_IP=$(terraform output -json patroni_private_ips | jq -r '.[0]')

# Connect via ProxyJump
ssh -i ~/.ssh/your-key.pem -J ec2-user@$BASTION_IP ec2-user@$PATRONI_IP
```

#### PostgreSQL via NLB

```bash
# Get NLB DNS name
NLB_DNS=$(terraform output -raw nlb_dns_name)

# Connect to Primary (R/W) - port 5432
psql -h $NLB_DNS -p 5432 -U postgres

# Connect to Replicas (RO) - port 5433
psql -h $NLB_DNS -p 5433 -U postgres
```

**Password:** Retrieved from SSM Parameter Store. Get it with:
```bash
aws ssm get-parameter --name "/pgha/postgres-password" --with-decryption \
    --profile postgresql-ha-profile --query 'Parameter.Value' --output text
```

### Step 8: Test Failover

```bash
./scripts/chaos-test.sh
```

This script runs multiple failure scenarios:
1. **Patroni stop** - Graceful service stop
2. **PostgreSQL kill** - Crash simulation
3. **Patroni failover** - Planned switchover
4. **EC2 stop** - Hardware failure simulation

Each test verifies:
- Automatic failover completes
- Data integrity is preserved
- Cluster recovers to healthy state

### Step 9: Destroy Infrastructure

> **IMPORTANT:** Always destroy when not testing to avoid charges.

```bash
./scripts/destroy-cluster.sh
```

The script will:
1. Confirm destruction
2. Run `terraform destroy`
3. Clean up all AWS resources

---

## Troubleshooting

### Terraform Init Fails

**Error:** `Error: Failed to get existing workspaces`

**Solution:** Delete `.terraform` folder and re-run:
```bash
cd terraform
rm -rf .terraform .terraform.lock.hcl
terraform init
```

### SSH Connection Refused

**Error:** `ssh: connect to host X port 22: Connection refused`

**Causes:**
1. Instance still starting (wait 2-3 min)
2. Security group missing your IP

**Solution:**
```bash
# Check your current IP
curl -s https://checkip.amazonaws.com/

# Update terraform.tfvars with correct IP
admin_ip = "NEW_IP/32"

# Re-apply
terraform apply
```

### Patroni Not Starting

**Error:** `patroni.service: Failed with result 'exit-code'`

**Check logs:**
```bash
# SSH to Patroni node
sudo journalctl -u patroni -n 100

# Common issues:
# 1. etcd not reachable - check security groups
# 2. SSM secrets not accessible - check IAM role
# 3. Port already in use - check for zombie processes
```

### etcd Cluster Not Forming

**Check:**
```bash
# SSH to etcd node
etcdctl endpoint health --cluster
etcdctl member list
```

**Common issues:**
1. Nodes can't reach each other (security groups)
2. Initial cluster configuration mismatch
3. Clock skew between nodes

### NLB Targets Unhealthy

**Check in AWS Console:**
1. EC2 > Target Groups > pgha-primary-tg
2. Check "Health status" column
3. Click on unhealthy target for details

**Common issues:**
1. Patroni API not responding on port 8008
2. Security group blocking NLB health checks
3. Instance not fully initialized

---

## Reference

### Security Group Ports

| Source | Destination | Port | Protocol | Purpose |
|--------|-------------|------|----------|---------|
| NLB | Patroni SG | 5432 | TCP | PostgreSQL |
| NLB | Patroni SG | 6432 | TCP | PgBouncer |
| NLB | Patroni SG | 8008 | TCP | Patroni API (health) |
| Patroni SG | Patroni SG | 5432 | TCP | Replication |
| Patroni SG | etcd SG | 2379 | TCP | etcd client |
| etcd SG | etcd SG | 2380 | TCP | etcd peer |
| Bastion SG | Patroni SG | 22 | TCP | SSH |
| Bastion SG | etcd SG | 22 | TCP | SSH |

### Naming Convention

```
{project}-{resource}-{number}
```

Examples:
- `pgha-patroni-1`, `pgha-patroni-2`, `pgha-patroni-3`
- `pgha-etcd-1`, `pgha-etcd-2`, `pgha-etcd-3`
- `pgha-bastion`
- `pgha-nlb`
- `pgha-sg-patroni`, `pgha-sg-etcd`, `pgha-sg-bastion`

### Required Tags

All resources include:
```hcl
tags = {
  Project   = "postgresql-ha-ec2"
  ManagedBy = "terraform"
}
```

---

<a name="portugues"></a>
## Português

Guia completo para deploy do cluster PostgreSQL HA na AWS EC2.

### Pré-requisitos

| Ferramenta | Versão | Propósito |
|------------|--------|-----------|
| Conta AWS | - | Recursos AWS |
| AWS CLI | >= 2.0 | Acesso à API AWS |
| Terraform | >= 1.6.0 | Infrastructure as Code |
| Par de Chaves SSH | - | Acesso às instâncias EC2 |
| Git Bash | - | Shell no Windows |

### Passo 1: Configuração do AWS CLI

Este projeto usa o perfil AWS CLI `postgresql-ha-profile`.

```bash
# Configure o perfil
aws configure --profile postgresql-ha-profile
```

Informe quando solicitado:
- **AWS Access Key ID**: Sua access key
- **AWS Secret Access Key**: Sua secret key
- **Default region name**: `us-east-1`
- **Default output format**: `json`

**Verifique a configuração:**

```bash
aws sts get-caller-identity --profile postgresql-ha-profile
```

Saída esperada:
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/seu-usuario"
}
```

<details>
<summary><strong>Usando um nome de perfil diferente</strong></summary>

Para usar um perfil diferente, atualize estes arquivos:

1. **`terraform/providers.tf`**:
   ```hcl
   provider "aws" {
     region  = var.aws_region
     profile = "seu-perfil"
   }
   ```

2. **`scripts/config.sh`**:
   ```bash
   export AWS_PROFILE="seu-perfil"
   ```

3. **Todos os scripts em `scripts/`**: Substitua `--profile postgresql-ha-profile`

</details>

### Passo 2: Clonar Repositório

```bash
git clone https://github.com/jean-souto/postgresql-ha-ec2.git
cd postgresql-ha-ec2
```

### Passo 3: Configurar Variáveis Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edite `terraform.tfvars`:

```hcl
# Seu AWS Account ID (12 dígitos)
aws_account_id = "123456789012"

# Nome do seu key pair EC2 na AWS
key_name = "sua-chave-ssh"

# Seu IP público para acesso SSH (obtenha em https://checkip.amazonaws.com/)
admin_ip = "SEU_IP/32"
```

### Passo 4: Configurar Scripts

```bash
cd ../scripts
cp config.example.sh config.sh
```

Edite `config.sh`:

```bash
# Caminho para sua chave SSH privada
SSH_KEY_PATH="$HOME/.ssh/sua-chave.pem"

# Perfil AWS (deve corresponder ao terraform/providers.tf)
export AWS_PROFILE="postgresql-ha-profile"
```

### Passo 5: Deploy da Infraestrutura

```bash
# Da raiz do projeto
./scripts/create-cluster.sh
```

O script irá:
1. Inicializar o Terraform
2. Criar bucket S3 para state (se não existir)
3. Criar tabela DynamoDB para locking (se não existir)
4. Executar `terraform apply`
5. Aguardar instâncias ficarem prontas
6. Exibir informações de conexão

**Duração esperada:** ~5-7 minutos

### Passo 6: Verificar Deploy

```bash
# Verificar saúde do cluster
./scripts/health-check.sh
```

Saída esperada:
```
=== etcd Cluster Status ===
etcd-1: healthy
etcd-2: healthy
etcd-3: healthy
Cluster: 3/3 members healthy

=== Patroni Cluster Status ===
+ Cluster: pgha-cluster (12345678901234567) ---+
| Member     | Host         | Role    | State   |
+------------+--------------+---------+---------+
| patroni-1  | 10.0.1.x     | Leader  | running |
| patroni-2  | 10.0.1.x     | Replica | running |
| patroni-3  | 10.0.1.x     | Replica | running |
+------------+--------------+---------+---------+

=== NLB Target Health ===
Primary (5432): 1 healthy target
Replicas (5433): 2 healthy targets
```

### Passo 7: Conectar aos Serviços

#### SSH para o Bastion

```bash
# Obter IP do Bastion
cd terraform
BASTION_IP=$(terraform output -raw bastion_public_ip)

# Conectar
ssh -i ~/.ssh/sua-chave.pem ec2-user@$BASTION_IP
```

#### SSH para Nós do Cluster (via Bastion)

```bash
# Obter IP privado do Patroni
PATRONI_IP=$(terraform output -json patroni_private_ips | jq -r '.[0]')

# Conectar via ProxyJump
ssh -i ~/.ssh/sua-chave.pem -J ec2-user@$BASTION_IP ec2-user@$PATRONI_IP
```

#### PostgreSQL via NLB

```bash
# Obter DNS do NLB
NLB_DNS=$(terraform output -raw nlb_dns_name)

# Conectar ao Primary (R/W) - porta 5432
psql -h $NLB_DNS -p 5432 -U postgres

# Conectar às Replicas (RO) - porta 5433
psql -h $NLB_DNS -p 5433 -U postgres
```

**Senha:** Obtida do SSM Parameter Store. Recupere com:
```bash
aws ssm get-parameter --name "/pgha/postgres-password" --with-decryption \
    --profile postgresql-ha-profile --query 'Parameter.Value' --output text
```

### Passo 8: Testar Failover

```bash
./scripts/chaos-test.sh
```

Este script executa múltiplos cenários de falha:
1. **Patroni stop** - Parada graceful do serviço
2. **PostgreSQL kill** - Simulação de crash
3. **Patroni failover** - Switchover planejado
4. **EC2 stop** - Simulação de falha de hardware

Cada teste verifica:
- Failover automático completa
- Integridade dos dados preservada
- Cluster recupera para estado saudável

### Passo 9: Destruir Infraestrutura

> **IMPORTANTE:** Sempre destrua quando não estiver testando para evitar cobranças.

```bash
./scripts/destroy-cluster.sh
```

O script irá:
1. Confirmar destruição
2. Executar `terraform destroy`
3. Limpar todos os recursos AWS

---

## Solução de Problemas

### Terraform Init Falha

**Erro:** `Error: Failed to get existing workspaces`

**Solução:** Delete a pasta `.terraform` e execute novamente:
```bash
cd terraform
rm -rf .terraform .terraform.lock.hcl
terraform init
```

### Conexão SSH Recusada

**Erro:** `ssh: connect to host X port 22: Connection refused`

**Causas:**
1. Instância ainda iniciando (aguarde 2-3 min)
2. Security group sem seu IP

**Solução:**
```bash
# Verifique seu IP atual
curl -s https://checkip.amazonaws.com/

# Atualize terraform.tfvars com IP correto
admin_ip = "NOVO_IP/32"

# Re-aplique
terraform apply
```

### Patroni Não Inicia

**Erro:** `patroni.service: Failed with result 'exit-code'`

**Verifique logs:**
```bash
# SSH para nó Patroni
sudo journalctl -u patroni -n 100

# Problemas comuns:
# 1. etcd não alcançável - verifique security groups
# 2. Secrets SSM não acessíveis - verifique IAM role
# 3. Porta em uso - verifique processos zumbi
```

### Cluster etcd Não Forma

**Verifique:**
```bash
# SSH para nó etcd
etcdctl endpoint health --cluster
etcdctl member list
```

**Problemas comuns:**
1. Nós não conseguem se comunicar (security groups)
2. Configuração inicial do cluster incorreta
3. Diferença de relógio entre nós

### Targets do NLB Não Saudáveis

**Verifique no Console AWS:**
1. EC2 > Target Groups > pgha-primary-tg
2. Verifique coluna "Health status"
3. Clique no target não saudável para detalhes

**Problemas comuns:**
1. API Patroni não responde na porta 8008
2. Security group bloqueando health checks do NLB
3. Instância não totalmente inicializada

---

## Referência

### Portas dos Security Groups

| Origem | Destino | Porta | Protocolo | Propósito |
|--------|---------|-------|-----------|-----------|
| NLB | Patroni SG | 5432 | TCP | PostgreSQL |
| NLB | Patroni SG | 6432 | TCP | PgBouncer |
| NLB | Patroni SG | 8008 | TCP | Patroni API (health) |
| Patroni SG | Patroni SG | 5432 | TCP | Replicação |
| Patroni SG | etcd SG | 2379 | TCP | etcd client |
| etcd SG | etcd SG | 2380 | TCP | etcd peer |
| Bastion SG | Patroni SG | 22 | TCP | SSH |
| Bastion SG | etcd SG | 22 | TCP | SSH |

### Convenção de Nomes

```
{projeto}-{recurso}-{número}
```

Exemplos:
- `pgha-patroni-1`, `pgha-patroni-2`, `pgha-patroni-3`
- `pgha-etcd-1`, `pgha-etcd-2`, `pgha-etcd-3`
- `pgha-bastion`
- `pgha-nlb`
- `pgha-sg-patroni`, `pgha-sg-etcd`, `pgha-sg-bastion`

### Tags Obrigatórias

Todos os recursos incluem:
```hcl
tags = {
  Project   = "postgresql-ha-ec2"
  ManagedBy = "terraform"
}
```
