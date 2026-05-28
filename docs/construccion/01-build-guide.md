# Build Guide — How This Project Was Constructed

This document explains every decision made during the construction of this project, in the exact order things were built. It is written so that someone starting from zero can understand not just what was built, but why each piece was built before the next.

---

## The problem we were solving

Before writing a single line of code, the problem was defined:

> A developer needs access to AWS. They need to read S3 buckets tagged for their team, launch small EC2 instances in a controlled network, and absolutely nothing else — especially not production resources.

That problem has four parts:

1. What can they read? S3 buckets tagged Team=Dev
2. What can they launch? EC2 t2.micro or t3.micro only
3. Where can they launch? Only inside a specific VPC
4. What can they never touch? Anything tagged Environment=production

Every file in this project exists to solve one of those four parts.

---

## Step 1 — Decide the folder structure before writing any code

Before touching Terraform or Python, the project structure was planned:

```
assignment-18-iam-policy-testing/
├── terraform/     all infrastructure as code
├── policies/      generated policy JSON files
├── scripts/       Python test scripts
└── docs/          all documentation
```

Terraform manages infrastructure lifecycle. The Python scripts test those resources after they exist. Mixing them would make the project harder to understand. Each folder has a single clear responsibility.

The policies/ folder exists because the SCP cannot be applied automatically without AWS Organizations. Terraform generates the JSON and writes it there so anyone can pick it up and apply it manually.

---

## Step 2 — Write providers.tf first

