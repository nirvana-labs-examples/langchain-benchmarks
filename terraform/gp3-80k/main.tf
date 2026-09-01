terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region                   = "us-west-1"
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

resource "aws_vpc" "bench80k" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "langchain-bench-80k-vpc" }
}

resource "aws_internet_gateway" "bench80k" {
  vpc_id = aws_vpc.bench80k.id
  tags   = { Name = "langchain-bench-80k-igw" }
}

resource "aws_subnet" "bench80k" {
  vpc_id                  = aws_vpc.bench80k.id
  cidr_block              = "10.1.1.0/24"
  availability_zone       = "us-west-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "langchain-bench-80k-subnet" }
}

resource "aws_route_table" "bench80k" {
  vpc_id = aws_vpc.bench80k.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.bench80k.id
  }
  tags = { Name = "langchain-bench-80k-rt" }
}

resource "aws_route_table_association" "bench80k" {
  subnet_id      = aws_subnet.bench80k.id
  route_table_id = aws_route_table.bench80k.id
}

# Benchmark runs on the VM itself; only SSH needed from outside.
resource "aws_security_group" "bench80k" {
  name        = "bench-80k-sg"
  description = "SSH access for gp3-80k benchmark node"
  vpc_id      = aws_vpc.bench80k.id

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
  tags = { Name = "bench-80k-sg" }
}

resource "aws_key_pair" "bench80k" {
  key_name   = "benchmark-key-80k"
  public_key = var.ssh_public_key
}

# gp3 caps at 16k IOPS/volume -> 5 x 16k striped RAID-0 = 80k aggregate.
# m6i.16xlarge sustains 80k EBS IOPS (xlarge caps at 40k burst).
resource "aws_instance" "gp3_80k" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "m6i.16xlarge"
  subnet_id              = aws_subnet.bench80k.id
  vpc_security_group_ids = [aws_security_group.bench80k.id]
  key_name               = aws_key_pair.bench80k.key_name
  availability_zone      = "us-west-1a"

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
    iops        = 3000
    throughput  = 125
  }

  user_data = file("${path.module}/raid-setup.sh")

  tags = { Name = "langchain-bench-gp3-80k" }
}

resource "aws_ebs_volume" "stripe" {
  count             = 5
  availability_zone = "us-west-1a"
  size              = 64
  type              = "gp3"
  iops              = 16000
  throughput        = 500
  tags              = { Name = "langchain-bench-gp3-80k-stripe-${count.index}" }
}

resource "aws_volume_attachment" "stripe" {
  count       = 5
  device_name = "/dev/sd${element(["f", "g", "h", "i", "j"], count.index)}"
  volume_id   = aws_ebs_volume.stripe[count.index].id
  instance_id = aws_instance.gp3_80k.id
}

variable "ssh_public_key" {
  type = string
}

output "gp3_80k_ip" {
  value = aws_instance.gp3_80k.public_ip
}

output "aws_ami" {
  value = data.aws_ami.ubuntu.name
}
