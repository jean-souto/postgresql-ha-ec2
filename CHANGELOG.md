# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **[English](#english)** | **[Português](#português)**

---

<a name="english"></a>
## English


## [2.3.0] - 2025-12-26

### Fixed
- **PostgreSQL Data Directory Permissions** (`terraform/scripts/user-data-patroni.sh.tpl`)
  - Added `chmod 700 /var/lib/pgsql/17/data` after directory creation
  - PostgreSQL requires 0700 permissions; default was 0755
  - This caused replica "start failed" errors during cluster recreation

### Changed
- **Scripts converted from PowerShell to Bash** (`scripts/`)
  - All scripts now use `.sh` extension for cross-platform compatibility
  - `health-check.sh`, `insert-loop.sh`, `verify-data.sh`, `chaos-test.sh`, `monitor-cluster.sh`
  - Uses SSH via Bastion for all operations


## [2.2.0] - 2025-12-25

### Added
- **Elastic IP for Bastion Host** (`terraform/ec2-bastion.tf`)
  - Static IP that persists across instance restarts
  - Ensures consistent SSH access after infrastructure recreation

### Changed
- Updated `terraform/outputs.tf`:
  - `bastion_public_ip` now references EIP instead of auto-assigned IP
  - Added `bastion_eip_id` output for EIP allocation ID
  - `ssh_via_bastion` uses EIP for all connection commands
- Updated architecture documentation reflecting EIP on bastion


## [2.1.0] - 2025-12-25

### Changed
- **Security Architecture Overhaul**
  - Removed Elastic IPs from Patroni instances (economy)
  - Removed Elastic IPs from etcd instances (economy)
  - All cluster instances now use private IPs only
  - SSH access exclusively via Bastion Host using ProxyJump

- **Security Groups** (`terraform/security-groups.tf`)
  - Patroni SG: SSH now from Bastion SG (not admin IP)
  - etcd SG: SSH now from Bastion SG (not admin IP)
  - Added Bastion SG with SSH from admin IP only

- **Bastion Host** (`terraform/ec2-bastion.tf`)
  - Single entry point for all SSH access
  - ProxyJump to internal nodes (Patroni, etcd)
  - PostgreSQL 17 client for NLB connectivity testing

### Added
- **Operational Scripts** (`scripts/`)
  - `config.example.sh` - Configuration template
  - `health-check.sh` - Cluster health verification via bastion
  - `insert-loop.sh` - Continuous insert test via NLB
  - `verify-data.sh` - Data integrity verification
  - `chaos-test.sh` - Failover testing
  - `monitor-cluster.sh` - Real-time cluster monitoring

### Removed
- Elastic IPs from Patroni instances (`aws_eip.patroni`)
- Elastic IPs from etcd instances (`aws_eip.etcd`)
- Direct SSH access to Patroni/etcd from admin IP

### Security
- Reduced attack surface: only Bastion exposed to internet
- All database nodes accessible only via private network
- SSH hardened through single controlled entry point


## [1.0.0] - 2025-12-25

### Added

#### Infrastructure
- **VPC and Networking** (`terraform/vpc.tf`)
  - Single public subnet (second /24 block from VPC CIDR) in us-east-1a
  - Internet Gateway with route table
  - DNS hostnames and DNS support enabled

- **Security Groups** (`terraform/security-groups.tf`)
  - Patroni SG: PostgreSQL (5432), PgBouncer (6432), Patroni API (8008), SSH
  - etcd SG: Client API (2379), Peer communication (2380), SSH

- **SSM Parameter Store** (`terraform/ssm.tf`)
  - SecureString parameters for all passwords:
    - `/pgha/postgres-password`
    - `/pgha/replication-password`
    - `/pgha/pgbouncer-password`
    - `/pgha/patroni-api-password`

- **IAM Roles** (`terraform/iam.tf`)
  - EC2 instance role with SSM Parameter Store access
  - CloudWatch Logs write permissions
  - EC2 Describe for cluster discovery
  - SSM Session Manager for remote access

- **etcd Cluster** (`terraform/ec2-etcd.tf`)
  - 3 nodes with fixed private IPs (derived from VPC CIDR, offsets 266-268)
  - Amazon Linux 2023 with etcd 3.5.17
  - Private IPs only (EIPs removed in v2.1.0)