providers.tf is always the first file because nothing else can run without it.

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws    = { source = "hashicorp/aws",    version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.5" }
    local  = { source = "hashicorp/local",  version = "~> 2.4" }
    null   = { source = "hashicorp/null",   version = "~> 3.2" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "iam-policy-testing"
      ManagedBy   = "terraform"
      Environment = "lab"
      Owner       = "jhon"
    }
  }
}
```

The default_tags block was added here, not later. This guarantees every resource in every file gets those tags automatically. If you add default tags after creating resources, you need to recreate them to apply the tags.

Four providers were needed:
- aws: creates all AWS resources
- random: generates unique S3 bucket name suffix
- local: writes SCP JSON to disk
- null: runs CLI commands that have no native Terraform resource

---

## Step 3 — Define all variables before any resource

variables.tf was written second, before any resource file. If you write resources first and hardcode values, you then have to go back and replace every hardcoded value with a variable reference. Writing variables first means resources reference var.x from the start.

```hcl
variable "aws_region"          { default = "us-east-1" }
variable "account_id"          { }          # no default — must be provided
variable "resource_prefix"     { default = "jhon" }
variable "developer_user_name" { default = "developer-test" }
variable "vpc_cidr"            { default = "10.99.0.0/16" }
variable "public_subnet_cidr"  { default = "10.99.1.0/24" }
```

account_id has no default intentionally. It must be explicitly set in terraform.tfvars because it is account-specific and should never be accidentally defaulted to the wrong account.

The resource_prefix = "jhon" pattern ensures every resource name is unique within the shared account. Without it, two people running the same lab would collide on identical resource names.

---

## Step 4 — Create the VPC before IAM resources

The VPC must exist before the IAM policy that references it. The developer policy contains this condition:

```hcl
condition {
  test     = "ArnLike"
  variable = "ec2:Vpc"
  values   = ["arn:aws:ec2:${var.aws_region}:${var.account_id}:vpc/${aws_vpc.lab.id}"]
}
```

aws_vpc.lab.id is the VPC ID that AWS assigns when the VPC is created. Terraform resolves this dependency automatically, but understanding it is important for debugging.

Why 10.99.0.0/16? The shared account has many VPCs, most using 10.0.0.0/16. Using 10.99.0.0/16 avoids overlap and makes this VPC immediately identifiable as belonging to this lab.

The S3 buckets were placed in vpc.tf because they share the random_id suffix resource, keeping related resources together.

---

## Step 5 — Create the IAM user

The user was created before the policies because policies need to reference the user, and the user must exist before the boundary attachment runs.

Three decisions were made here:

**force_destroy = true**
Without this, terraform destroy fails if the user has active access keys. Since this lab is created and destroyed repeatedly, force_destroy is mandatory.

**Both access key and login profile**
The access key is needed for Python test scripts. The login profile is needed for manual testing in the AWS Console. Both serve distinct purposes.

**password_reset_required = true**
Terraform stores the initial password in state. Forcing a reset means the final password is never in Terraform state. Infrastructure code should not store operational credentials.

---

## Step 6 — Build the developer policy

This was the most complex step. The policy required nine statements across four control layers.

**Why use aws_iam_policy_document instead of raw JSON?**

Terraform validates HCL syntax before deployment. Each statement is a named block. Conditions are structured. The .json attribute generates correctly formatted IAM JSON automatically. Raw JSON has no validation — a typo creates a broken policy you discover only at runtime.

**The RunInstances problem — why three statements**

RunInstances acts on multiple resource types in a single API call. AWS evaluates conditions per resource type. Three statements were required:

```
EC2LaunchSmallInstances:
  resource: instance/*
  condition: InstanceType = t2.micro or t3.micro

EC2LaunchInLabVPC:
  resource: subnet/*, security-group/*, network-interface/*, volume/*, key-pair/*
  condition: ec2:Vpc = lab VPC ARN

EC2UseAMIs:
  resource: image/*
  no condition — AMIs are global resources with no VPC
```

**Why explicit Deny for production**

An implicit deny can be bypassed by attaching a second policy with a broader Allow. An explicit Deny cannot — it wins against any Allow, anywhere, in any policy. In a shared account where policies can be attached accidentally, explicit Deny on production provides an unbreakable guarantee.

---

## Step 7 — Build the permission boundary

The boundary was built after the user and policy so it could reference the policy ARN.

**Why not use the same policy as the boundary?**

The boundary defines the ceiling — what is theoretically possible. The identity policy defines what is actually granted. This separation lets you expand the ceiling without granting anything, or restrict the identity policy without touching the boundary.

**The boundary attachment challenge**

Terraform's aws_iam_user does not support permissions_boundary cleanly in the same apply. A null_resource with local-exec was used:

```hcl
provisioner "local-exec" {
  command = "aws iam put-user-permissions-boundary --user-name developer-test --permissions-boundary <ARN>"
}

provisioner "local-exec" {
  when    = destroy
  command = "aws iam delete-user-permissions-boundary --user-name developer-test || true"
}
```

The destroy provisioner is critical. AWS refuses to delete a user with an active permissions boundary, so the boundary must be removed first during terraform destroy.

---

## Step 8 — Build the sandbox role

The sandbox role depends on both the user (trust policy) and the developer policy (attached permissions). It was built last among IAM resources.

depends_on = [aws_iam_user.developer] was added after encountering a race condition error (see troubleshooting guide ERR-02). AWS validates trust policy principals at creation time — the user must exist first.

```hcl
resource "aws_iam_role" "developer_sandbox" {
  depends_on           = [aws_iam_user.developer]
  name                 = "${var.resource_prefix}-developer-sandbox-role"
  assume_role_policy   = data.aws_iam_policy_document.assume_role_trust.json
  max_session_duration = 3600
}
```

---

## Step 9 — Build the SCP

The SCP was built as a data source only because the shared account does not have AWS Organizations enabled. The resource block has count = 0.

The key design decision was NotAction for the region restriction:

```hcl
# Wrong — breaks IAM, STS, Route53
statement {
  effect  = "Deny"
  actions = ["*"]
  condition { aws:RequestedRegion not in approved list }
}

# Correct — excludes global services from region restriction
statement {
  effect      = "Deny"
  not_actions = ["iam:*", "sts:*", "route53:*", "cloudfront:*"]
  condition   { aws:RequestedRegion not in approved list }
}
```

Global services have no region. Including them in a region restriction causes all IAM and login calls to fail.

A local_file resource writes the generated JSON to policies/scp_policy.json so it can be applied manually.

---

## Step 10 — Build the Access Analyzer

One resource, two arguments. ACCOUNT type was chosen because the account is not in an AWS Organization.

```hcl
resource "aws_accessanalyzer_analyzer" "lab" {
  analyzer_name = "${var.resource_prefix}-lab-access-analyzer"
  type          = "ACCOUNT"
}
```

---

## Step 11 — Write outputs

Outputs were written last because they reference values from all other resources. Every value the Python scripts need was exported. Sensitive outputs use sensitive = true to prevent credentials appearing in logs.

---

## Step 12 — Write the Python test scripts

Three scripts, each testing one layer:

```
01_test_policy_simulator.py  tests the identity policy
02_test_access_analyzer.py   tests public exposure
03_test_assume_role.py       tests session policy behavior
```

Script 01 uses iam:SimulatePrincipalPolicy — a dry-run evaluator that does not execute the actual action. Eight test cases cover all four policy layers.

Script 02 uses the list_findings paginator. A paginator is required because the API paginates results. The critical check filters by our specific bucket names, not by total finding count.

Script 03 makes two AssumeRole calls — one without session policy and one with. It validates that a session policy restricts but never expands role permissions.

---

## Build order summary

```
1.  providers.tf          Terraform engine + AWS connection
2.  variables.tf          All inputs declared before use
3.  terraform.tfvars      Actual values
4.  vpc.tf                VPC + subnets + S3 buckets
5.  iam_user.tf           developer-test user + credentials
6.  iam_policies.tf       Core developer policy
7.  iam_boundary.tf       Permission boundary + sandbox role
8.  scp.tf                SCP JSON generation
9.  access_analyzer.tf    Public exposure scanner
10. outputs.tf            All exported values
11. scripts/01_*.py       Policy Simulator tests
12. scripts/02_*.py       Access Analyzer validation
13. scripts/03_*.py       Session policy demonstration
```

The rule behind this order: dependencies before dependents. A resource that references another must always exist first — even if Terraform resolves the order automatically, understanding the dependency chain is essential for debugging.
