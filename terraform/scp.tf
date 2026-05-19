# =============================================================================
# SERVICE CONTROL POLICY (SCP)
# =============================================================================
# SCPs live at the AWS Organizations level — they are NOT IAM policies.
# They apply to an entire Organizational Unit (OU) or AWS account.
#
# Key difference from IAM policies:
#   IAM policy:  "What can THIS USER do?"
#   SCP:         "What is the MAXIMUM any identity in this account can do?"
#                Even the root user of the account cannot bypass an SCP.
#
# WHY this matters:
#   An SCP is the last line of defense. Even if a developer gets AdministratorAccess,
#   they cannot do what the SCP forbids. This is why SCPs are set by the
#   security/platform team and developers cannot modify them.
#
# PREREQUISITES:
#   - AWS Organizations must be enabled in the management account
#   - This account must be a member of an OU
#   - The caller must have organizations:* permissions in the management account
#
# For this lab: the JSON is generated and ready. If Organizations is not
# enabled, apply the JSON manually via the Console → Organizations → Policies.
# =============================================================================

# ── SCP Policy Document ───────────────────────────────────────────────────────

data "aws_iam_policy_document" "scp" {

  # ── Rule 1: Deny all regions except us-east-1 and eu-west-1 ──────────────
  # aws:RequestedRegion is available on almost all API calls.
  # We use a StringNotEquals condition with the NotAction pattern:
  # Actions that are global (IAM, STS, Route53, Support, Billing) must be
  # excluded from region restrictions — they don't operate in a specific region.
  statement {
    sid    = "DenyNonApprovedRegions"
    effect = "Deny"
    not_actions = [
      # Global services — excluding these from region restriction is MANDATORY.
      # If you don't exclude them, IAM calls fail because IAM has no region.
      "iam:*",
      "sts:*",
      "route53:*",
      "cloudfront:*",
      "support:*",
      "trustedadvisor:*",
      "health:*",
      "budgets:*",
      "ce:*",
      "waf:*",
      "globalaccelerator:*",
    ]
    resources = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:RequestedRegion"
      values   = ["us-east-1", "eu-west-1"]
    }
  }

  # ── Rule 2: Deny CloudTrail deletion and disabling ────────────────────────
  # CloudTrail is the audit backbone. Deleting it means attackers can operate
  # without leaving traces. This deny has NO conditions — it applies to
  # everyone in the OU, including root. There is no legitimate reason to
  # delete CloudTrail in a governed account.
  statement {
    sid    = "DenyCloudTrailModification"
    effect = "Deny"
    actions = [
      "cloudtrail:DeleteTrail",
      "cloudtrail:StopLogging",
      "cloudtrail:UpdateTrail",
      "cloudtrail:PutEventSelectors",
      "cloudtrail:RemoveTags",
    ]
    resources = ["*"]
  }

  # ── Rule 3: Deny leaving the organization ────────────────────────────────
  # A compromised account could try to detach itself from the OU to escape SCPs.
  statement {
    sid    = "DenyLeaveOrganization"
    effect = "Deny"
    actions = [
      "organizations:LeaveOrganization",
    ]
    resources = ["*"]
  }

  # ── Rule 4: Deny root user actions ───────────────────────────────────────
  # Root should not be used for day-to-day operations. This forces all
  # operations through IAM identities.
  statement {
    sid    = "DenyRootUserActions"
    effect = "Deny"
    actions = ["*"]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::*:root"]
    }
  }
}

# ── Terraform resource — only works if Organizations is enabled ──────────────
# If your account is standalone, this resource will fail with:
# "AccessDeniedException: You need an organization"
# In that case: comment this resource out and use the JSON in policies/scp_policy.json

resource "aws_organizations_policy" "lab_scp" {
  count = 0 # <── set to 1 if Organizations is enabled in your account

  name        = "${var.resource_prefix}-lab-scp"
  description = "Lab SCP: restrict to us-east-1/eu-west-1, protect CloudTrail, deny root usage"
  content     = data.aws_iam_policy_document.scp.json
  type        = "SERVICE_CONTROL_POLICY"

  tags = {
    Name = "${var.resource_prefix}-lab-scp"
  }
}

# ── Save SCP JSON to local file for manual console application ───────────────
resource "local_file" "scp_json" {
  content  = data.aws_iam_policy_document.scp.json
  filename = "${path.module}/../policies/scp_policy.json"
}
