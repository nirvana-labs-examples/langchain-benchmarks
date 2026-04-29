# LangChain Agent Benchmark

Compares storage performance between [Nirvana Labs ABS](https://nirvanalabs.io) and AWS gp3 for LangChain agent workloads.

Runs **100 concurrent agents**, each executing **10 tasks** with vector storage (Qdrant), caching (Redis), and checkpointing (Postgres).

## Quick Start

### Prerequisites

- [Terraform](https://terraform.io) installed
- [Ansible](https://ansible.com) installed

### Step 1: Configure Credentials

**AWS Credentials:**
```bash
# Option A: Use AWS CLI
aws configure

# Option B: Environment variables
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."  # if using temporary credentials
```

**Nirvana Labs API Key:**
```bash
# Get from https://dashboard.nirvanalabs.io/settings/api-keys
export NIRVANA_LABS_API_KEY="..."
```

**SSH Key:**
```bash
# Generate if you don't have one
ssh-keygen -t ed25519 -C "your-email@example.com"

# Your public key is at ~/.ssh/id_ed25519.pub
cat ~/.ssh/id_ed25519.pub
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

This deploys both VMs simultaneously:
- **AWS**: m5.xlarge with 256GB gp3 storage (us-west-1)
- **Nirvana**: n1-standard-4 with 256GB ABS storage (us-sva-2)

### Step 4: Generate Inventory & Verify SSH

```bash
./scripts/generate-inventory.sh
```

This generates the Ansible inventory and waits for SSH access (up to 60s).

### Step 5: Run Benchmark

```bash
cd ansible && ansible-playbook playbook.yml
```

This will:
1. Install Docker and start services (Postgres, Qdrant, Redis) on both VMs
2. Run the benchmark **on each VM** (eliminates network variability)
3. Fetch results back to `ansible/results/`

## Results

Results are saved to:
- `ansible/results/nirvana-abs-benchmark.json`
- `ansible/results/aws-gp3-benchmark.json`

### Expected Results

> **Note:** These are estimates from our testing. Your results will likely fall within this range depending on cloud region load, time of day, and other factors.

| Metric | Nirvana ABS | AWS gp3 | Improvement |
|--------|-------------|---------|-------------|
| **IOPS** | **167.25** | 123.58 | **+35%** |
| Latency p50 | 108.10ms | 143.56ms | 25% lower |
| Latency p95 | 256.10ms | 525.02ms | 51% lower |
| Latency p99 | 545.78ms | 1,507.94ms | 64% lower |
| **Task Time p50** | **9,998ms** | 13,237ms | **1.3x faster** |
| **Task Time p95** | **11,466ms** | 19,754ms | **1.7x faster** |
| **Task Time p99** | **12,981ms** | 22,441ms | **1.7x faster** |

**Key Takeaway:** Nirvana ABS delivers **35% higher IOPS** and **1.7x faster task completion** under concurrent load, with significantly lower latency variance (64% lower p99).

### Deployment Time

| Step | Time |
|------|------|
| Terraform (provision VMs) | ~3 min |
| SSH verification | ~30 sec |
| Ansible (setup + benchmark) | ~22 min |
| **Total** | **~25 min** |

## Test Configuration

### Default Configuration

| Parameter | AWS | Nirvana |
|-----------|-----|---------|
| **Instance Type** | m5.xlarge | n1-standard-4 |
| **vCPU / RAM** | 4 vCPU / 16 GB | 4 vCPU / 16 GB |
| **Storage Type** | gp3 (General Purpose SSD) | ABS (Accelerated Block Storage) |
| **Storage Size** | 256 GB | 256 GB |
| **IOPS** | 3,000 (baseline) | Dynamic |
| **Region** | us-west-1 | us-sva-2 |

### Available Instance Classes

**AWS EC2 (m5 family):**
| Instance | vCPU | RAM | Use Case |
|----------|------|-----|----------|
| m5.large | 2 | 8 GB | Light testing |
| m5.xlarge | 4 | 16 GB | Default benchmark |
| m5.2xlarge | 8 | 32 GB | Heavy workloads |
| m5.4xlarge | 16 | 64 GB | Production scale |

**Nirvana Labs:**
| Instance | vCPU | RAM | Use Case |
|----------|------|-----|----------|
| n1-standard-2 | 2 | 8 GB | Light testing |
| n1-standard-4 | 4 | 16 GB | Default benchmark |
| n1-standard-8 | 8 | 32 GB | Heavy workloads |
| n1-standard-16 | 16 | 64 GB | Production scale |

**AWS Storage Types:**
| Type | IOPS | Throughput | Use Case |
|------|------|------------|----------|
| gp3 | 3,000-16,000 | 125-1,000 MB/s | General purpose (default) |
| gp2 | 100-16,000 | 128-250 MB/s | Legacy general purpose |
| io1/io2 | Up to 64,000 | Up to 1,000 MB/s | High-performance |

To change instance types, edit `terraform.tfvars`:
```hcl
aws_instance_type     = "m5.2xlarge"
nirvana_instance_type = "n1-standard-8"
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              LOCAL MACHINE                                   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                      │
│  │  Terraform  │───▶│  Ansible    │───▶│  Results    │                      │
│  │  (deploy)   │    │  (configure)│    │  (fetch)    │                      │
│  └─────────────┘    └──────┬──────┘    └─────────────┘                      │
└────────────────────────────┼────────────────────────────────────────────────┘
                             │ SSH
              ┌──────────────┴──────────────┐
              ▼                              ▼
┌─────────────────────────────┐  ┌─────────────────────────────┐
│      AWS (us-west-1)        │  │    NIRVANA (us-sva-2)       │
│  ┌───────────────────────┐  │  │  ┌───────────────────────┐  │
│  │      m5.xlarge        │  │  │  │    n1-standard-4      │  │
│  │   4 vCPU / 16GB RAM   │  │  │  │   4 vCPU / 16GB RAM   │  │
│  ├───────────────────────┤  │  │  ├───────────────────────┤  │
│  │    256GB gp3 SSD      │  │  │  │    256GB ABS SSD      │  │
│  │    3,000 IOPS         │  │  │  │    Dynamic IOPS       │  │
│  └───────────────────────┘  │  │  └───────────────────────┘  │
│                             │  │                             │
│  ┌───────────────────────┐  │  │  ┌───────────────────────┐  │
│  │   Docker Services     │  │  │  │   Docker Services     │  │
│  │  ┌─────┐ ┌─────┐     │  │  │  │  ┌─────┐ ┌─────┐     │  │
│  │  │Qdrant│ │Redis│     │  │  │  │  │Qdrant│ │Redis│     │  │
│  │  └─────┘ └─────┘     │  │  │  │  └─────┘ └─────┘     │  │
│  │  ┌─────────────┐     │  │  │  │  ┌─────────────┐     │  │
│  │  │  Postgres   │     │  │  │  │  │  Postgres   │     │  │
│  │  └─────────────┘     │  │  │  │  └─────────────┘     │  │
│  └───────────────────────┘  │  │  └───────────────────────┘  │
│                             │  │                             │
│  ┌───────────────────────┐  │  │  ┌───────────────────────┐  │
│  │   Benchmark Runner    │  │  │  │   Benchmark Runner    │  │
│  │  100 agents × 10 tasks│  │  │  │  100 agents × 10 tasks│  │
│  │  - Vector writes      │  │  │  │  - Vector writes      │  │
│  │  - RAG queries        │  │  │  │  - RAG queries        │  │
│  │  - Cache ops          │  │  │  │  - Cache ops          │  │
│  │  - Checkpoints        │  │  │  │  - Checkpoints        │  │
│  └───────────────────────┘  │  │  └───────────────────────┘  │
└─────────────────────────────┘  └─────────────────────────────┘
```

## What's Measured

- **IOPS**: Read/write operations per second
- **Latency**: p50/p99 for each operation type
- **Task Time**: End-to-end task completion

Each task:
1. Ingests 10 documents to Qdrant (vector writes)
2. Runs 5 RAG queries (vector reads)
3. Caches results in Redis (cache writes)
4. Saves checkpoint to Postgres (DB write)

## Manual Setup (No Ansible)

If you don't have Ansible installed:

```bash
./scripts/setup.sh
```

Then SSH into each VM and run the benchmark manually.

## Cleanup

```bash
cd terraform
terraform destroy
```

## Project Structure

```
.
├── terraform/              # Infrastructure as Code
│   ├── main.tf            # AWS + Nirvana resources
│   ├── variables.tf       # Input variables
│   └── terraform.tfvars   # Your configuration
├── ansible/
│   ├── playbook.yml       # Main playbook
│   ├── inventory/         # Generated from terraform
│   ├── group_vars/        # Platform-specific vars
│   └── roles/
│       ├── benchmark-services/  # Docker setup
│       └── benchmark-runner/    # Run benchmark on VM
├── scripts/
│   ├── generate-inventory.sh    # Create Ansible inventory
│   └── setup.sh                 # Manual setup (no Ansible)
└── results/               # Benchmark results
```

## Links

- [Nirvana Labs](https://nirvanalabs.io)
- [Nirvana Labs Documentation](https://docs.nirvanalabs.io)
- [Terraform Provider](https://registry.terraform.io/providers/nirvana-labs/nirvana/latest)
