#!/usr/bin/env python3
"""
IAM Policy Simulator — Automated Test Suite
Assignment 18: IAM Policy Testing and Validation

WHAT THIS SCRIPT DOES:
  Uses the AWS IAM Policy Simulator API to test whether specific actions
  are allowed or denied for the developer-test user WITHOUT actually
  performing those actions. This is a dry-run evaluation engine.

HOW TO RUN:
  1. Apply Terraform first to create all resources
  2. Export outputs:
       export DEV_BUCKET=$(terraform -chdir=terraform output -raw dev_bucket_name)
       export PROD_BUCKET=$(terraform -chdir=terraform output -raw production_bucket_name)
       export LAB_VPC_ID=$(terraform -chdir=terraform output -raw lab_vpc_id)
       export ACCOUNT_ID=866934333672
  3. Run:
       python3 scripts/01_test_policy_simulator.py

REQUIREMENTS:
  Your CLI profile must have iam:SimulatePrincipalPolicy permission.
  (Not the developer-test user — YOUR admin profile.)
"""

import boto3
import json
import os
import sys
from dataclasses import dataclass
from typing import Optional


# ── Configuration ──────────────────────────────────────────────────────────────

REGION      = "us-east-1"
ACCOUNT_ID  = os.environ.get("ACCOUNT_ID", "866934333672")
USER_NAME   = "developer-test"
USER_ARN    = f"arn:aws:iam::{ACCOUNT_ID}:user/{USER_NAME}"

DEV_BUCKET  = os.environ.get("DEV_BUCKET", "")
PROD_BUCKET = os.environ.get("PROD_BUCKET", "")
LAB_VPC_ID  = os.environ.get("LAB_VPC_ID", "")

# ── Colors for terminal output ─────────────────────────────────────────────────

GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
BLUE   = "\033[94m"
RESET  = "\033[0m"
BOLD   = "\033[1m"


@dataclass
class TestCase:
    name: str
    action: str
    resource_arn: str
    expected: str          # "allowed" or "implicitDeny" or "explicitDeny"
    context_entries: list  # IAM condition context keys (simulate resource tags)
    description: str


def build_test_cases() -> list[TestCase]:
    """
    Define the six required test cases from the assignment brief,
    plus extra cases for thorough coverage.
    """
    dev_bucket_arn  = f"arn:aws:s3:::{DEV_BUCKET}"
    prod_bucket_arn = f"arn:aws:s3:::{PROD_BUCKET}"

    return [
        # ── Test 1: Can list S3 buckets (REQUIRED) ─────────────────────────
        TestCase(
            name        = "TC-01: List all S3 buckets",
            action      = "s3:ListAllMyBuckets",
            resource_arn= "*",
            expected    = "allowed",
            context_entries=[],
            description = "Developer must be able to see bucket names (not content)",
        ),

        # ── Test 2: Cannot delete S3 objects (REQUIRED) ────────────────────
        TestCase(
            name        = "TC-02: Deny S3 DeleteObject",
            action      = "s3:DeleteObject",
            resource_arn= f"{dev_bucket_arn}/*",
            expected    = "explicitDeny",
            context_entries=[
                {
                    "ContextKeyName"  : "aws:ResourceTag/Team",
                    "ContextKeyValues": ["Dev"],
                    "ContextKeyType"  : "string",
                },
            ],
            description = "Even inside a Dev bucket, deletion must be blocked",
        ),

        # ── Test 3: Can launch t2.micro (REQUIRED) ─────────────────────────
        TestCase(
            name        = "TC-03: Allow RunInstances t2.micro",
            action      = "ec2:RunInstances",
            resource_arn= f"arn:aws:ec2:{REGION}:{ACCOUNT_ID}:instance/*",
            expected    = "allowed",
            context_entries=[
                {
                    "ContextKeyName"  : "ec2:InstanceType",
                    "ContextKeyValues": ["t2.micro"],
                    "ContextKeyType"  : "string",
                },
            ],
            description = "t2.micro is in the allowed instance type list",
        ),

        # ── Test 4: Cannot launch t2.large (REQUIRED) ──────────────────────
        TestCase(
            name        = "TC-04: Deny RunInstances t2.large",
            action      = "ec2:RunInstances",
            resource_arn= f"arn:aws:ec2:{REGION}:{ACCOUNT_ID}:instance/*",
            expected    = "implicitDeny",
            context_entries=[
                {
                    "ContextKeyName"  : "ec2:InstanceType",
                    "ContextKeyValues": ["t2.large"],
                    "ContextKeyType"  : "string",
                },
            ],
            description = "t2.large is not in the allowed list — implicit deny",
        ),

        # ── Test 5: Can read Dev-tagged bucket ─────────────────────────────
        TestCase(
            name        = "TC-05: Allow GetObject from Dev bucket",
            action      = "s3:GetObject",
            resource_arn= f"{dev_bucket_arn}/*",
            expected    = "allowed",
            context_entries=[
                {
                    "ContextKeyName"  : "aws:ResourceTag/Team",
                    "ContextKeyValues": ["Dev"],
                    "ContextKeyType"  : "string",
                },
            ],
            description = "Dev bucket (Team=Dev) should be readable",
        ),

        # ── Test 6: Cannot access production bucket ─────────────────────────
        TestCase(
            name        = "TC-06: Deny access to production bucket",
            action      = "s3:GetObject",
            resource_arn= f"{prod_bucket_arn}/*",
            expected    = "explicitDeny",
            context_entries=[
                {
                    "ContextKeyName"  : "aws:ResourceTag/Environment",
                    "ContextKeyValues": ["production"],
                    "ContextKeyType"  : "string",
                },
            ],
            description = "Production bucket (Environment=production) must be blocked by explicit Deny",
        ),

        # ── Test 7: Cannot launch t2.large even with VPC context ────────────
        TestCase(
            name        = "TC-07: Deny t2.large regardless of VPC",
            action      = "ec2:RunInstances",
            resource_arn= f"arn:aws:ec2:{REGION}:{ACCOUNT_ID}:instance/*",
            expected    = "implicitDeny",
            context_entries=[
                {
                    "ContextKeyName"  : "ec2:InstanceType",
                    "ContextKeyValues": ["t2.large"],
                    "ContextKeyType"  : "string",
                },
                {
                    "ContextKeyName"  : "ec2:Vpc",
                    "ContextKeyValues": [f"arn:aws:ec2:{REGION}:{ACCOUNT_ID}:vpc/{LAB_VPC_ID}"],
                    "ContextKeyType"  : "string",
                },
            ],
            description = "VPC context doesn't override instance-type restriction",
        ),

        # ── Test 8: Cannot delete S3 bucket ────────────────────────────────
        TestCase(
            name        = "TC-08: Deny s3:DeleteBucket",
            action      = "s3:DeleteBucket",
            resource_arn= dev_bucket_arn,
            expected    = "explicitDeny",
            context_entries=[
                {
                    "ContextKeyName"  : "aws:ResourceTag/Team",
                    "ContextKeyValues": ["Dev"],
                    "ContextKeyType"  : "string",
                },
            ],
            description = "DeleteBucket is in the explicit deny list regardless of tag",
        ),
    ]


