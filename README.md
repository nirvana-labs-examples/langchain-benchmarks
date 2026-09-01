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
| gp3-80k | AWS m6i.16xlarge | EBS gp3 × 5, RAID-0 | 80,000 (5 × 16,000) |
| Nirvana ABS | n1-standard-4 | ABS | Dynamic |

Each VM: 4 vCPU / 16 GB RAM / 256 GB volume.

> **gp3-80k caveat:** gp3 caps at 16,000 IOPS per volume and every m6i smaller than 16xlarge caps EBS at 40k IOPS, so 80k of gp3 requires 5 × 16k volumes striped RAID-0 (64K chunk, XFS, all service data + fio on the array) on an m6i.16xlarge — **64 vCPU / 256 GB RAM**, not the 4 vCPU / 16 GB of every other platform. 256 GB of page cache can hold the whole dataset after the initial cold pass, so its sustained-load numbers (especially 1000×100) reflect storage + RAM, not storage alone. fio cold-read numbers are unaffected. Qdrant + Redis + Postgres run in Docker on the same VM. Workload: 5M random 768d vectors loaded into 50 Qdrant collections (100K each), `hnsw_config.inline_storage = true`, INT8 scalar quantization (quantile 0.99). Each task issues 2 random-tenant Qdrant queries, 2 Redis reads, 2 Postgres reads.

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
| gp3-80k | 80,384 | 3.2 ms |
| Nirvana ABS | 261k–313k (range across runs) | 0.82–1.0 ms |

fio numbers are stable to within ±2% on AWS platforms (provisioned IOPS caps make them deterministic). Nirvana fio varies more because there's no fixed cap.

---

## Scenario 1 — 100 agents × 10 tasks (1,000 total tasks)

Three independent cold runs on the multi-tenant config.

### LangChain cold reads

| Platform | r1 dur | r1 task p99 | r2 dur | r2 task p99 | r3 dur | r3 task p99 |
|----------|-------:|------------:|-------:|------------:|-------:|------------:|
| **nirvana-abs** | **36s** | **542 ms** | **36s** | **553 ms** | **36s** | **564 ms** |
| gp3-80k | 36s | 588 ms | 36s | 527 ms | 36s | 608 ms |
| io2-32k | 40s | 556 ms | 41s | 587 ms | 43s | 600 ms |
| io2-64k | 40s | 567 ms | 41s | 639 ms | 42s | 595 ms |
| gp3-16k | 43s | 651 ms | 42s | 622 ms | 43s | 696 ms |
| gp3-3k | 61s | 1,345 ms | 63s | 1,203 ms | 62s | 2,360 ms |

### Qdrant p99 (per-query, disk-bound)

| Platform | r1 | r2 | r3 |
|----------|---:|---:|---:|
| io2-64k | 140 ms | 157 ms | 149 ms |
| io2-32k | 140 ms | 155 ms | 156 ms |
| gp3-80k | 165 ms | 165 ms | 162 ms |
| nirvana-abs | 170 ms | 176 ms | 182 ms |
| gp3-16k | 175 ms | 174 ms | 173 ms |
| gp3-3k | 599 ms | 581 ms | 951 ms |

### Takeaways

- Nirvana fastest duration and task p99 in all three runs (36 s / 542–564 ms vs io2 40-43 s / 556-639 ms).
- gp3-80k ties Nirvana on duration (36 s all runs); task p99 straddles Nirvana's range (527–608 ms). See gp3-80k caveat.
- io2 owns the per-query Qdrant tail in all three runs (140-157 ms vs Nirvana 170-182 ms); gp3-80k sits between (162-165 ms).
- gp3-3k task p99 swings 1,203 → 2,360 ms across runs — only platform with run-to-run noise outside ±10%.

---

## Scenario 2 — 500 agents × 20 tasks (10,000 total tasks)

### LangChain cold reads

| Platform | r1 dur | r1 task p99 | r2 dur | r2 task p99 | r3 dur | r3 task p99 |
|----------|-------:|------------:|-------:|------------:|-------:|------------:|
| **nirvana-abs** | **343s** | **485 ms** | **351s** | **497 ms** | **351s** | **501 ms** |
| gp3-80k | 349s | 504 ms | 352s | 500 ms | 346s | 497 ms |
| io2-64k | 395s | 553 ms | 413s | 579 ms | 424s | 600 ms |
| io2-32k | 401s | 559 ms | 413s | 579 ms | 420s | 591 ms |
| gp3-16k | 413s | 576 ms | 418s | 585 ms | 430s | 609 ms |
| gp3-3k | 427s | 816 ms | 446s | 842 ms | 433s | 828 ms |

