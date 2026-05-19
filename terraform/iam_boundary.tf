# =============================================================================
# PERMISSION BOUNDARY
# =============================================================================
# A Permission Boundary is a MAXIMUM permission ceiling attached to a user
# or role. It does NOT grant permissions — it only limits them.
#
# Mental model:
#   Effective permissions = (Identity policy) ∩ (Permission Boundary)
#   Both must say "Allow" for an action to be permitted.
#
# Use case here:
#   Even if someone accidentally attaches AdministratorAccess to developer-test,
#   the boundary caps them at this policy. They can never exceed S3+EC2 scoped.
#
# This is critical for delegated admin scenarios:
#   If developer-test could create other IAM users, without a boundary those
#   users could have more permissions than the creator. Boundaries prevent
#   privilege escalation through IAM user/role creation.
# =============================================================================

data "aws_iam_policy_document" "developer_boundary" {

  # ── What the boundary ALLOWS (ceiling) ────────────────────────────────────
  # This is the maximum any policy can grant. S3 and EC2 only.
  statement {
    sid    = "BoundaryAllowS3"
    effect = "Allow"
    actions = [
      "s3:Get*",
      "s3:List*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "BoundaryAllowEC2"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "ec2:RunInstances",
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
  }

  # ── What the boundary explicitly PREVENTS (hard floor) ────────────────────
  # Even if the identity policy has broader allows, these are always denied.
  statement {
    sid    = "BoundaryDenyIAM"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:DeleteUser",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:AttachUserPolicy",
      "iam:DetachUserPolicy",
      "iam:PutUserPolicy",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:PassRole",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "BoundaryDenyOrganizations"
    effect = "Deny"
    actions = [
      "organizations:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "BoundaryDenyCloudTrail"
    effect = "Deny"
    actions = [
      "cloudtrail:DeleteTrail",
      "cloudtrail:StopLogging",
      "cloudtrail:UpdateTrail",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "BoundaryDenyBilling"
    effect = "Deny"
    actions = [
      "aws-portal:*",
      "billing:*",
      "budgets:Delete*",
      "ce:Delete*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "developer_boundary" {
  name        = "${var.resource_prefix}-developer-boundary"
  path        = "/"
  description = "Permission boundary for developer-test: caps at S3+EC2, blocks IAM/CloudTrail/billing"
  policy      = data.aws_iam_policy_document.developer_boundary.json

  tags = {
    Name = "${var.resource_prefix}-developer-boundary"
  }
}

# ── Attach the boundary to the user ──────────────────────────────────────────
# This is the critical step. Without this attachment, the policy exists but
# has no effect. Note: this is NOT policy attachment (which grants permissions).
# This is a boundary attachment — it LIMITS permissions.

# ── Attach boundary via CLI after user is created ────────────────────────────
# aws_iam_user supports permissions_boundary natively.
# We use a null_resource with local-exec so we don't need to restructure files.

resource "null_resource" "attach_boundary" {
  depends_on = [
    aws_iam_user.developer,
    aws_iam_policy.developer_boundary,
  ]

  provisioner "local-exec" {
    command = <<-ENDOFFILE
      aws iam put-user-permissions-boundary \
        --user-name ${aws_iam_user.developer.name} \
        --permissions-boundary ${aws_iam_policy.developer_boundary.arn} \
        --region ${var.aws_region}
    ENDOFFILE
  }

  # Remove the boundary on destroy so the user can be cleanly deleted
  provisioner "local-exec" {
    when    = destroy
    command = "aws iam delete-user-permissions-boundary --user-name developer-test || true"
  }
}

# ── IAM Role for assume-role testing ─────────────────────────────────────────
# This role is assumed by developer-test in the session policy test script.
# It has no inline permissions — the session policy passed at assume-role time
# further restricts what the assumed session can do.

data "aws_iam_policy_document" "assume_role_trust" {
  statement {
    sid    = "AllowDeveloperToAssume"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.account_id}:user/${var.developer_user_name}"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "developer_sandbox" {
  name               = "${var.resource_prefix}-developer-sandbox-role"
  depends_on         = [aws_iam_user.developer]
  assume_role_policy = data.aws_iam_policy_document.assume_role_trust.json

  # The trust policy references the developer-test user ARN.
  # AWS validates that the principal exists at role creation time,
  # so we must wait for the user to be created first.
  description        = "Role assumed by developer-test for session policy testing"
  max_session_duration = 3600 # 1 hour max

  tags = {
    Name = "${var.resource_prefix}-developer-sandbox-role"
  }
}

# Attach the same developer policy to the role so it has baseline permissions
resource "aws_iam_role_policy_attachment" "developer_sandbox" {
  role       = aws_iam_role.developer_sandbox.name
  policy_arn = aws_iam_policy.developer.arn
}
