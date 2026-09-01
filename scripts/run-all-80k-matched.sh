#!/bin/bash
# 80k matched-pair grid: gp3-80k-sv (AWS) and nirvana-abs-32 side by side.
# Generates the inventory from terraform output, waits for both hosts,
# then runs all 3 scenarios x 3 runs. Ansible runs both hosts in parallel.
set -e
cd "$(dirname "$0")/.."
TF=terraform/80k-matched

AWS_IP=$(terraform -chdir=$TF output -raw gp3_80k_sv_ip)
NIRVANA_IP=$(terraform -chdir=$TF output -raw nirvana_32_ip)
[ -n "$AWS_IP" ] && [ -n "$NIRVANA_IP" ] || { echo "missing terraform outputs"; exit 1; }

mkdir -p ansible/inventory ansible/logs ansible/results
cat > ansible/inventory/hosts-80k-matched.yml << EOF
all:
  children:
    aws:
      hosts:
        gp3-80k-sv:
          ansible_host: ${AWS_IP}
          ansible_user: ubuntu
          platform_name: gp3-80k-sv
    nirvana:
      hosts:
        nirvana-abs-32:
          ansible_host: ${NIRVANA_IP}
          ansible_user: ubuntu
          platform_name: nirvana-abs-32
EOF
echo "inventory: gp3-80k-sv=${AWS_IP} nirvana-abs-32=${NIRVANA_IP}"

wait_ssh() {
  for i in $(seq 1 40); do
    ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes ubuntu@$1 "$2" 2>/dev/null && return 0
    sleep 10
  done
  echo "SSH/readiness FAILED for $1"; return 1
}
wait_ssh "$AWS_IP" "test -f /opt/.disk-ready" &
p1=$!
wait_ssh "$NIRVANA_IP" "exit" &
p2=$!
wait $p1 && wait $p2
echo "both hosts ready"

cd ansible
run() {
  local dir=$1 agents=$2 tasks=$3 r=$4
  echo "[$(date '+%H:%M:%S')] START $dir $r (${agents}x${tasks})"
  ansible-playbook -i inventory/hosts-80k-matched.yml playbook.yml \
    -e num_agents=$agents -e tasks_per_agent=$tasks \
    > logs/run-80km-$dir-$r.log 2>&1
  mkdir -p results/$dir
  for p in gp3-80k-sv nirvana-abs-32; do
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