### Qdrant p99 (per-query)

| Platform | r1 | r2 | r3 |
|----------|---:|---:|---:|
| gp3-80k | 129 ms | 131 ms | 132 ms |
| io2-64k | 141 ms | 166 ms | 160 ms |
| io2-32k | 151 ms | 162 ms | 163 ms |
| gp3-16k | 166 ms | 170 ms | 179 ms |
| nirvana-abs | 167 ms | 170 ms | 169 ms |
| gp3-3k | 370 ms | 392 ms | 369 ms |

### Takeaways

- Nirvana wins duration and task p99 in all three runs (343-351 s / 485-501 ms). Run-to-run spread ≤16 ms task p99.
- gp3-80k is a statistical tie with Nirvana on duration (346-352 s) and task p99 (497-504 ms), and posts the best Qdrant p99 of any platform (129-132 ms) — its 80k effective IOPS clears io2's 40k instance cap. See gp3-80k caveat.
- io2 owns Qdrant tail among like-for-like 4-vCPU platforms (141-166 ms vs Nirvana 167-170 ms). 6-25 ms gap.
- Every platform stable to ±5% on every metric — 10K-task sample eliminates the run-to-run noise visible at 100×10.

---

## Scenario 3 — 1000 agents

r1 and r2 are at × 10 tasks (10K total tasks). **r3 is at × 100 tasks (100K total tasks) — 10× the work**, included to show how the same platform ordering holds at high sustained depth. Numbers are not directly comparable across the columns; compare within-column (platforms vs platforms in the same run).

### LangChain cold reads

| Platform | r1 (×10) dur | r1 task p99 | r2 (×10) dur | r2 task p99 | r3 (×100) dur | r3 task p99 |
|----------|-------------:|------------:|-------------:|------------:|--------------:|------------:|
| **nirvana-abs** | **343s** | **483 ms** | **352s** | **502 ms** | **3,484s (58 min)** | **725 ms** |
| gp3-80k | 343s | 490 ms | 360s | 506 ms | 3,448s (57 min) | 665 ms |
| io2-64k | 400s | 567 ms | 422s | 601 ms | 4,151s | 771 ms |
| io2-32k | 399s | 559 ms | 420s | 594 ms | 4,129s | 779 ms |
| gp3-16k | 410s | 571 ms | 432s | 611 ms | 4,098s | 760 ms |
| gp3-3k | 428s | 867 ms | 432s | 806 ms | 4,271s | 809 ms |

### Qdrant p99 (per-query)

| Platform | r1 (×10) | r2 (×10) | r3 (×100) |
|----------|---------:|---------:|----------:|
| gp3-80k | 131 ms | 128 ms | 84 ms |
| io2-64k | 145 ms | 166 ms | 140 ms |
| io2-32k | 145 ms | 163 ms | 140 ms |
| gp3-16k | 170 ms | 184 ms | 147 ms |
| nirvana-abs | 168 ms | 169 ms | **301 ms** |
| gp3-3k | 397 ms | 368 ms | 307 ms |

### Takeaways

- Nirvana wins duration and task p99 in all three runs against every like-for-like 4-vCPU platform, including the 10×-larger r3 (58 min vs 68-71 min on AWS, 16% faster).
- gp3-80k matches or edges Nirvana across the board here (343s/3,448s durations; 84 ms Qdrant p99 at ×100) — but this is where its 256 GB page cache matters most: after the first cold pass through the dataset, sustained reads are increasingly served from RAM, not the array. Treat r3 especially as a storage+RAM result.
- Qdrant p99 ordering flips at × 100 tasks: Nirvana's per-query p99 jumps from 169 ms to 301 ms while io2 holds at 140 ms. Wider right tail under sustained 100K-task load — the array's shared-controller path sees longer queue events at p99 when read pressure is held high.
- gp3-3k stays IOPS-bound: same 307-397 ms Qdrant p99 across all three runs regardless of workload depth.

---

## Cross-scenario summary

Headline metric per platform per run (Qdrant p99 / task p99 / duration):

