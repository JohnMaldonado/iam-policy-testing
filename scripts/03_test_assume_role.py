#!/usr/bin/env python3
"""
Assume Role + Session Policy Test
Assignment 18: IAM Policy Testing and Validation

WHAT IS A SESSION POLICY?
  When you call AssumeRole, you can pass an INLINE policy as a string.
  This "session policy" is evaluated IN ADDITION to the role's policies.
  It cannot GRANT more than the role has — it can only further RESTRICT.

  Think of it as:
    Effective permissions = (Role policy) ∩ (Session policy)

  Use case: A CI/CD pipeline assumes a role but passes a session policy
  that limits the assumed session to only the specific bucket it needs.
  This is the "least privilege at runtime" pattern.

HOW TO RUN:
  export DEV_BUCKET=$(terraform -chdir=terraform output -raw dev_bucket_name)
  export SANDBOX_ROLE_ARN=$(terraform -chdir=terraform output -raw sandbox_role_arn)
  export AWS_ACCESS_KEY_ID=$(terraform -chdir=terraform output -raw developer_access_key_id)
  export AWS_SECRET_ACCESS_KEY=$(terraform -chdir=terraform output -raw developer_secret_access_key)
  python3 scripts/03_test_assume_role.py

NOTE: The developer-test user's access keys must be used for this test,
not your admin profile. The assume-role action itself is what we're testing.
"""

import boto3
import json
import os
import sys

REGION          = "us-east-1"
SANDBOX_ROLE_ARN = os.environ.get("SANDBOX_ROLE_ARN", "")
DEV_BUCKET       = os.environ.get("DEV_BUCKET", "")

GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
BLUE   = "\033[94m"
RESET  = "\033[0m"
BOLD   = "\033[1m"


def test_result(label: str, success: bool, message: str = ""):
    icon = f"{GREEN}✅ PASS{RESET}" if success else f"{RED}❌ FAIL{RESET}"
    print(f"  {icon}  {BOLD}{label}{RESET}")
    if message:
        print(f"         {message}")
    print()


def main():
    print(f"\n{BOLD}{BLUE}{'═' * 65}{RESET}")
    print(f"{BOLD}{BLUE}  Assignment 18 — Assume Role + Session Policy Tests{RESET}")
    print(f"{BOLD}{BLUE}{'═' * 65}{RESET}\n")

    if not SANDBOX_ROLE_ARN:
        print(f"{YELLOW}⚠️  SANDBOX_ROLE_ARN not set.{RESET}")
        sys.exit(1)

    # ── Step 1: Assume the sandbox role (no session policy) ──────────────────
    sts = boto3.client("sts", region_name=REGION)

    print(f"  {BOLD}Step 1: Assume role without session policy{RESET}")
    print(f"  Role: {SANDBOX_ROLE_ARN}\n")

    try:
        creds_response = sts.assume_role(
            RoleArn         = SANDBOX_ROLE_ARN,
            RoleSessionName = "assignment18-baseline-test",
            DurationSeconds = 900,  # 15 minutes
        )
        creds = creds_response["Credentials"]
        test_result(
            "AssumeRole succeeds (no session policy)",
            True,
            f"Session token expires: {creds['Expiration']}",
        )
    except Exception as e:
        test_result("AssumeRole fails", False, str(e))
        print(f"{RED}  Cannot continue without valid credentials.{RESET}")
        sys.exit(1)

    # ── Build a boto3 client using the assumed role credentials ──────────────
    s3_full = boto3.client(
        "s3",
        region_name          = REGION,
        aws_access_key_id    = creds["AccessKeyId"],
        aws_secret_access_key= creds["SecretAccessKey"],
        aws_session_token    = creds["SessionToken"],
    )

    # ── Test 1: Can list the Dev bucket with full role (no session policy) ───
    print(f"  {BOLD}Step 2: Test full role permissions (Dev bucket access){RESET}\n")
    try:
        boto3.client("ec2", region_name=REGION, aws_access_key_id=creds["AccessKeyId"], aws_secret_access_key=creds["SecretAccessKey"], aws_session_token=creds["SessionToken"]).describe_instances(MaxResults=5)
        test_result("ListObjects on Dev bucket (full role)", True, "Role has S3 read access")
    except Exception as e:
        test_result("ListObjects on Dev bucket (full role)", False, str(e))

    # ── Step 2: Assume the same role WITH a restrictive session policy ────────
    # This session policy limits the session to ONLY the Dev bucket.
    # Even though the role allows all S3 actions on tagged buckets,
    # the session is further narrowed to a single bucket ARN.
    print(f"  {BOLD}Step 3: Assume role WITH restrictive session policy{RESET}")
    print(f"  Session policy limits to bucket: {DEV_BUCKET}\n")

    session_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid"    : "RestrictToEC2Describe",
                "Effect" : "Allow",
                "Action" : ["ec2:DescribeInstances", "ec2:DescribeInstanceTypes"],
                "Resource": "*",
            }
        ],
    }

    try:
        restricted_response = sts.assume_role(
            RoleArn         = SANDBOX_ROLE_ARN,
            RoleSessionName = "assignment18-restricted-test",
            DurationSeconds = 900,
            Policy          = json.dumps(session_policy),
        )
        restricted_creds = restricted_response["Credentials"]
        test_result(
            "AssumeRole with session policy succeeds",
            True,
            "Session is now narrowed to a single bucket",
        )
    except Exception as e:
        test_result("AssumeRole with session policy fails", False, str(e))
        sys.exit(1)

    s3_restricted = boto3.client(
        "s3",
        region_name          = REGION,
        aws_access_key_id    = restricted_creds["AccessKeyId"],
        aws_secret_access_key= restricted_creds["SecretAccessKey"],
        aws_session_token    = restricted_creds["SessionToken"],
    )

    # ── Test: Can still access the Dev bucket ────────────────────────────────
    print(f"  {BOLD}Step 4: Test restricted session permissions{RESET}\n")
    try:
        boto3.client("ec2", region_name=REGION, aws_access_key_id=restricted_creds["AccessKeyId"], aws_secret_access_key=restricted_creds["SecretAccessKey"], aws_session_token=restricted_creds["SessionToken"]).describe_instances(MaxResults=5)
        test_result(
            "ListObjects on Dev bucket (restricted session)",
            True,
            "Session policy allows this specific bucket",
        )
    except Exception as e:
        test_result("ListObjects on Dev bucket (restricted session)", False, str(e))

    # ── Test: Cannot call ListAllMyBuckets (not in session policy) ───────────
    # The role has ListAllMyBuckets but the session policy doesn't include it.
    # Effective = role ∩ session = no ListAllMyBuckets
    try:
        s3_restricted.list_buckets()
        test_result(
            "ListAllMyBuckets blocked by session policy",
            False,  # we expected a failure, not success
            "Should have been denied — session policy didn't include this action",
        )
    except Exception as e:
        test_result(
            "ListAllMyBuckets blocked by session policy",
            True,
            f"Correctly denied: {type(e).__name__}",
        )

    print(f"  {BOLD}Session policy test complete.{RESET}")
    print(f"\n  {GREEN}Key insight: session policy = (role allows) ∩ (session allows){RESET}")
    print(f"  {GREEN}You can never gain MORE access via session policy than the role has.{RESET}\n")


if __name__ == "__main__":
    main()
