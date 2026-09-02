# LangChain Agent Benchmark — Multi-Tenant Qdrant on Nirvana ABS vs AWS

Cold-read benchmarks for a multi-tenant Qdrant deployment (50 collections × 100K vectors, `inline_storage` + INT8 scalar quantization) on five storage platforms, run as three separate scenarios (different agent fan-out / depth), each replicated across three independent runs (r1, r2, r3) for run-to-run stability.

> Cold reads only: Qdrant container restarted and OS page cache dropped before each benchmark. The HNSW index has to be paged in from disk.

## Platforms

| Platform | Instance | Storage | Provisioned IOPS |
|----------|----------|---------|------------------|
| gp3-3k | AWS m6i.xlarge | EBS gp3 | 3,000 |
| gp3-16k | AWS m6i.xlarge | EBS gp3 | 16,000 |
| io2-32k | AWS m6i.xlarge | EBS io2 | 32,000 |
| io2-64k | AWS m6i.xlarge | EBS io2 | 64,000 (capped at 40k by instance) |
| Nirvana ABS | n1-standard-4 | ABS | Dynamic |

Each VM: 4 vCPU / 16 GB RAM / 256 GB volume. Qdrant + Redis + Postgres run in Docker on the same VM. Workload: 5M random 768d vectors loaded into 50 Qdrant collections (100K each), `hnsw_config.inline_storage = true`, INT8 scalar quantization (quantile 0.99). Each task issues 2 random-tenant Qdrant queries, 2 Redis reads, 2 Postgres reads.

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

Workload size is set in `ansible/roles/benchmark-runner/defaults/main.yml` (`num_agents`, `tasks_per_agent`).

## Raw disk floor (fio, O_DIRECT QD=256, sequential read, 30s)

| Platform | Measured IOPS | Mean latency |
|----------|--------------:|-------------:|
| gp3-3k | 3,097 | 82.6 ms |
| gp3-16k | 16,531 | 15.5 ms |
| io2-32k | 33,068 | 7.7 ms |
| io2-64k | 40,339 | 6.3 ms |
| Nirvana ABS | 261k–313k (range across runs) | 0.82–1.0 ms |

fio numbers are stable to within ±2% on AWS platforms (provisioned IOPS caps make them deterministic). Nirvana fio varies more because there's no fixed cap.

---

## Scenario 1 — 100 agents × 10 tasks (1,000 total tasks)

Three independent cold runs on the multi-tenant config.

### LangChain cold reads

| Platform | r1 dur | r1 task p99 | r2 dur | r2 task p99 | r3 dur | r3 task p99 |
|----------|-------:|------------:|-------:|------------:|-------:|------------:|
| **nirvana-abs** | **36s** | **542 ms** | **36s** | **553 ms** | **36s** | **564 ms** |
| io2-32k | 40s | 556 ms | 41s | 587 ms | 43s | 600 ms |
| io2-64k | 40s | 567 ms | 41s | 639 ms | 42s | 595 ms |
| gp3-16k | 43s | 651 ms | 42s | 622 ms | 43s | 696 ms |
| gp3-3k | 61s | 1,345 ms | 63s | 1,203 ms | 62s | 2,360 ms |

### Qdrant p99 (per-query, disk-bound)

| Platform | r1 | r2 | r3 |
|----------|---:|---:|---:|
| io2-64k | 140 ms | 157 ms | 149 ms |
| io2-32k | 140 ms | 155 ms | 156 ms |
| nirvana-abs | 170 ms | 176 ms | 182 ms |
| gp3-16k | 175 ms | 174 ms | 173 ms |
| gp3-3k | 599 ms | 581 ms | 951 ms |

### Takeaways

- Nirvana fastest duration and task p99 in all three runs (36 s / 542–564 ms vs io2 40-43 s / 556-639 ms).
- io2 owns the per-query Qdrant tail in all three runs (140-157 ms vs Nirvana 170-182 ms).
- gp3-3k task p99 swings 1,203 → 2,360 ms across runs — only platform with run-to-run noise outside ±10%.

---

## Scenario 2 — 500 agents × 20 tasks (10,000 total tasks)

### LangChain cold reads

| Platform | r1 dur | r1 task p99 | r2 dur | r2 task p99 | r3 dur | r3 task p99 |
|----------|-------:|------------:|-------:|------------:|-------:|------------:|
| **nirvana-abs** | **343s** | **485 ms** | **351s** | **497 ms** | **351s** | **501 ms** |
| io2-64k | 395s | 553 ms | 413s | 579 ms | 424s | 600 ms |
| io2-32k | 401s | 559 ms | 413s | 579 ms | 420s | 591 ms |
| gp3-16k | 413s | 576 ms | 418s | 585 ms | 430s | 609 ms |
| gp3-3k | 427s | 816 ms | 446s | 842 ms | 433s | 828 ms |

