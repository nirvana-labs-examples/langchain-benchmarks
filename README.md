# LangChain Agent Benchmark

Compares storage performance between [Nirvana Labs ABS](https://nirvanalabs.io) and AWS gp3 for LangChain agent workloads.

Runs **100 concurrent agents**, each executing **10 tasks** with vector storage (Qdrant), caching (Redis), and checkpointing (Postgres).

## Quick Start

### Prerequisites

- [Terraform](https://terraform.io) installed
- [Ansible](https://ansible.com) installed
- AWS credentials configured (`aws configure` or environment variables)
- Nirvana Labs API key (`export NIRVANA_LABS_API_KEY=...`)
- SSH key pair

### Step 1: Deploy VMs

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your SSH public key and Nirvana project ID

terraform init
terraform apply
```

This deploys both VMs simultaneously:
- **AWS**: m5.xlarge with 256GB gp3 storage (us-west-1)
- **Nirvana**: n1-standard-4 with 256GB ABS storage (us-sva-2)

#### Customizing Instance & Storage

Edit `terraform.tfvars` to test different configurations:

```hcl
# AWS - try different instance sizes or storage types
aws_instance_type      = "m5.2xlarge"   # larger instance
aws_storage_size       = 512            # more storage
aws_storage_type       = "io1"          # provisioned IOPS
aws_storage_iops       = 10000          # higher IOPS

# Nirvana - try different instance sizes
nirvana_instance_type  = "n1-standard-8"
nirvana_storage_size   = 512
```

### Step 2: Generate Ansible Inventory

```bash
./scripts/generate-inventory.sh
```

### Step 3: Verify SSH Connectivity

Before running Ansible, verify SSH access to both VMs:

```bash
# Get IPs from terraform output
AWS_IP=$(cd terraform && terraform output -raw aws_ip)
NIRVANA_IP=$(cd terraform && terraform output -raw nirvana_ip)

# Test SSH (wait ~30 seconds after terraform for VMs to boot)
ssh -o ConnectTimeout=10 ubuntu@$AWS_IP "echo 'AWS: OK'"
ssh -o ConnectTimeout=10 ubuntu@$NIRVANA_IP "echo 'Nirvana: OK'"
```

### Step 4: Run Benchmark

```bash
cd ansible && ansible-playbook playbook.yml
```

This will:
1. Install Docker and start services (Postgres, Qdrant, Redis) on both VMs
2. Run the benchmark **on each VM** (eliminates network variability)
3. Fetch results back to `ansible/results/`

## Results

Results are saved to:
- `ansible/results/aws-benchmark.json`
- `ansible/results/nirvana-benchmark.json`

### Sample Results (On-VM)

> **Note:** Results may vary based on cloud region load, time of day, and other factors. These are estimates from our testing.

| Metric | Nirvana ABS | AWS gp3 | Diff |
|--------|-------------|---------|------|
| IOPS | 77.23 | 63.10 | +22% |
| Latency p50 | 330.91ms | 413.92ms | +20% |
| Latency p99 | 509.03ms | 565.21ms | +10% |
| Task Time p50 | 5355ms | 6505ms | +18% |
| Task Time p99 | 6572ms | 7265ms | +10% |

### Deployment Time

| Step | Time |
|------|------|
| Terraform (provision VMs) | ~3 min |
| SSH verification | ~30 sec |
| Ansible (setup + benchmark) | ~22 min |
| **Total** | **~25 min** |

## Test Configuration

| Parameter | AWS | Nirvana |
|-----------|-----|---------|
| **Instance Type** | m5.xlarge (4 vCPU, 16GB RAM) | n1-standard-4 (4 vCPU, 16GB RAM) |
| **Storage Type** | gp3 (General Purpose SSD) | ABS (Accelerated Block Storage) |
| **Storage Size** | 256 GB | 256 GB |
| **IOPS** | 3,000 (baseline) | Dynamic |
| **Region** | us-west-1 | us-sva-2 |

## Architecture

```
AWS (us-west-1)                    Nirvana (us-sva-2)
+------------------+               +------------------+
| m5.xlarge        |               | n1-standard-4    |
| 256GB gp3        |               | 256GB ABS        |
+------------------+               +------------------+
| Docker Services: |               | Docker Services: |
| - Postgres       |               | - Postgres       |
| - Qdrant         |               | - Qdrant         |
| - Redis          |               | - Redis          |
+------------------+               +------------------+
| Benchmark runs   |               | Benchmark runs   |
| locally on VM    |               | locally on VM    |
+------------------+               +------------------+
        |                                  |
        +----------------------------------+
                        |
                +---------------+
                | Local Machine |
                | (Ansible)     |
                +---------------+
                | Fetches       |
                | results       |
                +---------------+
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
