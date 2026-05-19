# =============================================================================
# IAM USER: developer-test
# =============================================================================
# This user represents a developer who should have scoped access:
#   - Read S3 in Dev buckets only
#   - Launch small EC2 only inside the lab VPC
#   - No access to anything tagged production
# =============================================================================

resource "aws_iam_user" "developer" {
  name          = var.developer_user_name
  path          = "/"
  force_destroy = true # deletes access keys automatically on terraform destroy

  tags = {
    Name        = var.developer_user_name
    Description = "Lab user for IAM policy testing - Assignment 18"
    Team        = "Dev"
  }
}

# ── Programmatic Access Key ──────────────────────────────────────────────────
# Required so the Python test scripts can call the Policy Simulator API
# using this user's identity context.

resource "aws_iam_access_key" "developer" {
  user = aws_iam_user.developer.name
}

# ── Console Login Profile ────────────────────────────────────────────────────
# Allows login via AWS Console for manual testing via the Policy Simulator UI.
# Password will be shown in terraform output (encrypted via PGP in prod).

resource "aws_iam_user_login_profile" "developer" {
  user                    = aws_iam_user.developer.name
  password_reset_required = true
}