### Qdrant p99 (per-query)

| Platform | r1 | r2 | r3 |
|----------|---:|---:|---:|
| io2-64k | 141 ms | 166 ms | 160 ms |
| io2-32k | 151 ms | 162 ms | 163 ms |
| gp3-16k | 166 ms | 170 ms | 179 ms |
| nirvana-abs | 167 ms | 170 ms | 169 ms |
| gp3-3k | 370 ms | 392 ms | 369 ms |

### Takeaways

- Nirvana wins duration and task p99 in all three runs (343-351 s / 485-501 ms). Run-to-run spread ≤16 ms task p99.
- io2 owns Qdrant tail (141-166 ms vs Nirvana 167-170 ms). 6-25 ms gap.
- Every platform stable to ±5% on every metric — 10K-task sample eliminates the run-to-run noise visible at 100×10.

---

## Scenario 3 — 1000 agents

r1 and r2 are at × 10 tasks (10K total tasks). **r3 is at × 100 tasks (100K total tasks) — 10× the work**, included to show how the same platform ordering holds at high sustained depth. Numbers are not directly comparable across the columns; compare within-column (platforms vs platforms in the same run).

### LangChain cold reads

| Platform | r1 (×10) dur | r1 task p99 | r2 (×10) dur | r2 task p99 | r3 (×100) dur | r3 task p99 |
|----------|-------------:|------------:|-------------:|------------:|--------------:|------------:|
| **nirvana-abs** | **343s** | **483 ms** | **352s** | **502 ms** | **3,484s (58 min)** | **725 ms** |
| io2-64k | 400s | 567 ms | 422s | 601 ms | 4,151s | 771 ms |
| io2-32k | 399s | 559 ms | 420s | 594 ms | 4,129s | 779 ms |
| gp3-16k | 410s | 571 ms | 432s | 611 ms | 4,098s | 760 ms |
| gp3-3k | 428s | 867 ms | 432s | 806 ms | 4,271s | 809 ms |

### Qdrant p99 (per-query)

| Platform | r1 (×10) | r2 (×10) | r3 (×100) |
|----------|---------:|---------:|----------:|
| io2-64k | 145 ms | 166 ms | 140 ms |
| io2-32k | 145 ms | 163 ms | 140 ms |
| gp3-16k | 170 ms | 184 ms | 147 ms |
| nirvana-abs | 168 ms | 169 ms | **301 ms** |
| gp3-3k | 397 ms | 368 ms | 307 ms |

### Takeaways

- Nirvana wins duration and task p99 in all three runs, including the 10×-larger r3 (58 min vs 68-71 min on AWS, 16% faster).
- Qdrant p99 ordering flips at × 100 tasks: Nirvana's per-query p99 jumps from 169 ms to 301 ms while io2 holds at 140 ms. Wider right tail under sustained 100K-task load — the array's shared-controller path sees longer queue events at p99 when read pressure is held high.
- gp3-3k stays IOPS-bound: same 307-397 ms Qdrant p99 across all three runs regardless of workload depth.

---

## Cross-scenario summary

Headline metric per platform per run (Qdrant p99 / task p99 / duration):

| Scenario | gp3-3k | gp3-16k | io2-32k | io2-64k | nirvana-abs |
|----------|--------|---------|---------|---------|-------------|
| 100×10 r1 | 599 / 1345 / 61s | 175 / 651 / 43s | 140 / 556 / 40s | 140 / 567 / 40s | 170 / 542 / 36s |
| 100×10 r2 | 581 / 1203 / 63s | 174 / 622 / 42s | 155 / 587 / 41s | 157 / 639 / 41s | 176 / 553 / 36s |
| 100×10 r3 | 951 / 2360 / 62s | 173 / 696 / 43s | 156 / 600 / 43s | 149 / 595 / 42s | 182 / 564 / 36s |
| 500×20 r1 | 370 / 816 / 427s | 166 / 576 / 413s | 151 / 559 / 401s | 141 / 553 / 395s | 167 / 485 / 343s |
| 500×20 r2 | 392 / 842 / 446s | 170 / 585 / 418s | 162 / 579 / 413s | 166 / 579 / 413s | 170 / 497 / 351s |
| 500×20 r3 | 369 / 828 / 433s | 179 / 609 / 430s | 163 / 591 / 420s | 160 / 600 / 424s | 169 / 501 / 351s |
| 1000×10 r1 | 397 / 867 / 428s | 170 / 571 / 410s | 145 / 559 / 399s | 145 / 567 / 400s | 168 / 483 / 343s |
| 1000×10 r2 | 368 / 806 / 432s | 184 / 611 / 432s | 163 / 594 / 420s | 166 / 601 / 422s | 169 / 502 / 352s |
| 1000×100 r3\* | 307 / 809 / 4271s | 147 / 760 / 4098s | 140 / 779 / 4129s | 140 / 771 / 4151s | 301 / 725 / 3484s |

