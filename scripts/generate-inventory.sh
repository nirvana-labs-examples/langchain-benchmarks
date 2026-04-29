#!/bin/bash
# Generate Ansible inventory from Terraform output and verify SSH

cd "$(dirname "$0")/../terraform"

AWS_IP=$(terraform output -raw aws_ip 2>/dev/null)
NIRVANA_IP=$(terraform output -raw nirvana_ip 2>/dev/null)

if [ -z "$AWS_IP" ] || [ -z "$NIRVANA_IP" ]; then
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
        aws-benchmark:
          ansible_host: ${AWS_IP}
          ansible_user: ubuntu
          platform_name: aws-gp3
    nirvana:
      hosts:
        nirvana-benchmark:
          ansible_host: ${NIRVANA_IP}
          ansible_user: ubuntu
          platform_name: nirvana-abs
EOF

echo "Inventory generated:"
echo "  AWS:     ${AWS_IP}"
echo "  Nirvana: ${NIRVANA_IP}"

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

wait_for_ssh "$AWS_IP" "AWS" &
pid1=$!
wait_for_ssh "$NIRVANA_IP" "Nirvana" &
pid2=$!

wait $pid1
aws_ok=$?
wait $pid2
nirvana_ok=$?

if [ $aws_ok -ne 0 ] || [ $nirvana_ok -ne 0 ]; then
    echo ""
    echo "ERROR: SSH verification failed. Check your SSH key and security groups."
    exit 1
fi

echo ""
echo "Ready! Run: cd ansible && ansible-playbook playbook.yml"