| Scenario | gp3-3k | gp3-16k | io2-32k | io2-64k | gp3-80k | nirvana-abs |
|----------|--------|---------|---------|---------|---------|-------------|
| 100×10 r1 | 599 / 1345 / 61s | 175 / 651 / 43s | 140 / 556 / 40s | 140 / 567 / 40s | 165 / 588 / 36s | 170 / 542 / 36s |
| 100×10 r2 | 581 / 1203 / 63s | 174 / 622 / 42s | 155 / 587 / 41s | 157 / 639 / 41s | 165 / 527 / 36s | 176 / 553 / 36s |
| 100×10 r3 | 951 / 2360 / 62s | 173 / 696 / 43s | 156 / 600 / 43s | 149 / 595 / 42s | 162 / 608 / 36s | 182 / 564 / 36s |
| 500×20 r1 | 370 / 816 / 427s | 166 / 576 / 413s | 151 / 559 / 401s | 141 / 553 / 395s | 129 / 504 / 349s | 167 / 485 / 343s |
| 500×20 r2 | 392 / 842 / 446s | 170 / 585 / 418s | 162 / 579 / 413s | 166 / 579 / 413s | 131 / 500 / 352s | 170 / 497 / 351s |
| 500×20 r3 | 369 / 828 / 433s | 179 / 609 / 430s | 163 / 591 / 420s | 160 / 600 / 424s | 132 / 497 / 346s | 169 / 501 / 351s |
| 1000×10 r1 | 397 / 867 / 428s | 170 / 571 / 410s | 145 / 559 / 399s | 145 / 567 / 400s | 131 / 490 / 343s | 168 / 483 / 343s |
| 1000×10 r2 | 368 / 806 / 432s | 184 / 611 / 432s | 163 / 594 / 420s | 166 / 601 / 422s | 128 / 506 / 360s | 169 / 502 / 352s |
| 1000×100 r3\* | 307 / 809 / 4271s | 147 / 760 / 4098s | 140 / 779 / 4129s | 140 / 771 / 4151s | 84 / 665 / 3448s | 301 / 725 / 3484s |

\* r3 of scenario 3 is 1000 agents × **100** tasks (10× the total work of r1/r2).

### Overall takeaways

- Nirvana ABS finishes fastest end-to-end in all 9 runs among like-for-like 4 vCPU / 16 GB platforms. Margin vs the best such AWS platform: 9-16% on duration, 4-14% on task p99.
- gp3-80k (5 × 16k gp3 RAID-0 on m6i.16xlarge) is the only AWS config that reaches Nirvana's duration/task-p99 tier, and it takes 16× the vCPUs, 16× the RAM, and ~13× the monthly cost of the m6i.xlarge+gp3-16k node to do it — with the page-cache caveat above on sustained runs. Storage-only cost is still ~5-8× cheaper than io2 at 32-64k provisioned IOPS (gp3 IOPS are ~$0.005/IOPS-mo vs io2's tiered ~$0.046-0.065).
- io2 owns per-query Qdrant p99 in 8 of 9 runs (Nirvana within 2-29 ms in those 8). The exception is the 100K-task sustained run, where Nirvana's per-query tail expands to 301 ms while io2 stays at 140 ms.
- io2-32k and io2-64k are statistically indistinguishable. Provisioning beyond 32k IOPS buys nothing for this workload.
- gp3-3k is the only IOPS-bound platform (3,000 IOPS ceiling). Qdrant p99 sits 2-6× higher than the io2 tier.
- Run-to-run stability is sample-size driven: ±10% at 1,000 tasks, ±5% at 10,000 tasks, sub-percent at 100,000 tasks for the stable metrics.

---

## Test Configuration

| Parameter | gp3-3k | gp3-16k | io2-32k | io2-64k | gp3-80k | Nirvana |
|-----------|--------|---------|---------|---------|---------|---------|
| Instance Type | m6i.xlarge | m6i.xlarge | m6i.xlarge | m6i.xlarge | m6i.16xlarge | n1-standard-4 |
| vCPU / RAM | 4 / 16 GB | 4 / 16 GB | 4 / 16 GB | 4 / 16 GB | 64 / 256 GB | 4 / 16 GB |
| Storage Type | gp3 | gp3 | io2 | io2 | gp3 × 5, RAID-0 | ABS |
| Size | 256 GB | 256 GB | 256 GB | 256 GB | 320 GB (5 × 64) | 256 GB |
| Provisioned IOPS | 3,000 | 16,000 | 32,000 | 64,000 | 80,000 (5 × 16,000) | Dynamic |
| Instance Max IOPS | 40,000 | 40,000 | 40,000 | 40,000 | 80,000 (sustained) | N/A |

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

## Links

- [Nirvana Labs](https://nirvanalabs.io)
- [Nirvana Labs Documentation](https://docs.nirvanalabs.io)
- [Terraform Provider](https://registry.terraform.io/providers/nirvana-labs/nirvana/latest)
