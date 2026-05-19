variable "aws_region" {
  description = "Primary AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS Account ID — used to construct IAM policy ARNs"
  type        = string
}

variable "resource_prefix" {
  description = "Prefix applied to every named resource (keeps lab resources identifiable)"
  type        = string
  default     = "jhon"
}

variable "developer_user_name" {
  description = "IAM user created for policy testing"
  type        = string
  default     = "developer-test"
}

# ---------- VPC ----------
variable "vpc_cidr" {
  description = "CIDR block for the lab VPC"
  type        = string
  default     = "10.99.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet inside the lab VPC"
  type        = string
  default     = "10.99.1.0/24"
}
