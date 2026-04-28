#!/bin/bash
# Manual setup script (alternative to Ansible)
# Run this if you don't have Ansible installed

set -e

cd "$(dirname "$0")/../terraform"

AWS_IP=$(terraform output -raw aws_ip 2>/dev/null)
NIRVANA_IP=$(terraform output -raw nirvana_ip 2>/dev/null)

if [ -z "$AWS_IP" ] || [ -z "$NIRVANA_IP" ]; then
    echo "Error: Could not get IPs from terraform output"
    exit 1
fi

echo "Setting up VMs..."
echo "AWS: $AWS_IP"
echo "Nirvana: $NIRVANA_IP"

# Setup script to run on each VM
SETUP_SCRIPT='
sudo apt-get update
sudo apt-get install -y docker.io docker-compose python3 python3-pip python3-venv

sudo systemctl start docker
sudo systemctl enable docker

sudo mkdir -p /opt/benchmark
cd /opt/benchmark

sudo tee docker-compose.yml << EOF
version: "3.8"
services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_USER: benchmark
      POSTGRES_PASSWORD: benchmark
      POSTGRES_DB: benchmark
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
  qdrant:
    image: qdrant/qdrant:latest
    ports:
      - "6333:6333"
      - "6334:6334"
    volumes:
      - qdrant_data:/qdrant/storage
  redis:
    image: redis:7
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
volumes:
  postgres_data:
  qdrant_data:
  redis_data:
EOF

sudo docker-compose up -d
echo "Services started!"
'

echo ""
echo "Setting up AWS VM..."
ssh -o StrictHostKeyChecking=no ubuntu@$AWS_IP "$SETUP_SCRIPT"

echo ""
echo "Setting up Nirvana VM..."
ssh -o StrictHostKeyChecking=no ubuntu@$NIRVANA_IP "$SETUP_SCRIPT"

echo ""
echo "Setup complete! VMs are ready for benchmarking."
echo ""
echo "To run benchmark manually:"
echo "  ssh ubuntu@$AWS_IP"
echo "  ssh ubuntu@$NIRVANA_IP"
