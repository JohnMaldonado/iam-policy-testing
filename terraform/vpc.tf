# =============================================================================
# LAB VPC
# Purpose: This VPC acts as the "allowed boundary" in the developer IAM policy.
# The EC2 RunInstances condition will only permit launches inside this VPC.
# Creating the VPC in Terraform ensures the VPC ID is dynamic — no hardcoding.
# =============================================================================

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.resource_prefix}-iam-lab-vpc"
  }
}

# ── Public Subnet ────────────────────────────────────────────────────────────
# One subnet is enough for lab purposes. EC2 policy restricts to this VPC,
# not a specific subnet — keeping the restriction at VPC level is simpler
# and the correct real-world pattern for a developer sandbox.

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.resource_prefix}-iam-lab-subnet-public"
    Team = "Dev" # <── This tag is what the S3 policy condition checks for
  }
}

# ── Internet Gateway ─────────────────────────────────────────────────────────
resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id

  tags = {
    Name = "${var.resource_prefix}-iam-lab-igw"
  }
}

# ── Route Table ──────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = {
    Name = "${var.resource_prefix}-iam-lab-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── S3 Lab Buckets ────────────────────────────────────────────────────────────
# We need at least one bucket tagged Team=Dev (accessible) and one without
# (inaccessible) to validate that tag-based conditions work correctly.

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "dev_team" {
  bucket        = "${var.resource_prefix}-lab-dev-team-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "${var.resource_prefix}-lab-dev-team"
    Team = "Dev" # <── policy allows access to buckets with this tag
  }
}

resource "aws_s3_bucket_versioning" "dev_team" {
  bucket = aws_s3_bucket.dev_team.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Block all public access — bucket is private, accessible only via IAM
resource "aws_s3_bucket_public_access_block" "dev_team" {
  bucket                  = aws_s3_bucket.dev_team.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "production" {
  bucket        = "${var.resource_prefix}-lab-production-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "${var.resource_prefix}-lab-production"
    Environment = "production" # <── developer policy DENIES access to this tag
  }
}

resource "aws_s3_bucket_public_access_block" "production" {
  bucket                  = aws_s3_bucket.production.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
