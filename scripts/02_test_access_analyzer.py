#!/usr/bin/env python3
"""
IAM Access Analyzer — Findings Validator
Assignment 18: IAM Policy Testing and Validation

WHAT THIS SCRIPT DOES:
  Queries IAM Access Analyzer for active findings and validates that our
  S3 buckets show NO public access findings. A finding would mean a resource
  is accessible by principals outside our AWS account.

HOW TO RUN:
  export ANALYZER_ID=$(terraform -chdir=terraform output -raw access_analyzer_id)
  export DEV_BUCKET=$(terraform -chdir=terraform output -raw dev_bucket_name)
  export PROD_BUCKET=$(terraform -chdir=terraform output -raw production_bucket_name)
  python3 scripts/02_test_access_analyzer.py

SUCCESS CRITERIA:
  - Zero ACTIVE findings for our S3 buckets
  - Analyzer status is ACTIVE (not FAILED or DISABLED)
"""

import boto3
import os
import sys
import json

REGION      = "us-east-1"
ANALYZER_ID = os.environ.get("ANALYZER_ID", "")
DEV_BUCKET  = os.environ.get("DEV_BUCKET", "")
PROD_BUCKET = os.environ.get("PROD_BUCKET", "")

GREEN  = "\033[92m"
RED    = "\033[91m"
YELLOW = "\033[93m"
BLUE   = "\033[94m"
RESET  = "\033[0m"
BOLD   = "\033[1m"


def main():
    print(f"\n{BOLD}{BLUE}{'═' * 65}{RESET}")
    print(f"{BOLD}{BLUE}  Assignment 18 — Access Analyzer Findings Report{RESET}")
    print(f"{BOLD}{BLUE}{'═' * 65}{RESET}\n")

    if not ANALYZER_ID:
        print(f"{YELLOW}⚠️  ANALYZER_ID not set.{RESET}")
        print("   Run: export ANALYZER_ID=$(terraform -chdir=terraform output -raw access_analyzer_id)")
        sys.exit(1)

    client = boto3.client("accessanalyzer", region_name=REGION)

    # ── Step 1: Verify analyzer is ACTIVE ────────────────────────────────────
    try:
        analyzer = client.get_analyzer(analyzerName=ANALYZER_ID)["analyzer"]
        status   = analyzer["status"]
        color    = GREEN if status == "ACTIVE" else RED
        print(f"  Analyzer status: {color}{BOLD}{status}{RESET}")
        print(f"  Analyzer ARN:    {analyzer['arn']}\n")

        if status != "ACTIVE":
            print(f"{RED}  Analyzer is not ACTIVE — check IAM permissions or wait for initialization.{RESET}")
            sys.exit(1)
    except Exception as e:
        print(f"{RED}  Cannot get analyzer: {e}{RESET}")
        sys.exit(1)

    # ── Step 2: List all active findings ─────────────────────────────────────
    paginator = client.get_paginator("list_findings")
    pages     = paginator.paginate(
        analyzerArn=analyzer["arn"],
        filter={"status": {"eq": ["ACTIVE"]}},
    )

    all_findings = []
    for page in pages:
        all_findings.extend(page.get("findings", []))

    if not all_findings:
        print(f"  {GREEN}{BOLD}✅ No ACTIVE findings — all resources are private{RESET}\n")
    else:
        print(f"  {RED}{BOLD}⚠️  {len(all_findings)} ACTIVE finding(s) detected:{RESET}\n")
        for finding in all_findings:
            resource = finding.get("resource", "unknown")
            ftype    = finding.get("resourceType", "?")
            cond     = finding.get("condition", {})
            print(f"  {RED}→ Resource:  {resource}{RESET}")
            print(f"    Type:      {ftype}")
            print(f"    Condition: {json.dumps(cond, indent=2)}")
            print()

    # ── Step 3: Validate our specific buckets ─────────────────────────────────
    print(f"  {BOLD}Bucket-level checks:{RESET}")
    bucket_names = []
    if DEV_BUCKET:  bucket_names.append((DEV_BUCKET, "Dev bucket"))
    if PROD_BUCKET: bucket_names.append((PROD_BUCKET, "Production bucket"))

    all_clear = True
    for bucket_name, label in bucket_names:
        bucket_findings = [
            f for f in all_findings
            if bucket_name in f.get("resource", "")
        ]
        if bucket_findings:
            print(f"  {RED}❌ {label} ({bucket_name}) has {len(bucket_findings)} finding(s){RESET}")
            all_clear = False
        else:
            print(f"  {GREEN}✅ {label} ({bucket_name}) — no public access findings{RESET}")

    print()
    result_color = GREEN if all_clear else RED
    result_text  = "ALL CLEAR — no public access detected" if all_clear else "ISSUES FOUND — review findings above"
    print(f"  {result_color}{BOLD}Result: {result_text}{RESET}\n")

    sys.exit(0 if all_clear else 1)


if __name__ == "__main__":
    main()
