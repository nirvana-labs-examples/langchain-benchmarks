# LangChain Agent Benchmark — State-Serialization Writes on Nirvana ABS vs AWS

Write-path follow-up to the multi-tenant cold-read suite (`multi-tenant-summary` branch). Agent runtimes (LangGraph-style) serialize and commit a checkpoint after every step — small synchronous writes that must fsync before the agent proceeds. This branch benchmarks that write path on the same five storage platforms.

> The read suite showed Nirvana ABS fastest end-to-end in all 9 runs, with a per-query p99 tail that widens under sustained load while io2 stays flat. The open question this branch answers: does that tail behavior also appear on the write path, and does dynamic IOPS scaling hold predictable latency bounds under sustained write pressure?

## Platforms

Same five platforms and VM shapes as the read suite (4 vCPU / 16 GB RAM / 256 GB volume):

| Platform | Instance | Storage | Provisioned IOPS |
|----------|----------|---------|------------------|
| gp3-3k | AWS m6i.xlarge | EBS gp3 | 3,000 |
| gp3-16k | AWS m6i.xlarge | EBS gp3 | 16,000 |
| io2-32k | AWS m6i.xlarge | EBS io2 | 32,000 |
| io2-64k | AWS m6i.xlarge | EBS io2 | 64,000 (capped at 40k by instance) |
| Nirvana ABS | n1-standard-4 | ABS | Dynamic |

## Workload

The preloaded dataset is unchanged: 5M random 768d vectors across 50 Qdrant collections (`inline_storage`, INT8 scalar quantization), so writes land on realistically filled volumes.

Each task is one **checkpoint cycle**:

| Op | What it models | Disk path |
|----|----------------|-----------|
| Postgres `INSERT` + `COMMIT` | Serialize agent state to the checkpointer | WAL fsync — commit waits on disk |
| Redis `SETEX` | Latest-state pointer | AOF (fsync policy configurable) |
| Qdrant upsert (5 vectors, `wait=true`, random tenant) | Agent memory write | Qdrant WAL |

The checkpoint payload **grows with step number** — 2 KB base + 2 KB per step, capped at 64 KB — mimicking accumulating message history. Upsert IDs sit above the preloaded range and are deterministic per (agent, task), so repeat runs overwrite the same points instead of growing the dataset.

Two modes, run back-to-back:

- **write** — pure checkpoint cycles (commit-latency bound)
- **mixed** — each task first reads context (1 Qdrant query on a random tenant, 1 Redis get, 1 Postgres select) then runs the checkpoint cycle; the realistic agent-runtime shape

10 concurrent workers, matching the read suite.

## Durability configuration

On a write benchmark, the fsync policy *is* the result, so it's pinned and documented:

| Service | Setting |
|---------|---------|
| Postgres | `synchronous_commit=on` (every COMMIT waits on WAL fsync) |
| Redis | `appendonly yes`; `appendfsync` set by the `redis_appendfsync` var — default `everysec`, set `always` for a fully disk-bound Redis variant |
| Qdrant | WAL defaults, upserts with `wait=true` |

## Metrics

- Per-backend write percentiles: `postgres_commit_p50/95/99`, `redis_write_*`, `qdrant_upsert_*`
- Task time percentiles, end-to-end duration, aggregate ops/s
- **p99-over-time series** (10 s windows) for Postgres commit, Qdrant upsert, and task time — a single aggregate p99 can't distinguish "consistently 170 ms" from "150 ms with periodic 400 ms spikes"; predictable-latency claims live in this series
- fio write floor: 4k random write (O_DIRECT, QD=64×4) plus a QD=1 `--fsync=1` test — fsync latency is the number that predicts checkpoint commit latency
- Per-second `iostat -x` throughout (`w/s`, `w_await`)

## Scenarios

Same grid as the read suite for cross-referencing, three runs each:

| Scenario | Agents | Tasks/agent | Total checkpoints |
|----------|-------:|------------:|------------------:|
| Preview (default) | 500 | 20 | 10,000 |
| Small | 100 | 10 | 1,000 |
| Sustained | 1,000 | 100 | 100,000 |

The sustained run is the important one — it's where the read suite exposed Nirvana's p99 tail widening.

## Quick Start

```bash
export AWS_ACCESS_KEY_ID="..." AWS_SECRET_ACCESS_KEY="..." AWS_SESSION_TOKEN="..."
export NIRVANA_LABS_API_KEY="..."

cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit ssh_public_key + nirvana_project_id
terraform init && terraform apply

cd ../scripts && ./generate-inventory.sh
cd ../ansible && ansible-playbook -i inventory/hosts.yml playbook.yml

cd ../terraform && terraform destroy
```

Workload shape (`num_agents`, `tasks_per_agent`) and mode flags (`run_write`, `run_mixed`) live in `ansible/roles/benchmark-runner/defaults/main.yml`. Redis fsync policy (`redis_appendfsync`) lives in `ansible/roles/benchmark-services/defaults/main.yml`. The cold/hot read benchmark from the read suite is still available via `run_cold` / `run_hot` (off by default on this branch).

## Result file layout

```
ansible/results/
├── {platform}-write-benchmark.json   # pure write mode + fio write floor
├── {platform}-mixed-benchmark.json   # mixed mode + fio write floor
├── {platform}-iostat-write.log
└── {platform}-iostat-mixed.log
```

Result JSONs include a `timeseries` block with per-10s-window p99 for `postgres_commit`, `qdrant_upsert`, and `task_time`.

## Status

Harness complete; results pending first runs (preview scenario 500×20 first, then the full grid).

## Links

- [Nirvana Labs](https://nirvanalabs.io)
- [Nirvana Labs Documentation](https://docs.nirvanalabs.io)
- [Terraform Provider](https://registry.terraform.io/providers/nirvana-labs/nirvana/latest)
