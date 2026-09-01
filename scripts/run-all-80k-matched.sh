#!/bin/bash
# 80k matched-pair grid: gp3-80k-sv (AWS) and nirvana-abs-32 side by side.
# Each side is its own terraform stack (terraform/80k-matched/{aws,nirvana})
# so they can be provisioned and benchmarked independently — any side whose
# stack has no output is simply skipped. Ansible runs present hosts in parallel.
set -e
cd "$(dirname "$0")/.."

AWS_IP=$(terraform -chdir=terraform/80k-matched/aws output -raw gp3_80k_sv_ip 2>/dev/null || true)
NIRVANA_IP=$(terraform -chdir=terraform/80k-matched/nirvana output -raw nirvana_32_ip 2>/dev/null || true)
[ -n "$AWS_IP" ] || [ -n "$NIRVANA_IP" ] || { echo "no terraform outputs found — apply a stack first"; exit 1; }

PLATFORMS=()
mkdir -p ansible/inventory ansible/logs ansible/results
{
  echo "all:"
  echo "  children:"
  if [ -n "$AWS_IP" ]; then
    echo "    aws:"
    echo "      hosts:"
    echo "        gp3-80k-sv:"
    echo "          ansible_host: ${AWS_IP}"
    echo "          ansible_user: ubuntu"
    echo "          platform_name: gp3-80k-sv"
  fi
  if [ -n "$NIRVANA_IP" ]; then
    echo "    nirvana:"
    echo "      hosts:"
    echo "        nirvana-abs-32:"
    echo "          ansible_host: ${NIRVANA_IP}"
    echo "          ansible_user: ubuntu"
    echo "          platform_name: nirvana-abs-32"
  fi
} > ansible/inventory/hosts-80k-matched.yml
[ -n "$AWS_IP" ] && PLATFORMS+=(gp3-80k-sv)
[ -n "$NIRVANA_IP" ] && PLATFORMS+=(nirvana-abs-32)
echo "inventory: aws=${AWS_IP:-skipped} nirvana=${NIRVANA_IP:-skipped}"

wait_ssh() {
  for i in $(seq 1 40); do
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes ubuntu@$1 "$2" 2>/dev/null && return 0
    sleep 10
  done
  echo "SSH/readiness FAILED for $1"; return 1
}
[ -n "$AWS_IP" ] && { wait_ssh "$AWS_IP" "test -f /opt/.disk-ready" || exit 1; }
[ -n "$NIRVANA_IP" ] && { wait_ssh "$NIRVANA_IP" "exit" || exit 1; }
echo "hosts ready"

cd ansible
run() {
  local dir=$1 agents=$2 tasks=$3 r=$4
  echo "[$(date '+%H:%M:%S')] START $dir $r (${agents}x${tasks})"
  ansible-playbook -i inventory/hosts-80k-matched.yml playbook.yml \
    -e num_agents=$agents -e tasks_per_agent=$tasks \
    > logs/run-80km-$dir-$r.log 2>&1
  mkdir -p results/$dir
  for p in "${PLATFORMS[@]}"; do
    mv results/$p-benchmark.json results/$dir/$p-benchmark-$r.json
    mv results/$p-iostat.log results/$dir/$p-iostat-$r.log
  done
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
run 1000X10 1000 100 r3  # scenario-3 r3 is 1000x100, matching the main grid

echo "ALL RUNS COMPLETE"