def run_simulation(
    iam_client,
    user_arn: str,
    action: str,
    resource_arn: str,
    context_entries: list,
) -> dict:
    """
    Calls iam:SimulatePrincipalPolicy for a single action + resource.
    Returns the simulation result dict.
    """
    kwargs = {
        "PolicySourceArn"   : user_arn,
        "ActionNames"       : [action],
        "ResourceArns"      : [resource_arn] if resource_arn != "*" else ["*"],
    }

    if context_entries:
        kwargs["ContextEntries"] = context_entries

    response = iam_client.simulate_principal_policy(**kwargs)
    return response["EvaluationResults"][0]


def print_header():
    print(f"\n{BOLD}{BLUE}{'═' * 65}{RESET}")
    print(f"{BOLD}{BLUE}  Assignment 18 — IAM Policy Simulator Test Suite{RESET}")
    print(f"{BOLD}{BLUE}  User: {USER_ARN}{RESET}")
    print(f"{BOLD}{BLUE}{'═' * 65}{RESET}\n")


def print_result(tc: TestCase, result: dict, passed: bool):
    actual   = result.get("EvalDecision", "unknown")
    icon     = f"{GREEN}✅ PASS{RESET}" if passed else f"{RED}❌ FAIL{RESET}"
    expected = f"{GREEN}{tc.expected}{RESET}" if passed else f"{RED}{tc.expected}{RESET}"
    actual_c = f"{GREEN}{actual}{RESET}" if passed else f"{RED}{actual}{RESET}"

    print(f"  {icon}  {BOLD}{tc.name}{RESET}")
    print(f"         {tc.description}")
    print(f"         Action:   {tc.action}")
    print(f"         Expected: {expected}  |  Got: {actual_c}")

    # Show which policy caused the decision (helps debug)
    matched = result.get("MatchedStatements", [])
    if matched:
        sids = [s.get("SourcePolicyId", "?") for s in matched]
        print(f"         Matched:  {', '.join(sids)}")

    print()


def main():
    print_header()

    # Validate env vars
    missing = []
    if not DEV_BUCKET  : missing.append("DEV_BUCKET")
    if not PROD_BUCKET : missing.append("PROD_BUCKET")
    if not LAB_VPC_ID  : missing.append("LAB_VPC_ID")

    if missing:
        print(f"{YELLOW}⚠️  Missing env vars: {', '.join(missing)}{RESET}")
        print(f"   Run: export DEV_BUCKET=$(terraform -chdir=terraform output -raw dev_bucket_name)")
        print(f"        export PROD_BUCKET=$(terraform -chdir=terraform output -raw production_bucket_name)")
        print(f"        export LAB_VPC_ID=$(terraform -chdir=terraform output -raw lab_vpc_id)")
        sys.exit(1)

    iam = boto3.client("iam", region_name=REGION)
    test_cases = build_test_cases()

    passed = 0
    failed = 0
    errors = 0

    for tc in test_cases:
        try:
            result  = run_simulation(iam, USER_ARN, tc.action, tc.resource_arn, tc.context_entries)
            actual  = result.get("EvalDecision", "")
            ok      = actual == tc.expected
            print_result(tc, result, ok)
            if ok: passed += 1
            else:  failed += 1

        except Exception as e:
            print(f"  {RED}💥 ERROR{RESET}  {tc.name}")
            print(f"         {str(e)}\n")
            errors += 1

    # ── Summary ───────────────────────────────────────────────────────────────
    total = len(test_cases)
    color = GREEN if failed == 0 and errors == 0 else RED
    print(f"{BOLD}{color}{'─' * 65}{RESET}")
    print(f"{BOLD}{color}  Results: {passed}/{total} passed  |  {failed} failed  |  {errors} errors{RESET}")
    print(f"{BOLD}{color}{'─' * 65}{RESET}\n")

    sys.exit(0 if (failed == 0 and errors == 0) else 1)


if __name__ == "__main__":
    main()
