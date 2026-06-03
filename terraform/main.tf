terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    nirvana = {
      source  = "nirvana-labs/nirvana"
      version = "~> 1.0"
    }
  }
}

# =============================================================================
# PROVIDERS
# =============================================================================

provider "aws" {
  region = var.aws_region
}

provider "nirvana" {}

# =============================================================================
# AWS RESOURCES
# =============================================================================

# Lookup latest Ubuntu 24.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]  # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "benchmark" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "langchain-benchmark-vpc" }
}

resource "aws_internet_gateway" "benchmark" {
  vpc_id = aws_vpc.benchmark.id
  tags   = { Name = "langchain-benchmark-igw" }
}

resource "aws_subnet" "benchmark" {
  vpc_id                  = aws_vpc.benchmark.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "langchain-benchmark-subnet" }
}

resource "aws_route_table" "benchmark" {
  vpc_id = aws_vpc.benchmark.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.benchmark.id
  }
  tags = { Name = "langchain-benchmark-rt" }
}

resource "aws_route_table_association" "benchmark" {
  subnet_id      = aws_subnet.benchmark.id
  route_table_id = aws_route_table.benchmark.id
}

resource "aws_security_group" "benchmark" {
  name        = "benchmark-sg"
  description = "Security group for benchmark server"
  vpc_id      = aws_vpc.benchmark.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 6333
    to_port     = 6334
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "benchmark-sg" }
}

resource "aws_key_pair" "benchmark" {
  key_name   = "benchmark-key"
  public_key = var.ssh_public_key
}

# gp3 @ 3,000 IOPS (baseline)
resource "aws_instance" "gp3_3k" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.aws_instance_type
  subnet_id              = aws_subnet.benchmark.id
  vpc_security_group_ids = [aws_security_group.benchmark.id]
  key_name               = aws_key_pair.benchmark.key_name

  root_block_device {
    volume_size = var.aws_storage_size
    volume_type = "gp3"
    iops        = 3000
    throughput  = 125
  }

  tags = { Name = "langchain-bench-gp3-3k" }
}

# gp3 @ 16,000 IOPS
resource "aws_instance" "gp3_16k" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.aws_instance_type
  subnet_id              = aws_subnet.benchmark.id
  vpc_security_group_ids = [aws_security_group.benchmark.id]
  key_name               = aws_key_pair.benchmark.key_name

  root_block_device {
    volume_size = var.aws_storage_size
    volume_type = "gp3"
    iops        = 16000
    throughput  = 1000
  }

  tags = { Name = "langchain-bench-gp3-16k" }
}

# io2 @ 32,000 IOPS
resource "aws_instance" "io2_32k" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.aws_instance_type
  subnet_id              = aws_subnet.benchmark.id
  vpc_security_group_ids = [aws_security_group.benchmark.id]
  key_name               = aws_key_pair.benchmark.key_name

  root_block_device {
    volume_size = var.aws_storage_size
    volume_type = "io2"
    iops        = 32000
  }

  tags = { Name = "langchain-bench-io2-32k" }
}

# io2 @ 64,000 IOPS
resource "aws_instance" "io2_64k" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.aws_instance_type
  subnet_id              = aws_subnet.benchmark.id
  vpc_security_group_ids = [aws_security_group.benchmark.id]
  key_name               = aws_key_pair.benchmark.key_name

  root_block_device {
    volume_size = var.aws_storage_size
    volume_type = "io2"
    iops        = 64000
  }

  tags = { Name = "langchain-bench-io2-64k" }
}

# =============================================================================
# NIRVANA RESOURCES
# =============================================================================

resource "nirvana_networking_vpc" "benchmark" {
  name        = "langchain-benchmark-vpc"
  region      = var.nirvana_region
  project_id  = var.nirvana_project_id
  subnet_name = "langchain-benchmark-subnet"
}

resource "nirvana_networking_firewall_rule" "ssh" {
  vpc_id              = nirvana_networking_vpc.benchmark.id
  name                = "benchmark-ssh"
  protocol            = "tcp"
  source_address      = "0.0.0.0/0"
  destination_address = nirvana_networking_vpc.benchmark.subnet.cidr
  destination_ports   = ["22"]
}

resource "nirvana_networking_firewall_rule" "postgres" {
  vpc_id              = nirvana_networking_vpc.benchmark.id
  name                = "benchmark-postgres"
  protocol            = "tcp"
  source_address      = "0.0.0.0/0"
  destination_address = nirvana_networking_vpc.benchmark.subnet.cidr
  destination_ports   = ["5432"]
}

resource "nirvana_networking_firewall_rule" "qdrant" {
  vpc_id              = nirvana_networking_vpc.benchmark.id
  name                = "benchmark-qdrant"
  protocol            = "tcp"
  source_address      = "0.0.0.0/0"
  destination_address = nirvana_networking_vpc.benchmark.subnet.cidr
  destination_ports   = ["6333", "6334"]
}

resource "nirvana_networking_firewall_rule" "redis" {
  vpc_id              = nirvana_networking_vpc.benchmark.id
  name                = "benchmark-redis"
  protocol            = "tcp"
  source_address      = "0.0.0.0/0"
  destination_address = nirvana_networking_vpc.benchmark.subnet.cidr
  destination_ports   = ["6379"]
}

resource "nirvana_compute_vm" "benchmark" {
  name              = "langchain-bench-nirvana"
  region            = var.nirvana_region
  project_id        = var.nirvana_project_id
  instance_type     = var.nirvana_instance_type
  os_image_name     = "ubuntu-noble-2026-05-18"
  boot_volume       = { size = var.nirvana_storage_size, type = var.nirvana_storage_type }
  public_ip_enabled = true
  subnet_id         = nirvana_networking_vpc.benchmark.subnet.id
  ssh_key           = { public_key = var.ssh_public_key }

  depends_on = [
    nirvana_networking_firewall_rule.ssh,
    nirvana_networking_firewall_rule.postgres,
    nirvana_networking_firewall_rule.qdrant,
    nirvana_networking_firewall_rule.redis
  ]
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "gp3_3k_ip" {
  value       = aws_instance.gp3_3k.public_ip
  description = "AWS gp3 3k IOPS VM public IP"
}

output "gp3_16k_ip" {
  value       = aws_instance.gp3_16k.public_ip
  description = "AWS gp3 16k IOPS VM public IP"
}

output "io2_32k_ip" {
  value       = aws_instance.io2_32k.public_ip
  description = "AWS io2 32k IOPS VM public IP"
}

output "io2_64k_ip" {
  value       = aws_instance.io2_64k.public_ip
  description = "AWS io2 64k IOPS VM public IP"
}

output "nirvana_ip" {
  value       = nirvana_compute_vm.benchmark.public_ip
  description = "Nirvana VM public IP"
}

output "aws_ami" {
  value       = data.aws_ami.ubuntu.name
  description = "AWS AMI used"
}

output "next_steps" {
  value = <<-EOT

    VMs are ready! Next steps:

    1. Generate inventory:  ./scripts/generate-inventory.sh
    2. Run benchmark:       cd ansible && ansible-playbook playbook.yml

  EOT
}
