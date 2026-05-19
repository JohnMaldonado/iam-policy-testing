# =============================================================================
# IAM ACCESS ANALYZER
# =============================================================================
# Access Analyzer continuously scans your account for resources that are
# shared with external principals (outside your account or organization).
#
# It analyzes:
#   - S3 bucket policies
#   - IAM roles with cross-account trust
#   - KMS key policies
#   - Lambda function policies
#   - SQS queue policies
#   - Secrets Manager secrets
#
# The analyzer generates "findings" when it detects external access.
# Findings are not necessarily bad — you may intentionally share resources.
# But you must review them and either archive (acknowledge) or fix them.
#
# For this lab:
#   - We create the analyzer in us-east-1
#   - Our S3 buckets block public access, so the analyzer should show
#     NO public findings — validating our configuration is correct
# =============================================================================

resource "aws_accessanalyzer_analyzer" "lab" {
  analyzer_name = "${var.resource_prefix}-lab-access-analyzer"
  type          = "ACCOUNT" # analyzes resources shared outside this account
  # Use "ORGANIZATION" if you have AWS Organizations enabled

  tags = {
    Name = "${var.resource_prefix}-lab-access-analyzer"
  }
}

# ── Archive Rule: ignore expected cross-account shares ───────────────────────
# In a real environment, you'd add archive rules for known-good cross-account
# access (e.g., your CI/CD account accessing your artifact bucket).
# For this lab we leave it empty — we want to see all findings.
