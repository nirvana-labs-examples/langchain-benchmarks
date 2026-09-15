terraform {
  required_providers {
    nirvana = {
      source  = "nirvana-labs/nirvana"
      version = "~> 1.0"
    }
  }
}

# =============================================================================
# 80k matched-pair benchmark — Nirvana side:
#   nirvana-abs-32 — n1-highcpu-32 (32 vCPU / 64 GB), 256 GB ABS.
# Matches the AWS side's c6in.8xlarge shape exactly; see ../aws.
# Requires NIRVANA_LABS_API_KEY in the environment.
# =============================================================================

provider "nirvana" {}

variable "ssh_public_key" {
  type = string
}

variable "nirvana_project_id" {
  type = string
}

variable "nirvana_region" {
  type    = string
  default = "us-sva-2"
}

resource "nirvana_networking_vpc" "m80k" {
  name        = "langchain-bench-80k-vpc"
  region      = var.nirvana_region
  project_id  = var.nirvana_project_id
  subnet_name = "langchain-bench-80k-subnet"
}

resource "nirvana_networking_firewall_rule" "ssh" {
  vpc_id              = nirvana_networking_vpc.m80k.id
  name                = "bench80k-ssh"
  protocol            = "tcp"
  source_address      = "0.0.0.0/0"
  destination_address = nirvana_networking_vpc.m80k.subnet.cidr
  destination_ports   = ["22"]
}

resource "nirvana_compute_vm" "nirvana_32" {
  name              = "langchain-bench-nirvana-hc32"
  region            = var.nirvana_region
  project_id        = var.nirvana_project_id
  instance_type     = "n1-highcpu-32"
  os_image_name     = "ubuntu-noble-2026-05-18"
  boot_volume       = { size = 256, type = "abs" }
  public_ip_enabled = true
  subnet_id         = nirvana_networking_vpc.m80k.subnet.id
  ssh_key           = { public_key = var.ssh_public_key }

  depends_on = [nirvana_networking_firewall_rule.ssh]
}

output "nirvana_32_ip" {
  value = nirvana_compute_vm.nirvana_32.public_ip
}
