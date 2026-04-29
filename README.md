# LangChain Agent Benchmark

Compares **cold read** storage performance between [Nirvana Labs ABS](https://nirvanalabs.io) and AWS (gp3 and io2) for LangChain agent workloads.

> **Cold reads** drop OS caches before reading to measure true disk performance, not memory cache.

## What's Tested

### 1. Raw Disk (fio)
- Write 1GB test file
- Drop OS caches (`echo 3 > /proc/sys/vm/drop_caches`)
- Read back and measure IOPS/latency

### 2. LangChain Application
- Populate data: 100 agents × 10 tasks writing to Qdrant, Redis, Postgres
- Drop OS caches
- Run 100 cold read queries against each service

## Quick Start

### Prerequisites

- [Terraform](https://terraform.io) installed
- [Ansible](https://ansible.com) installed

### Step 1: Configure Credentials

```bash
# AWS credentials
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."  # if using temporary credentials

# Nirvana Labs API key (https://dashboard.nirvanalabs.io/settings/api-keys)
export NIRVANA_LABS_API_KEY="..."
```

### Step 2: Configure Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
ssh_public_key     = "ssh-ed25519 AAAA... your-email@example.com"
nirvana_project_id = "your-project-id"  # Get from Nirvana dashboard
```

### Step 3: Deploy VMs

```bash
terraform init
terraform apply
```

Deploys 3 VMs:
- **AWS gp3**: m5.xlarge, 256GB, 3,000 IOPS baseline
- **AWS io2**: m5.xlarge, 256GB, 16,000 provisioned IOPS
- **Nirvana**: n1-standard-4, 256GB ABS (dynamic IOPS)

### Step 4: Generate Inventory

```bash
./scripts/generate-inventory.sh
```

### Step 5: Run Benchmark

```bash
cd ansible && ansible-playbook playbook.yml
```

Or fio only:
```bash
cd ansible && ansible-playbook fio-only.yml
```

### Step 6: Cleanup

```bash
cd terraform && terraform destroy
```

## Results

### Raw Disk Cold Read (fio)

| Metric | AWS gp3 | AWS io2 | Nirvana ABS | ABS vs gp3 |
|--------|---------|---------|-------------|------------|
| **Cold Read IOPS** | 3,098 | 16,533 | **162,379** | 52x |
| Cold Read Latency | 82,620 us | 15,481 us | **1,576 us** | 52x lower |

### Application Cold Read (LangChain)

| Service | AWS gp3 p50 | AWS io2 p50 | Nirvana ABS p50 |
|---------|-------------|-------------|-----------------|
| Qdrant (vector) | 2.60 ms | 2.99 ms | **2.47 ms** |
| Redis (cache) | 0.12 ms | 0.13 ms | 0.15 ms |
| Postgres (checkpoint) | 0.31 ms | 0.30 ms | **0.26 ms** |

### Key Takeaways

1. **Nirvana ABS** delivers **162k cold read IOPS** vs io2's 16.5k (10x) and gp3's 3k (52x)
2. **Cold reads confirm** we're measuring actual disk I/O, not memory cache
3. Application cold reads show similar patterns across services

## Test Configuration

| Parameter | AWS gp3 | AWS io2 | Nirvana |
|-----------|---------|---------|---------|
| Instance Type | m5.xlarge | m5.xlarge | n1-standard-4 |
| vCPU / RAM | 4 / 16 GB | 4 / 16 GB | 4 / 16 GB |
| Storage | gp3 | io2 | ABS |
| Size | 256 GB | 256 GB | 256 GB |
| Provisioned IOPS | 3,000 | 16,000 | Dynamic |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              LOCAL MACHINE                                   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                      │
│  │  Terraform  │───▶│  Ansible    │───▶│  Results    │                      │
│  └─────────────┘    └──────┬──────┘    └─────────────┘                      │
└────────────────────────────┼────────────────────────────────────────────────┘
                             │ SSH
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│   AWS gp3       │ │   AWS io2       │ │   Nirvana ABS   │
│   256GB/3k IOPS │ │   256GB/16k IOPS│ │   256GB/dynamic │
├─────────────────┤ ├─────────────────┤ ├─────────────────┤
│ 1. Write data   │ │ 1. Write data   │ │ 1. Write data   │
│ 2. Drop caches  │ │ 2. Drop caches  │ │ 2. Drop caches  │
│ 3. Cold read    │ │ 3. Cold read    │ │ 3. Cold read    │
└─────────────────┘ └─────────────────┘ └─────────────────┘
```

## How Cold Reads Work

### fio (raw disk)
```bash
# 1. Write test file
fio --rw=write --size=1G --filename=/tmp/test

# 2. Drop OS caches
sync && echo 3 > /proc/sys/vm/drop_caches

# 3. Cold read
fio --rw=read --size=1G --filename=/tmp/test
```

### LangChain (application)
```python
# 1. Populate data (100 agents × 10 tasks)
for agent in agents:
    qdrant.upsert(vectors)
    redis.set(cache)
    postgres.insert(checkpoint)

# 2. Drop OS caches
subprocess.run(["sh", "-c", "echo 3 > /proc/sys/vm/drop_caches"])

# 3. Cold read queries
for query in queries:
    qdrant.query_points()  # measure latency
    redis.get()            # measure latency
    postgres.select()      # measure latency
```

## Project Structure

```
.
├── terraform/
│   ├── main.tf              # AWS (gp3 + io2) + Nirvana resources
│   └── variables.tf
├── ansible/
│   ├── playbook.yml         # Full benchmark (fio + LangChain)
│   ├── fio-only.yml         # Raw disk benchmark only
│   └── roles/
│       ├── benchmark-services/   # Docker (Qdrant, Redis, Postgres)
│       └── benchmark-runner/     # Cold read benchmarks
└── results/                 # JSON results
```

## Links

- [Nirvana Labs](https://nirvanalabs.io)
- [Nirvana Labs Documentation](https://docs.nirvanalabs.io)
- [Terraform Provider](https://registry.terraform.io/providers/nirvana-labs/nirvana/latest)