- **Patroni/PostgreSQL Cluster** (`terraform/ec2-patroni.tf`)
  - 3 nodes running PostgreSQL 17 + Patroni 4.1.0 + PgBouncer
  - Automatic leader election and failover
  - Private IPs only (EIPs removed in v2.1.0)

- **Network Load Balancer** (`terraform/nlb.tf`)
  - Internal NLB for PostgreSQL access
  - R/W port 5432 (routes to primary only)
  - R/O port 5433 (routes to replicas only)
  - Health checks using Patroni REST API (/primary, /replica)

- **Bastion Host** (`terraform/ec2-bastion.tf`)
  - t3.micro instance for testing NLB connectivity
  - PostgreSQL 17 client installed
  - Auto-assigned public IP (upgraded to EIP in v2.2.0)

- **Terraform Backend** (`terraform/backend.tf`, `terraform/main.tf`)
  - S3 bucket for remote state
  - DynamoDB table for state locking

### Technical Details

#### PostgreSQL 17 on Amazon Linux 2023
- Uses PGDG repository with EL-9 compatibility
- Fixed `$releasever` replacement (AL2023 reports "2023" instead of "9")
- Patroni uses `/usr/bin` as bin_dir (not `/usr/pgsql-17/bin`)

#### etcd Cluster
- Version 3.5.17 (avoiding 3.5.0-3.5.2 corruption bugs)
- Uses fixed private IPs for reliable cluster formation
- Initial cluster token shared across all nodes

#### NLB Health Checks
- HTTP health checks to Patroni API port 8008
- `/primary` endpoint for R/W target group
- `/replica` endpoint for R/O target group
- Health check interval: 10s, threshold: 2 healthy / 2 unhealthy

### Tested Scenarios

#### Cluster Formation
- [x] etcd cluster forms quorum (3/3 nodes)
- [x] Patroni elects primary automatically
- [x] Streaming replication to 2 replicas

#### NLB Connectivity
- [x] Port 5432 routes to primary (pg_is_in_recovery = false)
- [x] Port 5433 routes to replicas (pg_is_in_recovery = true)
- [x] Health checks correctly identify primary vs replicas

#### Failover
- [x] Stopping primary triggers automatic failover (~30s)
- [x] NLB health checks detect new primary
- [x] Data preserved after failover (no data loss)
- [x] Old primary rejoins as replica using pg_rewind
- [x] New data can be inserted on new primary

### Known Limitations

1. **NLB Hairpinning**: Targets cannot connect to their own NLB with client IP preservation enabled. Use bastion for testing.

2. **Free Tier Usage**: 7 EC2 instances (3 Patroni + 3 etcd + 1 Bastion) exceed free tier hours if running 24/7. Use start/stop scripts for cost control.

3. **Single AZ**: All instances in us-east-1a for simplicity. Not production-ready for HA across AZ failures.

> **Note**: EIP limit issue resolved in v2.1.0 - now uses only 1 EIP (Bastion) instead of 6.

### Configuration

#### Required Variables
```hcl
aws_account_id = "123456789012"
aws_region     = "us-east-1"
environment    = "dev"
key_name       = "your-ssh-key"
admin_ip       = "your-ip/32"
```

#### Connection Strings
```bash
# R/W (Primary)
psql -h <nlb-dns> -p 5432 -U postgres -d postgres

# R/O (Replicas)
psql -h <nlb-dns> -p 5433 -U postgres -d postgres
```

