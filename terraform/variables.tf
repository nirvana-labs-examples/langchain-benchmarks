variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
}

variable "nirvana_project_id" {
  description = "Nirvana project ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-1"
}

# Note: AMI is now dynamically looked up in main.tf (Ubuntu 24.04 LTS)

variable "nirvana_region" {
  description = "Nirvana region"
  type        = string
  default     = "us-sva-2"
}

# =============================================================================
# AWS Instance & Storage Configuration
# =============================================================================

variable "aws_instance_type" {
  description = "AWS EC2 instance type"
  type        = string
  default     = "m5.xlarge"
}

variable "aws_storage_size" {
  description = "AWS root volume size in GB"
  type        = number
  default     = 256
}

variable "aws_storage_type" {
  description = "AWS EBS volume type (gp3, gp2, io1, io2)"
  type        = string
  default     = "gp3"
}

variable "aws_storage_iops" {
  description = "AWS EBS IOPS (for gp3/io1/io2)"
  type        = number
  default     = 3000
}

variable "aws_storage_throughput" {
  description = "AWS EBS throughput in MB/s (for gp3)"
  type        = number
  default     = 125
}

# =============================================================================
# Nirvana Instance & Storage Configuration
# =============================================================================

variable "nirvana_instance_type" {
  description = "Nirvana VM instance type"
  type        = string
  default     = "n1-standard-4"
}

variable "nirvana_storage_size" {
  description = "Nirvana boot volume size in GB"
  type        = number
  default     = 256
}

variable "nirvana_storage_type" {
  description = "Nirvana storage type (abs)"
  type        = string
  default     = "abs"
}
