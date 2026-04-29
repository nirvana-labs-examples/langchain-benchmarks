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

Deploys 5 VMs:
- **AWS gp3-3k**: m6i.xlarge, 256GB, 3,000 IOPS
- **AWS gp3-16k**: m6i.xlarge, 256GB, 16,000 IOPS
- **AWS io2-32k**: m6i.xlarge, 256GB, 32,000 IOPS
- **AWS io2-64k**: m6i.xlarge, 256GB, 64,000 IOPS (capped at instance limit)
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

| Platform | Provisioned IOPS | Measured IOPS | Latency |
|----------|------------------|---------------|---------|
| gp3-3k | 3,000 | 3,097 | 82,639 us |
| gp3-16k | 16,000 | 16,531 | 15,484 us |
| io2-32k | 32,000 | 33,071 | 7,740 us |
| io2-64k | 64,000 | 40,339* | 6,345 us |
| **Nirvana ABS** | Dynamic | **216,751** | **1,181 us** |

\* io2-64k capped at m6i.xlarge instance limit (40,000 IOPS)

### Application Cold Read (LangChain)

| Platform | Qdrant p50 | Redis p50 | Postgres p50 |
|----------|------------|-----------|--------------|
| gp3-3k | 2.00 ms | 0.10 ms | 0.23 ms |
| gp3-16k | 2.43 ms | 0.10 ms | 0.21 ms |
| io2-32k | 2.39 ms | 0.10 ms | 0.23 ms |
| io2-64k | 2.18 ms | 0.10 ms | 0.21 ms |
| Nirvana ABS | 2.19 ms | 0.14 ms | 0.21 ms |

### Key Takeaways

1. **Nirvana ABS** delivers **217k cold read IOPS** vs AWS's best io2 (40k) = **5.4x faster**
2. **Cold reads confirm** we're measuring actual disk I/O, not memory cache
3. AWS io2-64k was capped by m6i.xlarge instance limit (40k) despite 64k provisioned IOPS
4. Application latency shows less variance across platforms - dominated by application/network layer

## Test Configuration

| Parameter | gp3-3k | gp3-16k | io2-32k | io2-64k | Nirvana |
|-----------|--------|---------|---------|---------|---------|
| Instance Type | m6i.xlarge | m6i.xlarge | m6i.xlarge | m6i.xlarge | n1-standard-4 |
| vCPU / RAM | 4 / 16 GB | 4 / 16 GB | 4 / 16 GB | 4 / 16 GB | 4 / 16 GB |
| Storage Type | gp3 | gp3 | io2 | io2 | ABS |
| Size | 256 GB | 256 GB | 256 GB | 256 GB | 256 GB |
| Provisioned IOPS | 3,000 | 16,000 | 32,000 | 64,000 | Dynamic |
| Instance Max IOPS | 40,000 | 40,000 | 40,000 | 40,000 | N/A |

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│                                      LOCAL MACHINE                                        │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                                   │
│  │  Terraform  │───▶│  Ansible    │───▶│  Results    │                                   │
│  └─────────────┘    └──────┬──────┘    └─────────────┘                                   │
└────────────────────────────┼─────────────────────────────────────────────────────────────┘
                             │ SSH
    ┌────────────┬───────────┼───────────┬────────────┐
    ▼            ▼           ▼           ▼            ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌──────────────┐
│ gp3-3k │ │gp3-16k │ │io2-32k │ │io2-64k │ │ Nirvana ABS  │
│ 3k IOPS│ │16k IOPS│ │32k IOPS│ │64k IOPS│ │ dynamic IOPS │
└────────┘ └────────┘ └────────┘ └────────┘ └──────────────┘
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
