#!/bin/bash
# Generate Ansible inventory from Terraform output and verify SSH

cd "$(dirname "$0")/../terraform"

GP3_3K_IP=$(terraform output -raw gp3_3k_ip 2>/dev/null)
GP3_16K_IP=$(terraform output -raw gp3_16k_ip 2>/dev/null)
IO2_32K_IP=$(terraform output -raw io2_32k_ip 2>/dev/null)
IO2_64K_IP=$(terraform output -raw io2_64k_ip 2>/dev/null)
NIRVANA_IP=$(terraform output -raw nirvana_ip 2>/dev/null)

if [ -z "$GP3_3K_IP" ] || [ -z "$GP3_16K_IP" ] || [ -z "$IO2_32K_IP" ] || [ -z "$IO2_64K_IP" ] || [ -z "$NIRVANA_IP" ]; then
    echo "Error: Could not get IPs from terraform output"
    echo "Make sure terraform apply has been run"
    exit 1
fi

mkdir -p ../ansible/inventory

cat > ../ansible/inventory/hosts.yml << EOF
all:
  children:
    aws:
      hosts:
        gp3-3k:
          ansible_host: ${GP3_3K_IP}
          ansible_user: ubuntu
          platform_name: gp3-3k
        gp3-16k:
          ansible_host: ${GP3_16K_IP}
          ansible_user: ubuntu
          platform_name: gp3-16k
        io2-32k:
          ansible_host: ${IO2_32K_IP}
          ansible_user: ubuntu
          platform_name: io2-32k
        io2-64k:
          ansible_host: ${IO2_64K_IP}
          ansible_user: ubuntu
          platform_name: io2-64k
    nirvana:
      hosts:
        nirvana-abs:
          ansible_host: ${NIRVANA_IP}
          ansible_user: ubuntu
          platform_name: nirvana-abs
EOF

echo "Inventory generated:"
echo "  gp3-3k:     ${GP3_3K_IP}"
echo "  gp3-16k:    ${GP3_16K_IP}"
echo "  io2-32k:    ${IO2_32K_IP}"
echo "  io2-64k:    ${IO2_64K_IP}"
echo "  Nirvana:    ${NIRVANA_IP}"

# Verify SSH access
echo ""
echo "Verifying SSH access (may take up to 60s for VMs to boot)..."

wait_for_ssh() {
    local host=$1
    local name=$2
    local max_attempts=12
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes ubuntu@$host "exit" 2>/dev/null; then
            echo "  $name: OK"
            return 0
        fi
        echo "  $name: waiting... (attempt $attempt/$max_attempts)"
        sleep 5
        attempt=$((attempt + 1))
    done
    echo "  $name: FAILED"
    return 1
}

wait_for_ssh "$GP3_3K_IP" "gp3-3k" &
pid1=$!
wait_for_ssh "$GP3_16K_IP" "gp3-16k" &
pid2=$!
wait_for_ssh "$IO2_32K_IP" "io2-32k" &
pid3=$!
wait_for_ssh "$IO2_64K_IP" "io2-64k" &
pid4=$!
wait_for_ssh "$NIRVANA_IP" "Nirvana" &
pid5=$!

wait $pid1; r1=$?
wait $pid2; r2=$?
wait $pid3; r3=$?
wait $pid4; r4=$?
wait $pid5; r5=$?

if [ $r1 -ne 0 ] || [ $r2 -ne 0 ] || [ $r3 -ne 0 ] || [ $r4 -ne 0 ] || [ $r5 -ne 0 ]; then
    echo ""
    echo "ERROR: SSH verification failed. Check your SSH key and security groups."
    exit 1
fi

echo ""
echo "Ready! Run: cd ansible && ansible-playbook playbook.yml"
