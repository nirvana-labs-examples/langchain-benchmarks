#!/bin/bash
# Generate Ansible inventory from Terraform output and verify SSH

cd "$(dirname "$0")/../terraform"

AWS_GP3_IP=$(terraform output -raw aws_gp3_ip 2>/dev/null)
AWS_IO2_IP=$(terraform output -raw aws_io2_ip 2>/dev/null)
NIRVANA_IP=$(terraform output -raw nirvana_ip 2>/dev/null)

if [ -z "$AWS_GP3_IP" ] || [ -z "$AWS_IO2_IP" ] || [ -z "$NIRVANA_IP" ]; then
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
        aws-gp3-benchmark:
          ansible_host: ${AWS_GP3_IP}
          ansible_user: ubuntu
          platform_name: aws-gp3
        aws-io2-benchmark:
          ansible_host: ${AWS_IO2_IP}
          ansible_user: ubuntu
          platform_name: aws-io2
    nirvana:
      hosts:
        nirvana-benchmark:
          ansible_host: ${NIRVANA_IP}
          ansible_user: ubuntu
          platform_name: nirvana-abs
EOF

echo "Inventory generated:"
echo "  AWS gp3:  ${AWS_GP3_IP}"
echo "  AWS io2:  ${AWS_IO2_IP}"
echo "  Nirvana:  ${NIRVANA_IP}"

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

wait_for_ssh "$AWS_GP3_IP" "AWS gp3" &
pid1=$!
wait_for_ssh "$AWS_IO2_IP" "AWS io2" &
pid2=$!
wait_for_ssh "$NIRVANA_IP" "Nirvana" &
pid3=$!

wait $pid1
gp3_ok=$?
wait $pid2
io2_ok=$?
wait $pid3
nirvana_ok=$?

if [ $gp3_ok -ne 0 ] || [ $io2_ok -ne 0 ] || [ $nirvana_ok -ne 0 ]; then
    echo ""
    echo "ERROR: SSH verification failed. Check your SSH key and security groups."
    exit 1
fi

echo ""
echo "Ready! Run: cd ansible && ansible-playbook playbook.yml"