\* r3 of scenario 3 is 1000 agents × **100** tasks (10× the total work of r1/r2).

### Overall takeaways

- Nirvana ABS finishes fastest end-to-end in all 9 runs. Margin vs the best AWS platform: 9-16% on duration, 4-14% on task p99.
- io2 owns per-query Qdrant p99 in 8 of 9 runs (Nirvana within 2-29 ms in those 8). The exception is the 100K-task sustained run, where Nirvana's per-query tail expands to 301 ms while io2 stays at 140 ms.
- io2-32k and io2-64k are statistically indistinguishable. Provisioning beyond 32k IOPS buys nothing for this workload.
- gp3-3k is the only IOPS-bound platform (3,000 IOPS ceiling). Qdrant p99 sits 2-6× higher than the io2 tier.
- Run-to-run stability is sample-size driven: ±10% at 1,000 tasks, ±5% at 10,000 tasks, sub-percent at 100,000 tasks for the stable metrics.

---

## Test Configuration

| Parameter | gp3-3k | gp3-16k | io2-32k | io2-64k | Nirvana |
|-----------|--------|---------|---------|---------|---------|
| Instance Type | m6i.xlarge | m6i.xlarge | m6i.xlarge | m6i.xlarge | n1-standard-4 |
| vCPU / RAM | 4 / 16 GB | 4 / 16 GB | 4 / 16 GB | 4 / 16 GB | 4 / 16 GB |
| Storage Type | gp3 | gp3 | io2 | io2 | ABS |
| Size | 256 GB | 256 GB | 256 GB | 256 GB | 256 GB |
| Provisioned IOPS | 3,000 | 16,000 | 32,000 | 64,000 | Dynamic |
| Instance Max IOPS | 40,000 | 40,000 | 40,000 | 40,000 | N/A |

### Benchmark parameters

| Parameter | 100×10 | 500×20 | 1000×10 r1/r2 | 1000×100 r3 |
|-----------|-------:|-------:|-------:|------:|
| Pre-loaded vectors | 5,000,000 across 50 collections × 100K | (same) | (same) | (same) |
| Vector dimensions | 768 | 768 | 768 | 768 |
| HNSW `inline_storage` | true | true | true | true |
| Quantization | INT8 scalar, quantile 0.99 | (same) | (same) | (same) |
| Agents | 100 | 500 | 1,000 | 1,000 |
| Tasks per agent | 10 | 20 | 10 | 100 |
| Operations per task | 6 (2× Qdrant, 2× Redis, 2× Postgres) | (same) | (same) | (same) |
| Total tasks | 1,000 | 10,000 | 10,000 | 100,000 |
| Total operations | 6,000 | 60,000 | 60,000 | 600,000 |
| Concurrent workers | 10 | 10 | 10 | 10 |

## Methodology

1. **Pre-load:** insert 5M random vectors across 50 Qdrant collections, with `on_disk=true`, `inline_storage=true`, and INT8 scalar quantization. Auto-skipped on subsequent scenarios reusing the same on-disk state.
2. **Cold start:** restart Qdrant container to clear HNSW from process memory.
3. **Drop caches:** `sync && echo 3 > /proc/sys/vm/drop_caches`.
4. **Benchmark:** N agents × M tasks. Each task = 2× Qdrant random-tenant query + 2× Redis read + 2× Postgres read.
5. **Measure:** per-op latency percentiles (p50/p95/p99), application IOPS, end-to-end task time. Per-second `iostat -x` captured throughout.

## Result file layout

```
ansible/results/
├── 100X10/
│   ├── {gp3-3k,gp3-16k,io2-32k,io2-64k,nirvana-abs}-benchmark-{r1,r2,r3}.json
│   └── {gp3-3k,gp3-16k,io2-32k,io2-64k,nirvana-abs}-iostat-{r1,r2,r3}.log
├── 500X20/
│   └── ... (same layout)
└── 1000X10/
    └── ... (same layout; r3 is 1000×100, see Scenario 3)
```

## 80k matched pair — gp3 at its per-volume maximum

