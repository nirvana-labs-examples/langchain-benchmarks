terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

# =============================================================================
# 80k matched-pair benchmark — AWS side:
#   gp3-80k-sv — c6in.8xlarge (32 vCPU / 64 GB), single gp3 volume
#                @ 80,000 IOPS / 2,000 MiB/s (gp3 per-volume maximum since
#                Sep 2025; c6in.8xlarge sustains 100k instance-side, so the
#                volume is the measured bottleneck)
# The Nirvana side (n1-highcpu-32) lives in ../nirvana as a separate stack
# so each side can be provisioned independently.
# =============================================================================

provider "aws" {
  region = var.aws_region
}

variable "ssh_public_key" {
  type = string
}

variable "aws_region" {
  type    = string
  default = "us-west-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "m80k" {
  cidr_block           = "10.2.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "langchain-bench-80ksv-vpc" }
}

resource "aws_internet_gateway" "m80k" {
  vpc_id = aws_vpc.m80k.id
  tags   = { Name = "langchain-bench-80ksv-igw" }
}

resource "aws_subnet" "m80k" {
  vpc_id                  = aws_vpc.m80k.id
  cidr_block              = "10.2.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "langchain-bench-80ksv-subnet" }
}

resource "aws_route_table" "m80k" {
  vpc_id = aws_vpc.m80k.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.m80k.id
  }
  tags = { Name = "langchain-bench-80ksv-rt" }
}

resource "aws_route_table_association" "m80k" {
  subnet_id      = aws_subnet.m80k.id
  route_table_id = aws_route_table.m80k.id
}

# Benchmark runs on the VM itself; only SSH needed from outside.
resource "aws_security_group" "m80k" {
  name        = "bench-80ksv-sg"
  description = "SSH access for gp3-80k-sv benchmark node"
  vpc_id      = aws_vpc.m80k.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "bench-80ksv-sg" }
}

resource "aws_key_pair" "m80k" {
  key_name   = "benchmark-key-80ksv"
  public_key = var.ssh_public_key
}

resource "aws_instance" "gp3_80k_sv" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "c6in.8xlarge"
  subnet_id              = aws_subnet.m80k.id
  vpc_security_group_ids = [aws_security_group.m80k.id]
  key_name               = aws_key_pair.m80k.key_name
  availability_zone      = "${var.aws_region}a"

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
    iops        = 3000
    throughput  = 125
  }

  user_data = file("${path.module}/datadisk-setup.sh")

  tags = { Name = "langchain-bench-gp3-80k-sv" }
}

# Single gp3 volume at its per-volume maximum (80k IOPS / 2,000 MiB/s).
# 256 GiB satisfies the 500 IOPS/GiB ratio (needs >= 160 GiB for 80k).
resource "aws_ebs_volume" "data" {
  availability_zone = "${var.aws_region}a"
  size              = 256
  type              = "gp3"
  iops              = 80000
  throughput        = 2000
  tags              = { Name = "langchain-bench-gp3-80k-sv-data" }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.gp3_80k_sv.id
}

output "gp3_80k_sv_ip" {
  value = aws_instance.gp3_80k_sv.public_ip
}

output "aws_ami" {
  value = data.aws_ami.ubuntu.name
}
