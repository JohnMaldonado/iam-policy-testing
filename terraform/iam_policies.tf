# =============================================================================
# CUSTOM DEVELOPER POLICY
# =============================================================================
# This policy implements four layers of control:
#
#  Layer 1 — S3 read-only:   Only on buckets/objects tagged Team=Dev
#  Layer 2 — EC2 launch:     Only t2.micro or t3.micro instance types
#  Layer 3 — EC2 VPC lock:   RunInstances only inside the lab VPC
#  Layer 4 — Prod deny:      Explicit Deny on anything tagged Environment=production
#
# WHY explicit deny for prod?
#   Allow statements are evaluated after all Deny statements. An explicit Deny
#   can never be overridden by any Allow — not by another policy, not by
#   a role, not even by a broader managed policy. It is the strongest gate.
# =============================================================================

data "aws_iam_policy_document" "developer" {

  # ── Statement 1: S3 List all buckets ──────────────────────────────────────
  # ListAllMyBuckets does not operate on a specific bucket resource — it is an
  # account-level action. It cannot carry a resource ARN or tag condition.
  # We allow it here so the developer can see what buckets exist.
  # The tag condition on GetObject/GetBucketTagging prevents actual reading
  # of non-Dev buckets even though names are visible.
  statement {
    sid    = "S3ListAllBuckets"
    effect = "Allow"
    actions = [
      "s3:ListAllMyBuckets",
      "s3:GetBucketLocation",
    ]
    resources = ["*"]
  }

  # ── Statement 2: S3 Read on buckets tagged Team=Dev ────────────────────────
  # aws:ResourceTag is evaluated against the bucket's tags at request time.
  # This means the developer CAN list/read any bucket that has Team=Dev,
  # regardless of which bucket name it is — tags are the key, not the ARN.
  statement {
    sid    = "S3ReadDevBuckets"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetBucketTagging",
    ]
    resources = [
      "arn:aws:s3:::*",
      "arn:aws:s3:::*/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Team"
      values   = ["Dev"]
    }
  }

  # ── Statement 3: EC2 launch — small instances only ────────────────────────
  # ec2:InstanceType condition key is evaluated during RunInstances.
  # We also require the launch to happen inside our lab VPC.
  # RunInstances also requires permissions on AMI, subnet, and security group
  # resources — those are covered in Statements 4 and 5.
  statement {
    sid    = "EC2LaunchSmallInstances"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
    ]
    # The instance resource type within RunInstances
    resources = [
      "arn:aws:ec2:${var.aws_region}:${var.account_id}:instance/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceType"
      values   = ["t2.micro", "t3.micro"]
    }
  }

  # ── Statement 4: EC2 launch — VPC restriction ─────────────────────────────
  # RunInstances touches multiple resource types. The VPC condition must be
  # applied to the subnet resource (not the instance). AWS evaluates conditions
  # per-resource-type within a RunInstances call.
  statement {
    sid    = "EC2LaunchInLabVPC"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
    ]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${var.account_id}:subnet/*",
      "arn:aws:ec2:${var.aws_region}:${var.account_id}:network-interface/*",
      "arn:aws:ec2:${var.aws_region}:${var.account_id}:security-group/*",
      "arn:aws:ec2:${var.aws_region}:${var.account_id}:volume/*",
      "arn:aws:ec2:${var.aws_region}:${var.account_id}:key-pair/*",
    ]

    condition {
      test     = "ArnLike"
      variable = "ec2:Vpc"
      values   = ["arn:aws:ec2:${var.aws_region}:${var.account_id}:vpc/${aws_vpc.lab.id}"]
    }
  }

  # ── Statement 5: EC2 RunInstances — AMI (global resource, no condition) ───
  # AMIs are account/region-scoped and can't carry VPC or instance-type
  # conditions. We allow any AMI in our region (developer still needs to pick
  # one explicitly in their launch command).
  statement {
    sid    = "EC2UseAMIs"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
    ]
    resources = [
      "arn:aws:ec2:${var.aws_region}::image/*",
    ]
  }

  # ── Statement 6: EC2 read-only describe actions ───────────────────────────
  statement {
    sid    = "EC2ReadOnly"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeVpcs",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeImages",
      "ec2:DescribeKeyPairs",
      "ec2:DescribeAvailabilityZones",
    ]
    resources = ["*"]
  }

  # ── Statement 7: EC2 stop/start — only instances inside lab VPC ──────────
  statement {
    sid    = "EC2ManageLabInstances"
    effect = "Allow"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
      "ec2:RebootInstances",
      "ec2:CreateTags",
    ]
    resources = [
      "arn:aws:ec2:${var.aws_region}:${var.account_id}:instance/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/aws:cloudformation:stack-name"
      # Allow managing only instances that were created inside the lab VPC
      # (tagged by our Terraform stack).
      values   = [""] # placeholder: in real use, tag instances with stack name
    }
  }

  # ── Statement 8: EXPLICIT DENY — production resources ────────────────────
  # This is the safety net. Even if a future policy grants broader access,
  # this Deny will always win. It targets any resource tagged Environment=production.
  #
  # WHY use Deny instead of just not granting Allow?
  #   Because "no Allow = implicit deny" only works if we control every policy.
  #   In a real org, someone might attach another managed policy later.
  #   An explicit Deny cannot be overridden by any Allow anywhere.
  statement {
    sid    = "DenyProductionResources"
    effect = "Deny"
    actions = [
      "s3:*",
      "ec2:*",
      "rds:*",
      "lambda:*",
      "dynamodb:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Environment"
      values   = ["production"]
    }
  }

  # ── Statement 9: EXPLICIT DENY — S3 destructive actions ──────────────────
  # Even inside Dev buckets, developers should never be able to delete objects.
  # This is belt-and-suspenders: read-only is the intent, Deny makes it iron.
  statement {
    sid    = "DenyS3Destructive"
    effect = "Deny"
    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
    ]
    resources = ["*"]
  }
}

# ── Materialize as an IAM Managed Policy ─────────────────────────────────────
resource "aws_iam_policy" "developer" {
  name        = "${var.resource_prefix}-developer-policy"
  path        = "/"
  description = "Scoped developer policy: S3 read (Dev tag), EC2 small instances in lab VPC, deny production"
  policy      = data.aws_iam_policy_document.developer.json

  tags = {
    Name = "${var.resource_prefix}-developer-policy"
  }
}

# ── Attach to developer-test user ────────────────────────────────────────────
resource "aws_iam_user_policy_attachment" "developer" {
  user       = aws_iam_user.developer.name
  policy_arn = aws_iam_policy.developer.arn
}