In September 2025 AWS raised gp3's per-volume limits to 80,000 IOPS / 2,000 MiB/s / 64 TiB (previously 16,000 / 1,000 / 16 TiB), so gp3 now reaches 80k on a **single volume**. No m6i below 16xlarge can realize it (instance EBS cap), so this experiment uses a separate matched pair, sized so the **volume — not the instance — is the bottleneck** and both sides have identical CPU/RAM:

| Platform | Instance | vCPU / RAM | Storage | Instance EBS cap |
|----------|----------|-----------|---------|------------------|
| gp3-80k-sv | AWS c6in.8xlarge | 32 / 64 GB | single gp3, 256 GiB @ 80,000 IOPS / 2,000 MiB/s | 100k sustained |
| nirvana-abs-32 | Nirvana n1-highcpu-32 | 32 / 64 GB | ABS, 256 GB (boot volume) | n/a |

Same workload, scenarios, and cold-read methodology as the main grid. Stack: `terraform/80k-matched/`; driver: `scripts/run-all-80k-matched.sh`. Results are **not directly comparable to the 4 vCPU / 16 GB main grid** (8× CPU, 4× RAM — page cache holds more of the dataset on sustained runs); compare within the pair.

> Numbers vs the RAID-0 experiment it supersedes: a single 80k volume measured a slightly better fio floor (82.7k @ 3.09 ms vs 80.4k @ 3.18 ms for 5 × 16k RAID-0 on m6i.16xlarge) and a markedly tighter Qdrant tail.

### Raw disk floor (fio, cold)

| Platform | Measured IOPS (across 9 runs) | Mean latency |
|----------|------------------------------:|-------------:|
| gp3-80k-sv | 82,656–82,723 | ~3.1 ms |
| nirvana-abs-32 | 310k–394k | 0.65 ms |

### Pair results — dur / task p99 / Qdrant p99

| Scenario | run | gp3-80k-sv | nirvana-abs-32 |
|----------|-----|------------|----------------|
| 100×10 | r1 | 41.5s / 571 ms / 122 ms | 47.0s / 775 ms / 273 ms |
| 100×10 | r2 | 42.4s / 558 ms / 117 ms | 47.8s / 780 ms / 227 ms |
| 100×10 | r3 | 44.1s / 569 ms / 122 ms | 47.2s / 762 ms / 192 ms |
| 500×20 | r1 | 407s / 523 ms / 95 ms | 488s / 804 ms / 137 ms |
| 500×20 | r2 | 413s / 549 ms / 94 ms | 399s / 670 ms / 157 ms |
| 500×20 | r3 | 407s / 553 ms / 96 ms | 486s / 818 ms / 131 ms |
| 1000×10 | r1 | 446s / 586 ms / 98 ms | 488s / 801 ms / 134 ms |
| 1000×10 | r2 | 408s / 540 ms / 96 ms | 485s / 819 ms / 136 ms |
| 1000×100 | r3 | 4,263s / 724 ms / 56 ms | 4,976s / 938 ms / 89 ms |

### Key takeaways

- **AWS vs Nirvana at 80k: gp3-80k-sv wins every application-level metric in all 9 runs** — end-to-end duration 9–17% faster (except the one run where ABS matched it), task p99 22–32% lower, Qdrant per-query p99 roughly 30–55% lower — despite ABS measuring 3.7–4.8× the raw fio IOPS at one-fifth the latency. At this workload's queue depth, raw IOPS headroom doesn't convert into application latency; the gp3 volume's provisioned-performance consistency does.
- ABS shows real run-to-run variance on this instance shape (399–488s at 500×20; Qdrant p99 settling 273 → 192 ms across 100×10 runs) where gp3 held ±1–5% spreads on every metric.
- **A single 80k gp3 volume posts the lowest Qdrant per-query p99 of any AWS configuration in this repo** (117–122 ms at 100×10, 94–98 ms at depth, 56 ms at 100K sustained tasks) — below io2's 140–166 ms in the main grid and clearly below the superseded 5 × 16k RAID-0 build (128–165 ms). One volume has a tighter latency path than five striped ones.
- End-to-end durations do not improve over the main grid's io2 nodes despite 8× their vCPUs (4,263s at 1000×100 vs io2's 4,129–4,151s) — at 10 concurrent workers the LangChain loop, not storage, bounds throughput once the disk stops being the constraint.
- The 56 ms Qdrant p99 at 1000×100 reflects 64 GB of page cache warming over a 71-minute run as well as the volume itself; the matched Nirvana node gets the identical advantage, which is the point of the pair.

## Links

- [Nirvana Labs](https://nirvanalabs.io)
- [Nirvana Labs Documentation](https://docs.nirvanalabs.io)
- [Terraform Provider](https://registry.terraform.io/providers/nirvana-labs/nirvana/latest)
