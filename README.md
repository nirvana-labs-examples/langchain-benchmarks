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
├── 100X10/
│   ├── {platform}-write-benchmark-{r1,r2,r3}.json
│   ├── {platform}-mixed-benchmark-{r1,r2,r3}.json
│   └── {platform}-iostat-{write,mixed}-{r1,r2,r3}.log
├── 500X20/   (same layout)
└── 1000X100/ (same layout)
```

Result JSONs include a `timeseries` block with per-10s-window p99 for `postgres_commit`, `qdrant_upsert`, and `task_time`.

---

# Results

Two write regimes emerged and both are reported. **r1 of 500×20 and 1000×100 is the first-insert run**: the Qdrant upserts create new points, which triggers HNSW index growth and optimizer segment merges — a much heavier disk workload. **r2/r3 are steady-state overwrite runs** (deterministic IDs re-write the same points). The 100×10 runs and all mixed-mode runs after the first are effectively steady-state.

## fio write floor

AWS floors are pinned by provisioned IOPS and reproduce to within ±0.1% across all 9 runs. Nirvana has no fixed cap and its floor swings run to run.

| Platform | Random write IOPS (range) | Fsync latency (range) |
|----------|--------------------------:|----------------------:|
| gp3-3k | 3,083–3,097 | 2.73–2.75 ms |
| gp3-16k | 16,507–16,530 | 2.73–2.80 ms |
| io2-32k | 33,052–33,071 | 0.97–1.06 ms |
| io2-64k | 40,321–40,342 | 0.99–1.08 ms |
| nirvana-abs | 35,079–104,083 | 1.13–1.91 ms |

Two signals: writes are a far closer contest than reads (Nirvana's read floor was 261–313k IOPS), and **io2 beats Nirvana on raw fsync latency** (~1.0 vs ~1.1–1.9 ms) while gp3's ~2.7 ms fsync handicaps it at any provisioned IOPS.

## Scenario 1 — 100×10 (1,000 checkpoints)

| Platform | write r1 | write r2 | write r3 | mixed r1 | mixed r2 | mixed r3 |
|----------|---------:|---------:|---------:|---------:|---------:|---------:|
| **nirvana-abs** | **35s** / 542ms | **36s** / 595ms | **36s** / 529ms | **37s** / 547ms | **38s** / 563ms | **38s** / 616ms |
| io2-32k | 39s / 567ms | 39s / 552ms | 39s / 565ms | 42s / 592ms | 42s / 573ms | 41s / 569ms |
| gp3-16k | 40s / 577ms | 39s / 570ms | 40s / 569ms | 42s / 583ms | 42s / 574ms | 43s / 598ms |
| io2-64k | 40s / 569ms | 41s / 589ms | 40s / 597ms | 44s / 599ms | 44s / 608ms | 44s / 592ms |
| gp3-3k | 40s / 575ms | 39s / 579ms | 40s / 588ms | 42s / 580ms | 42s / 606ms | 43s / 570ms |

(cells: duration / task p99)

Nirvana fastest duration in all 6 runs. At this 1,000-task sample, task p99 is noisy — Nirvana wins it in 4 of 6 runs, loses r2 write and r3 mixed. gp3-3k is indistinguishable from the io2 tier: 1,000 checkpoints never saturate a 3k IOPS ceiling.

## Scenario 2 — 500×20 (10,000 checkpoints)

| Platform | write r1\* | write r2 | write r3 | mixed r1 | mixed r2 | mixed r3 |
|----------|----------:|---------:|---------:|---------:|---------:|---------:|
| **nirvana-abs** | **360s** / **553ms** | **361s** / **554ms** | **364s** / **564ms** | **372s** / **529ms** | **379s** / **540ms** | **375s** / **531ms** |
| io2-32k | 397s / 579ms | 400s / 589ms | 396s / 582ms | 429s / 606ms | 426s / 592ms | 422s / 597ms |
| gp3-16k | 405s / 594ms | 400s / 587ms | 406s / 589ms | 432s / 603ms | 428s / 596ms | 434s / 606ms |
| gp3-3k | 606s / 1,319ms | 403s / 583ms | 401s / 588ms | 427s / 602ms | 431s / 604ms | 432s / 608ms |
| io2-64k | 444s / 1,005ms | 418s / 608ms | 415s / 608ms | 445s / 623ms | 440s / 616ms | 444s / 625ms |

\* write r1 = first-insert regime. gp3-3k collapses there (606s, 1.3s task p99, 649ms Qdrant upsert p99 — the index-growth I/O saturates its 3k IOPS ceiling); in steady-state overwrites it performs like gp3-16k.

Nirvana wins duration and task p99 in all 6 runs (9–14% duration margin vs best AWS). Per-op Postgres commit p99 goes the other way at this scale: io2-32k/gp3-16k hold 78–88ms vs Nirvana's 95–105ms — same "io2 owns the per-op tail at moderate load" pattern as the read suite.

## Scenario 3 — 1000×100 sustained (100,000 checkpoints)

| Platform | write r1\* | write r2 | write r3 | mixed r1 | mixed r2 | mixed r3 |
|----------|----------:|---------:|---------:|---------:|---------:|---------:|
| **nirvana-abs** | **4,246s** / **925ms** | **4,526s** / **918ms** | **4,514s** / **919ms** | **5,203s** / **1,132ms** | **5,050s** / **994ms** | **5,012s** / **980ms** |
| io2-32k | 5,528s / 1,332ms | 6,252s / 1,378ms | 6,298s / 1,392ms | 6,727s / 1,500ms | 6,720s / 1,487ms | 6,740s / 1,488ms |
| gp3-16k | 5,567s / 1,338ms | 6,394s / 1,368ms | 6,415s / 1,389ms | 6,913s / 1,504ms | 6,886s / 1,510ms | 6,863s / 1,502ms |
| io2-64k | 5,742s / 1,382ms | 6,619s / 1,432ms | 6,672s / 1,449ms | 7,155s / 1,559ms | 7,257s / 1,562ms | 7,223s / 1,557ms |
| gp3-3k | 5,302s / 1,348ms | 5,999s / 1,375ms | 6,093s / 1,392ms | 8,812s / 2,614ms | 8,628s / 2,690ms | 8,806s / 2,642ms |

\* write r1 = first-insert regime. Note the AWS platforms all get ~13% *slower* in steady-state overwrites (segment rewrite amplification) while Nirvana absorbs the same shift with +6%.

At sustained scale the moderate-load pattern flips — Nirvana wins everything:

| Backend p99 (steady state, r2/r3) | gp3-3k | gp3-16k | io2-32k | io2-64k | nirvana-abs |
|-----------------------------------|-------:|--------:|--------:|--------:|------------:|
| Postgres commit (write mode) | 217–219ms | 212ms | 210–213ms | 224–232ms | **105–107ms** |
| Qdrant upsert (write mode) | 667–699ms | 374–386ms | 371–381ms | 395–398ms | **254–282ms** |
| Postgres commit (mixed mode) | 166–175ms | 165ms | 158–163ms | 170–171ms | **79–82ms** |

Duration margin vs best AWS: 24–28% (write), 25–27% (mixed). Task p99 margin: 33% (write), 34% (mixed). gp3-3k is the only platform where mixed is *slower* than pure-write — the added read IOPS push it over its ceiling (8,600–8,800s, 2.6s task p99).

## Tail stability under sustained load

The prospect question this suite exists to answer: does dynamic IOPS hold predictable latency bounds under sustained write pressure? Per-10s-window Postgres commit p99 across the 100K-checkpoint runs:

| Platform | Median window p99 | Worst window p99 | Worst/median |
|----------|------------------:|-----------------:|-------------:|
| nirvana-abs (steady state r2/r3) | **73–97ms** | **429–536ms** | 4.4–7.4× |
| nirvana-abs (first-insert r1) | 80–99ms | 735–964ms | 9.2–9.7× |
| io2-32k | 133–182ms | 600–678ms | 3.4–4.9× |
| io2-64k | 142–193ms | 620–744ms | 3.5–4.9× |
| gp3-16k | 140–181ms | 611–715ms | 3.4–5.1× |
| gp3-3k | 142–193ms | 566–664ms | 3.0–4.5× |

Read this carefully — it cuts both ways:

- **In relative terms, EBS is flatter.** Worst-window/median ratio is 3–5× on every AWS platform vs 4.4–9.7× on Nirvana. If your SLO is expressed as "p99 never exceeds N× typical," EBS is easier to reason about.
- **In absolute terms, Nirvana's bounds are as good or better.** In steady state its *worst* 10-second window (429–536ms) is lower than every AWS platform's worst (566–744ms), while its *typical* window is roughly half theirs. The high ratio is an artifact of the low baseline, not of taller spikes.
- The genuinely wide Nirvana tail (735–964ms worst windows) appears only in the first-insert regime — the same shared-controller queue behavior seen in the read suite's 100K-task run, triggered by index-growth I/O bursts.

## Overall takeaways

1. **Nirvana ABS wins end-to-end duration in all 18 runs** (9 write, 9 mixed), with the margin growing from ~10% at moderate load to ~25–35% at sustained 100K-checkpoint load.
2. **The moderate-load pattern mirrors the read suite**: io2/gp3-16k hold the best per-op commit tail at 10K checkpoints (io2's ~1.0ms fsync floor showing through), while Nirvana wins throughput.
3. **At sustained scale everything flips to Nirvana** — half the Postgres commit p99, lowest Qdrant upsert p99, lowest absolute worst-window latency. AWS's fixed IOPS ceilings become the constraint; dynamic IOPS absorbs the load.
4. **First-insert vs overwrite matters more than platform choice for some workloads**: index-growth write bursts are 1.5× the steady-state cost on constrained platforms (gp3-3k: 606s vs 402s at 500×20). Capacity-plan for ingest, not steady state.
5. **gp3-3k is fine until it isn't**: indistinguishable from io2 at 1K checkpoints, survivable at 10K steady-state, and 1.7× worse than everything at sustained mixed load.
6. io2-64k again buys nothing over io2-32k (instance-capped at 40k IOPS) — and was marginally slower in most write runs.

## Caveats and incident log

- **r1 of 500×20 / 1000×100 is a different (first-insert) regime** than r2/r3 (overwrite) — see Results intro. Both are legitimate workloads; compare like with like.
- **Mixed-mode reads are warm/steady-state reads** (no cache drop between the write and mixed phases), unlike the cold-read suite.
- **1000×100 r2 protocol deviations**: the Ansible controller (a laptop) slept mid-run, stretching the gap between the write and mixed phases to ~18h on the AWS hosts (benchmarks themselves ran uninterrupted on the VMs — durations are VM-side and unaffected). Nirvana's r2 mixed leg is a standalone re-run (see below); its r1/r3 runs are protocol-clean and agree with it.
- **Security incident (2026-07-05)**: the original Terraform exposed Redis/Postgres/Qdrant to 0.0.0.0/0. Internet scan bots wrote foreign keys into Redis on four hosts and flipped Nirvana's Redis to read-only replica mode mid-run (crashing one mixed leg, which was re-run). Remediation: all service ports now bind to 127.0.0.1 (committed), tainted Redis/Postgres volumes recreated, Qdrant dataset verified intact (5.5M vectors exactly). Published numbers are unaffected — the crashed run produced no data. Follow-up: tighten SG/firewall ingress in Terraform.
- Nirvana's fio write floor varies 35k–104k IOPS run to run (no provisioned cap); its application-level results are nonetheless the most stable of any platform (≤2% duration spread in steady state).

## Links

- [Nirvana Labs](https://nirvanalabs.io)
- [Nirvana Labs Documentation](https://docs.nirvanalabs.io)
- [Terraform Provider](https://registry.terraform.io/providers/nirvana-labs/nirvana/latest)
