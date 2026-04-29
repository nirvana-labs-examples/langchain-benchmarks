# LangChain Agent Benchmark

Compares storage performance between [Nirvana Labs ABS](https://nirvanalabs.io) and AWS (gp3 and io2) for LangChain agent workloads.

> OS caches are dropped before benchmarks to measure true disk performance, not memory cache.

## What's Tested

### 1. Raw Disk (fio)
- Write 1GB test file, drop OS caches, measure IOPS/latency

### 2. LangChain
- Run LangChain agents with Qdrant, Redis, Postgres
- Measure IOPS, latency (p50/p95/p99), and task completion time

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

### Raw Disk (fio)

| Platform | Provisioned IOPS | Measured IOPS | Latency |
|----------|------------------|---------------|---------|
| gp3-3k | 3,000 | 3,097 | 82,639 us |
| gp3-16k | 16,000 | 16,531 | 15,484 us |
| io2-32k | 32,000 | 33,071 | 7,740 us |
| io2-64k | 64,000 | 40,339* | 6,345 us |
| **Nirvana ABS** | Dynamic | **216,751** | **1,181 us** |

\* io2-64k capped at m6i.xlarge instance limit (40,000 IOPS)

### LangChain Benchmark

| Metric | Nirvana ABS | AWS gp3 | Improvement |
|--------|-------------|---------|-------------|
| IOPS | 167.25 | 123.58 | **+35%** |
| Latency p50 | 108.10 ms | 143.56 ms | **25% lower** |
| Latency p95 | 256.10 ms | 525.02 ms | **51% lower** |
| Latency p99 | 545.78 ms | 1,507.94 ms | **64% lower** |
| Task Time p50 | 9,998 ms | 13,237 ms | **1.3x faster** |
| Task Time p95 | 11,466 ms | 19,754 ms | **1.7x faster** |
| Task Time p99 | 12,981 ms | 22,441 ms | **1.7x faster** |

### Key Takeaways

1. **Nirvana ABS** delivers **217k IOPS** vs AWS's best io2 (40k) = **5.4x faster**
2. **Tail latency (p99)** shows the biggest improvement - **64% lower** on Nirvana ABS
3. **Task completion** is **1.7x faster** at p95/p99 - critical for production SLAs
4. AWS io2-64k was capped by m6i.xlarge instance limit (40k) despite 64k provisioned IOPS

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
+---------------------------------------------------------------------+
|                          LOCAL MACHINE                              |
|   +-----------+      +-----------+      +-----------+               |
|   | Terraform | ---> |  Ansible  | ---> |  Results  |               |
|   +-----------+      +-----+-----+      +-----------+               |
+----------------------------|----------------------------------------+
                             | SSH
        +----------+---------+----------+-----------+
        |          |         |          |           |
        v          v         v          v           v
    +--------+ +--------+ +--------+ +--------+ +------------+
    | gp3-3k | |gp3-16k | |io2-32k | |io2-64k | | Nirvana ABS|
    | 3k IOPS| |16k IOPS| |32k IOPS| |64k IOPS| |dynamic IOPS|
    +--------+ +--------+ +--------+ +--------+ +------------+
```

## Methodology

OS caches are dropped before each benchmark to ensure we measure true disk I/O:

```bash
sync && echo 3 > /proc/sys/vm/drop_caches
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