### References
- [Patroni Documentation](https://patroni.readthedocs.io/)
- [etcd Operations Guide](https://etcd.io/docs/v3.5/op-guide/)
- [AWS NLB Documentation](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/)

---

# Changelog (PT-BR)

Todas as mudanças notáveis deste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
e este projeto adere ao [Versionamento Semântico](https://semver.org/spec/v2.0.0.html).

<a name="português"></a>
## Português

## [2.3.0] - 2025-12-26

### Corrigido
- **Permissões do Diretório de Dados PostgreSQL** (`terraform/scripts/user-data-patroni.sh.tpl`)
  - Adicionado `chmod 700 /var/lib/pgsql/17/data` após criação do diretório
  - PostgreSQL requer permissões 0700; padrão era 0755
  - Isso causava erros "start failed" nas réplicas durante recriação do cluster

### Alterado
- **Scripts convertidos de PowerShell para Bash** (`scripts/`)
  - Todos os scripts agora usam extensão `.sh` para compatibilidade cross-platform
  - `health-check.sh`, `insert-loop.sh`, `verify-data.sh`, `chaos-test.sh`, `monitor-cluster.sh`
  - Usa SSH via Bastion para todas as operações


## [2.2.0] - 2025-12-25

### Adicionado
- **Elastic IP para Bastion Host** (`terraform/ec2-bastion.tf`)
  - IP estático que persiste entre reinicializações
  - Garante acesso SSH consistente após recriação da infraestrutura

### Alterado
- Atualizado `terraform/outputs.tf`:
  - `bastion_public_ip` agora referencia EIP ao invés de IP auto-atribuído
  - Adicionado output `bastion_eip_id` para ID de alocação do EIP
  - `ssh_via_bastion` usa EIP para todos os comandos de conexão
- Atualizada documentação da arquitetura refletindo EIP no bastion


## [2.1.0] - 2025-12-25

### Alterado
- **Reestruturação da Arquitetura de Segurança**
  - Removidos Elastic IPs das instâncias Patroni (economia)
  - Removidos Elastic IPs das instâncias etcd (economia)
  - Todas as instâncias do cluster agora usam apenas IPs privados
  - Acesso SSH exclusivamente via Bastion Host usando ProxyJump

- **Security Groups** (`terraform/security-groups.tf`)
  - Patroni SG: SSH agora do Bastion SG (não do IP admin)
  - etcd SG: SSH agora do Bastion SG (não do IP admin)
  - Adicionado Bastion SG com SSH apenas do IP admin

- **Bastion Host** (`terraform/ec2-bastion.tf`)
  - Ponto único de entrada para todo acesso SSH
  - ProxyJump para nós internos (Patroni, etcd)
  - Cliente PostgreSQL 17 para testes de conectividade NLB

### Adicionado
- **Scripts Operacionais** (`scripts/`)
  - `config.example.sh` - Template de configuração
  - `health-check.sh` - Verificação de saúde do cluster via bastion
  - `insert-loop.sh` - Teste de insert contínuo via NLB
  - `verify-data.sh` - Verificação de integridade de dados
  - `chaos-test.sh` - Testes de failover
  - `monitor-cluster.sh` - Monitoramento em tempo real

### Removido
- Elastic IPs das instâncias Patroni (`aws_eip.patroni`)
- Elastic IPs das instâncias etcd (`aws_eip.etcd`)
- Acesso SSH direto ao Patroni/etcd do IP admin

### Segurança
- Superfície de ataque reduzida: apenas Bastion exposto à internet
- Todos os nós de banco acessíveis apenas via rede privada
- SSH hardened através de ponto de entrada único controlado


## [1.0.0] - 2025-12-25

### Adicionado

#### Infraestrutura
- **VPC e Rede** (`terraform/vpc.tf`)
  - Subnet pública única (segundo bloco /24 do CIDR da VPC) em us-east-1a
  - Internet Gateway com route table
  - DNS hostnames e DNS support habilitados

- **Security Groups** (`terraform/security-groups.tf`)
  - Patroni SG: PostgreSQL (5432), PgBouncer (6432), Patroni API (8008), SSH
  - etcd SG: Client API (2379), Peer communication (2380), SSH

- **SSM Parameter Store** (`terraform/ssm.tf`)
  - Parâmetros SecureString para todas as senhas:
    - `/pgha/postgres-password`
    - `/pgha/replication-password`
    - `/pgha/pgbouncer-password`
    - `/pgha/patroni-api-password`

- **IAM Roles** (`terraform/iam.tf`)
  - Role EC2 com acesso ao SSM Parameter Store
  - Permissões de escrita no CloudWatch Logs
  - EC2 Describe para descoberta do cluster
  - SSM Session Manager para acesso remoto

- **Cluster etcd** (`terraform/ec2-etcd.tf`)
  - 3 nós com IPs privados fixos (derivados do CIDR da VPC, offsets 266-268)
  - Amazon Linux 2023 com etcd 3.5.17
  - Apenas IPs privados (EIPs removidos na v2.1.0)

- **Cluster Patroni/PostgreSQL** (`terraform/ec2-patroni.tf`)
  - 3 nós executando PostgreSQL 17 + Patroni 4.1.0 + PgBouncer
  - Eleição automática de líder e failover
  - Apenas IPs privados (EIPs removidos na v2.1.0)

- **Network Load Balancer** (`terraform/nlb.tf`)
  - NLB interno para acesso ao PostgreSQL
  - Porta R/W 5432 (roteia apenas para primary)
  - Porta R/O 5433 (roteia apenas para replicas)
  - Health checks usando API REST do Patroni (/primary, /replica)

- **Bastion Host** (`terraform/ec2-bastion.tf`)
  - Instância t3.micro para testes de conectividade NLB
  - Cliente PostgreSQL 17 instalado
  - IP público auto-atribuído (atualizado para EIP na v2.2.0)

- **Terraform Backend** (`terraform/backend.tf`, `terraform/main.tf`)
  - Bucket S3 para state remoto
  - Tabela DynamoDB para locking de state

### Detalhes Técnicos

#### PostgreSQL 17 no Amazon Linux 2023
- Usa repositório PGDG com compatibilidade EL-9
- Corrigido replacement de `$releasever` (AL2023 reporta "2023" ao invés de "9")
- Patroni usa `/usr/bin` como bin_dir (não `/usr/pgsql-17/bin`)

#### Cluster etcd
- Versão 3.5.17 (evitando bugs de corrupção das 3.5.0-3.5.2)
- Usa IPs privados fixos para formação confiável do cluster
- Token inicial do cluster compartilhado entre todos os nós

#### Health Checks do NLB
- Health checks HTTP para porta 8008 da API Patroni
- Endpoint `/primary` para target group R/W
- Endpoint `/replica` para target group R/O
- Intervalo de health check: 10s, threshold: 2 healthy / 2 unhealthy

### Cenários Testados

#### Formação do Cluster
- [x] Cluster etcd forma quorum (3/3 nós)
- [x] Patroni elege primary automaticamente
- [x] Replicação streaming para 2 replicas

#### Conectividade NLB
- [x] Porta 5432 roteia para primary (pg_is_in_recovery = false)
- [x] Porta 5433 roteia para replicas (pg_is_in_recovery = true)
- [x] Health checks identificam corretamente primary vs replicas

#### Failover
- [x] Parar primary dispara failover automático (~30s)
- [x] Health checks NLB detectam novo primary
- [x] Dados preservados após failover (sem perda de dados)
- [x] Antigo primary reintegra como replica usando pg_rewind
- [x] Novos dados podem ser inseridos no novo primary

### Limitações Conhecidas

1. **NLB Hairpinning**: Targets não podem conectar ao próprio NLB com preservação de IP do cliente habilitada. Use bastion para testes.

2. **Uso Free Tier**: 7 instâncias EC2 (3 Patroni + 3 etcd + 1 Bastion) excedem horas do free tier se rodando 24/7. Use scripts start/stop para controle de custos.

3. **Single AZ**: Todas as instâncias em us-east-1a por simplicidade. Não pronto para produção com HA entre falhas de AZ.

> **Nota**: Problema de limite de EIP resolvido na v2.1.0 - agora usa apenas 1 EIP (Bastion) ao invés de 6.

### Configuração

#### Variáveis Obrigatórias
```hcl
aws_account_id = "123456789012"
aws_region     = "us-east-1"
environment    = "dev"
key_name       = "sua-chave-ssh"
admin_ip       = "seu-ip/32"
```

#### Strings de Conexão
```bash
# R/W (Primary)
psql -h <nlb-dns> -p 5432 -U postgres -d postgres

# R/O (Replicas)
psql -h <nlb-dns> -p 5433 -U postgres -d postgres
```

### Referências
- [Documentação Patroni](https://patroni.readthedocs.io/)
- [Guia de Operações etcd](https://etcd.io/docs/v3.5/op-guide/)
- [Documentação AWS NLB](https://docs.aws.amazon.com/elasticloadbalancing/latest/network/)
