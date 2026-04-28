#!/bin/bash
# Generate Ansible inventory from Terraform output

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
    nirvana:
      hosts:
        nirvana-benchmark:
          ansible_host: ${NIRVANA_IP}
EOF

echo "Inventory generated:"
echo "  AWS:     ${AWS_IP}"
echo "  Nirvana: ${NIRVANA_IP}"
