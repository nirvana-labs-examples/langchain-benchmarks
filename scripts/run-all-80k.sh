#!/bin/bash
# Run all 3 scenarios x 3 runs for gp3-80k, mirroring the repo's result layout.
set -e
cd "$(dirname "$0")/../ansible"
mkdir -p logs results

run() {
  local dir=$1 agents=$2 tasks=$3 r=$4
  echo "[$(date '+%H:%M:%S')] START $dir $r (${agents}x${tasks})"
  ansible-playbook -i inventory/hosts-80k.yml playbook.yml \
    -e num_agents=$agents -e tasks_per_agent=$tasks \
    > logs/run-$dir-$r.log 2>&1
  mkdir -p results/$dir
  mv results/gp3-80k-benchmark.json results/$dir/gp3-80k-benchmark-$r.json
  mv results/gp3-80k-iostat.log results/$dir/gp3-80k-iostat-$r.log
  echo "[$(date '+%H:%M:%S')] DONE $dir $r"
}

run 100X10  100  10  r1   # includes 5M-vector preload on first run
run 100X10  100  10  r2
run 100X10  100  10  r3
run 500X20  500  20  r1
run 500X20  500  20  r2
run 500X20  500  20  r3
run 1000X10 1000 10  r1
run 1000X10 1000 10  r2
run 1000X10 1000 100 r3  # matches repo: scenario-3 r3 is 1000x100

echo "ALL RUNS COMPLETE"
