# Infrastructure Guide

This document explains what every resource in this project does, why it exists, and how to modify it. Read this before touching any `.tf` file.

---

## How the pieces fit together

Before diving into individual resources, here is the full picture of what gets deployed and why each piece exists:

```
┌─────────────────────────────────────────────────────────────────────┐
│  PROBLEM: How do you give a developer just enough AWS access        │
│  without risking they break production or escalate their own        │
│  privileges?                                                        │
│                                                                     │
│  SOLUTION: Four independent enforcement layers                      │
│                                                                     │
│  Layer 1 — SCP          WHO:  everyone in the account              │
│                         WHAT: region lock, CloudTrail protection    │
│                         WHY:  even root cannot bypass this          │
│                                                                     │
│  Layer 2 — Boundary     WHO:  developer-test user only             │
│                         WHAT: caps maximum permissions at S3+EC2   │
│                         WHY:  someone attaching AdministratorAccess │
│                               later still cannot break the ceiling  │
│                                                                     │
│  Layer 3 — Policy       WHO:  developer-test user only             │
│                         WHAT: grants scoped S3+EC2 with conditions  │
│                         WHY:  least privilege, only what is needed  │
│                                                                     │
│  Layer 4 — Session      WHO:  active assumed-role session only     │
│                         WHAT: further restricts at runtime         │
│                         WHY:  CI/CD jobs only touch what they need  │
└─────────────────────────────────────────────────────────────────────┘
```

Each layer is evaluated independently. If any layer says Deny, the request is blocked — no other layer can override it.

---

## File map

```
terraform/
├── providers.tf       Terraform engine config, AWS provider, shared tags
├── variables.tf       Input declarations (types + descriptions)
├── terraform.tfvars   Actual values for variables
├── vpc.tf             Network boundary + S3 test buckets
├── iam_user.tf        developer-test user + credentials
├── iam_policies.tf    The core developer policy (9 statements)
├── iam_boundary.tf    Permission ceiling + sandbox role
├── scp.tf             Account-level org policy + JSON export
├── access_analyzer.tf Public exposure scanner
└── outputs.tf         Values exported after apply
```

---

## `providers.tf` — Terraform engine and AWS provider

### Purpose

This file is the bootstrap for the entire project. It tells Terraform which version of Terraform itself is required, which external plugins (providers) to download, and how to configure the AWS provider with region and default tags.

Without this file, Terraform cannot initialize or run any other file.

### Why `default_tags` matters

```hcl
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

Every AWS resource created by this project automatically gets these four tags without you repeating them in every resource block. This enables cost allocation filtering, easy cleanup, and auditability of Terraform-managed resources.

### Why four providers?

| Provider | Why it is needed |
|----------|-----------------|
| `hashicorp/aws` | Creates all AWS resources |
| `hashicorp/random` | Generates a unique suffix for S3 bucket names (S3 names are globally unique across all accounts) |
| `hashicorp/local` | Writes the SCP JSON to a local file so you can apply it manually |
| `hashicorp/null` | Runs a CLI command for boundary attachment — there is no native Terraform resource for `put-user-permissions-boundary` |

### How to modify

**Change the deployment region** — do this in `terraform.tfvars`, not here:
```hcl
aws_region = "eu-west-1"
```

**Add a tag to every resource:**
```hcl
default_tags {
  tags = {
    Project    = "iam-policy-testing"
    ManagedBy  = "terraform"
    Environment = "lab"
    Owner      = "jhon"
    CostCenter = "platform-engineering"  # add here
  }
}
```

**Pin the AWS provider to an exact version** (recommended before production):
```hcl
aws = {
  source  = "hashicorp/aws"
  version = "= 5.50.0"  # exact instead of ~> 5.0
}
```

---

## `variables.tf` + `terraform.tfvars` — Configuration inputs

### Purpose

`variables.tf` declares what inputs the project accepts — names, types, and descriptions. It does not set values, only declares them.

`terraform.tfvars` sets the actual values. Terraform reads this file automatically on every `apply` and `plan`.

This separation means the same code can deploy to different environments by swapping `terraform.tfvars` values without touching any resource logic. It also makes the project self-documenting — every input has a description explaining what it controls.

### Why not hardcode values in resource files?

If you hardcode `account_id = "866934333672"` directly in `iam_policies.tf`, you must find and replace every occurrence when moving to a different account. With variables, you change one line in `terraform.tfvars` and every reference updates automatically.

### How to modify

**Change account or region:**
```hcl
# terraform.tfvars
aws_region = "eu-west-1"
account_id = "111122223333"
```

**Add a new variable:**

Step 1 — declare in `variables.tf`:
```hcl
variable "environment_name" {
  description = "The environment label applied to resources (lab, staging, prod)"
  type        = string
  default     = "lab"
}
```

Step 2 — set value in `terraform.tfvars`:
```hcl
environment_name = "staging"
```

Step 3 — use it in any resource:
```hcl
tags = {
  Environment = var.environment_name
}
```

**Never store credentials in `terraform.tfvars`.** AWS credentials must come from environment variables or `~/.aws/credentials`:
```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
```

---

## `vpc.tf` — Network boundary and S3 test buckets

### Purpose

This file creates two categories of resources that serve as **targets** for IAM policy conditions.

**The VPC exists so it can be referenced in an IAM condition.**

The developer policy says: "you may only launch EC2 instances inside this VPC." The VPC itself does not enforce anything — IAM evaluates the condition before EC2 even processes the request. But the VPC must exist first so its ID can be embedded in the policy ARN.

```
developer-test calls ec2:RunInstances
  IAM evaluates: is ec2:Vpc = arn:...:vpc/vpc-0569d66ed8a1e6de9 ?
    YES → allow
    NO  → deny (before EC2 sees the request)
```

**The two S3 buckets exist to validate tag-based conditions.**

- `jhon-lab-dev-team-*` tagged `Team=Dev` — the Policy Simulator and real API calls confirm the developer can read this
- `jhon-lab-production-*` tagged `Environment=production` — confirms the explicit Deny works

### Why the bucket names have a random suffix

S3 bucket names must be globally unique across all AWS accounts worldwide. Without the suffix, two people running this lab simultaneously would collide on the same name. The `random_id` resource generates 8 hex characters (e.g., `d01ce68a`) appended to the bucket name.

### Why `block_public_access` has four settings

```hcl
resource "aws_s3_bucket_public_access_block" "dev_team" {
  block_public_acls       = true   # ignore ACLs that grant public access
  block_public_policy     = true   # reject bucket policies granting public access
  ignore_public_acls      = true   # ignore any existing public ACLs
  restrict_public_buckets = true   # restrict to authorized users only
}
```

All four must be `true`. Missing even one creates a potential path to public exposure, which the Access Analyzer would flag as an active finding.

### How to modify

**Change the VPC CIDR** (to avoid collision with another VPC in your account):
```hcl
# terraform.tfvars
vpc_cidr           = "10.88.0.0/16"
public_subnet_cidr = "10.88.1.0/24"
```

The IAM policy condition updates automatically because it references `aws_vpc.lab.id` dynamically.

**Add a private subnet:**
```hcl
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.99.2.0/24"
  availability_zone = "${var.aws_region}b"

  tags = {
    Name = "${var.resource_prefix}-iam-lab-subnet-private"
  }
}
```

**Add a test object to the Dev bucket** so `GetObject` tests work against a real file:
```hcl
resource "aws_s3_object" "test_file" {
  bucket  = aws_s3_bucket.dev_team.id
  key     = "test/hello.txt"
  content = "Hello from the dev bucket"
}
```

**Add a third bucket** (e.g., staging — no special tag, neither accessible nor explicitly denied):
```hcl
resource "aws_s3_bucket" "staging" {
  bucket        = "${var.resource_prefix}-lab-staging-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = {
    Name        = "${var.resource_prefix}-lab-staging"
    Environment = "staging"
  }
}
```

---

## `iam_user.tf` — The developer-test user

### Purpose

This file creates the IAM identity that all policies are tested against. Three resources make up the complete user setup.

**`aws_iam_user.developer`** — the IAM user itself.

`force_destroy = true` is required for clean Terraform destruction. Without it, `terraform destroy` fails because AWS refuses to delete a user that has active access keys — you would need to delete them manually first. With `force_destroy`, Terraform deletes the keys automatically before deleting the user.

**`aws_iam_access_key.developer`** — programmatic credentials (Access Key ID + Secret).

These are used by the Python test scripts to call the Policy Simulator as this user's identity and to call `sts:AssumeRole` in Test 3. The key values are stored in Terraform state as sensitive outputs.

**`aws_iam_user_login_profile.developer`** — AWS Console password.

Allows manual testing via the IAM Policy Simulator UI in the console. `password_reset_required = true` forces a password change on first login, which is the correct security practice — Terraform never stores the final password.

### How to modify

**Rename the user** — update `terraform.tfvars` and the trust policy in `iam_boundary.tf` propagates automatically:
```hcl
# terraform.tfvars
developer_user_name = "dev-sandbox-user"
```

**Disable console access** — comment out or delete the `aws_iam_user_login_profile` resource. The user keeps programmatic access.

**Rotate the access key:**
```bash
terraform taint aws_iam_access_key.developer
terraform apply -auto-approve

# Re-export the new values
export AWS_ACCESS_KEY_ID=$(terraform output -raw developer_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(terraform output -raw developer_secret_access_key)
```

---

## `iam_policies.tf` — The core developer policy

### Purpose

This is the most important file. It defines exactly what `developer-test` can and cannot do using nine statements that implement four control layers.

**Why use `aws_iam_policy_document` instead of raw JSON?**

```hcl
data "aws_iam_policy_document" "developer" {
  statement {
    sid       = "S3ReadDevBuckets"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::*/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Team"
      values   = ["Dev"]
    }
  }
}
```

Terraform validates HCL syntax before deployment. Raw JSON has no validation — a typo silently creates a broken policy that you discover only when something fails at runtime.

### Statement-by-statement explanation

**`S3ListAllBuckets` — Allow listing all bucket names**

`s3:ListAllMyBuckets` is an account-level action. It lists bucket names, not contents. It cannot carry a resource ARN or tag condition because it does not target a specific resource. We allow it so the developer can see what buckets exist. The tag conditions on `GetObject` and `ListBucket` prevent them from reading the actual contents of non-Dev buckets.

**`S3ReadDevBuckets` — Allow reading buckets tagged `Team=Dev`**

This is **attribute-based access control (ABAC)**. Instead of listing specific bucket ARNs in the policy, we use a tag condition. Any bucket tagged `Team=Dev` becomes readable — including buckets created in the future. Without ABAC, you would need to update the policy every time a new Dev bucket is created.

```
Without ABAC: policy lists arn:aws:s3:::project-a, arn:aws:s3:::project-b
              → must update policy for every new bucket

With ABAC:    policy condition Team=Dev
              → tag the bucket → automatically accessible
```

**`EC2LaunchSmallInstances` — Allow RunInstances only for t2.micro/t3.micro**

The instance type condition only applies to the `instance` resource type within a `RunInstances` call. This is a separate statement from the VPC condition because AWS evaluates `RunInstances` conditions per-resource-type within the same API call.

**`EC2LaunchInLabVPC` — Allow RunInstances only inside the lab VPC**

`RunInstances` needs permissions on multiple resource types simultaneously: instance, subnet, security group, network interface, volume, AMI, key pair. The VPC restriction must be applied at the subnet and security group level because those are the resources that carry VPC membership. The condition:

```hcl
condition {
  test     = "ArnLike"
  variable = "ec2:Vpc"
  values   = ["arn:aws:ec2:${var.aws_region}:${var.account_id}:vpc/${aws_vpc.lab.id}"]
}
```

`aws_vpc.lab.id` is resolved at apply time — Terraform inserts the real VPC ID automatically, so no hardcoded values here.

**`EC2UseAMIs` — Allow RunInstances on any AMI**

AMIs are region-scoped resources that do not belong to a VPC. They cannot carry VPC or instance-type conditions. This statement allows the developer to use any AMI in the region. In a stricter policy, you would limit to account-owned or specific AMI IDs.

**`EC2ReadOnly` — Allow all Describe actions**

Describe actions are read-only. They allow the developer to list instances, VPCs, subnets, security groups, and AMIs — necessary information for making launch decisions. Without this, the developer cannot see what resources exist.

**`EC2ManageLabInstances` — Allow stop/start/terminate on own instances**

Allows the developer to manage instances they launched. The tag condition is a placeholder for a real stack-identifier tag pattern. In production, you would tag instances at launch with a team or project tag and restrict management to instances with that tag.

**`DenyProductionResources` — Explicit Deny on `Environment=production`**

This is the most critical statement. An explicit `Deny` cannot be overridden by any `Allow` anywhere — not in this policy, not in a future policy, not by an admin attaching `AdministratorAccess`. It is evaluated first in the IAM decision chain. Even if the developer somehow receives a broader policy later, they cannot touch anything tagged production.

**`DenyS3Destructive` — Explicit Deny on all S3 delete and modify actions**

Belt-and-suspenders. The S3 read-only statements already implicitly deny delete actions. The explicit Deny here ensures that even if someone adds a broader S3 Allow statement in the future, deletion remains blocked unconditionally — no combination of Allow statements can override it.

### How to modify

**Allow a new S3 action** — add to the `S3ReadDevBuckets` statement:
```hcl
actions = [
  "s3:GetObject",
  "s3:GetObjectVersion",
  "s3:ListBucket",
  "s3:GetBucketVersioning",
  "s3:GetBucketTagging",
  "s3:GetObjectTagging",   # add here
]
```

**Allow a larger instance type:**
```hcl
# EC2LaunchSmallInstances condition
values = ["t2.micro", "t3.micro", "t3.small"]
```

**Add an explicit deny for a new tag:**
```hcl
statement {
  sid    = "DenyCriticalTier"
  effect = "Deny"
  actions   = ["*"]
  resources = ["*"]

  condition {
    test     = "StringEquals"
    variable = "aws:ResourceTag/Tier"
    values   = ["critical"]
  }
}
```

**Attach the policy to an additional user:**
```hcl
resource "aws_iam_user_policy_attachment" "second_developer" {
  user       = aws_iam_user.second_developer.name
  policy_arn = aws_iam_policy.developer.arn
}
```

---

## `iam_boundary.tf` — Permission ceiling and sandbox role

### Purpose

This file serves two distinct purposes.

**1. Permission Boundary — `jhon-developer-boundary`**

A permission boundary defines the **maximum permissions** a user can ever have, regardless of what identity policies are attached. It does not grant anything — it only caps.

```
Scenario without boundary:
  developer-test + someone attaches AdministratorAccess = full admin

Scenario with boundary:
  developer-test + AdministratorAccess + boundary(S3+EC2 only)
  = S3+EC2 only    (boundary wins)
```

The boundary is especially important for **delegated administration protection**. If `developer-test` ever gained `iam:CreateUser`, they could create a new user without a boundary and grant that user admin access — escalating beyond their own permissions. The boundary prevents this because any user created by `developer-test` must also have the boundary, capping the escalation path.

The boundary allows a ceiling of S3 read and EC2 operations, and explicitly denies IAM write actions, Organizations changes, CloudTrail modification, and billing.

**2. Sandbox Role — `jhon-developer-sandbox-role`**

This role exists for Test 3 only. It has the same permissions as `developer-test` via the same attached policy. Its trust policy allows `developer-test` to assume it.

The role demonstrates **session policies** — an inline policy you pass at `sts:AssumeRole` time that further restricts the assumed session. The session policy is evaluated in addition to the role's policies:

```
Effective session permissions = (Role policy) ∩ (Session policy)
```

You can never gain more access via a session policy than the role has. It can only restrict.

### Why boundary attachment uses `null_resource` and not a Terraform argument

Terraform's `aws_iam_user` resource does not support setting a `permissions_boundary` in a way that avoids circular dependency when the boundary policy and user are in the same `apply`. The `null_resource` provisioner runs after both exist:

```hcl
provisioner "local-exec" {
  command = "aws iam put-user-permissions-boundary --user-name developer-test --permissions-boundary <ARN>"
}

# On destroy — removes boundary before user deletion
provisioner "local-exec" {
  when    = destroy
  command = "aws iam delete-user-permissions-boundary --user-name developer-test || true"
}
```

Without the destroy provisioner, `terraform destroy` fails — AWS does not allow deleting a user that has an active permissions boundary.

### Why `depends_on` on the sandbox role is mandatory

```hcl
resource "aws_iam_role" "developer_sandbox" {
  depends_on = [aws_iam_user.developer]
}
```

The trust policy contains a reference to the user ARN. AWS validates this ARN exists at role creation time. Without `depends_on`, Terraform may try to create the role in parallel with the user — if the role creation request reaches AWS before the user exists, AWS returns `MalformedPolicyDocument: Invalid principal` and the apply fails.

### How to modify

**Expand the boundary ceiling** — adding to the boundary does NOT grant the permission, the identity policy must also allow it:
```hcl
statement {
  sid    = "BoundaryAllowRDS"
  effect = "Allow"
  actions = [
    "rds:Describe*",
    "rds:ListTagsForResource",
  ]
  resources = ["*"]
}
```

**Allow a second user to assume the sandbox role:**
```hcl
data "aws_iam_policy_document" "assume_role_trust" {
  statement {
    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${var.account_id}:user/${var.developer_user_name}",
        "arn:aws:iam::${var.account_id}:user/second-developer",
      ]
    }
    actions = ["sts:AssumeRole"]
  }
}
```

**Increase the max session duration:**
```hcl
resource "aws_iam_role" "developer_sandbox" {
  max_session_duration = 7200  # 2 hours (AWS maximum is 43200 = 12 hours)
}
```

---

## `scp.tf` — Account-level org policy

### Purpose

A Service Control Policy (SCP) is fundamentally different from an IAM policy. It does not attach to a user or role — it attaches to an AWS Organizations Organizational Unit (OU) and applies to every identity in every account in that OU, including root.

```
IAM policy: "This user can do X"
SCP:        "Nobody in this entire OU can do Y, regardless of IAM policies"
```

SCPs are the last line of defense. Even `AdministratorAccess` cannot bypass an SCP.

This file generates the SCP JSON but does not apply it automatically because AWS Organizations must be enabled. The resource has `count = 0`. The JSON is written to `policies/scp_policy.json` for manual application via the console or CLI.

**The four SCP rules:**

**Rule 1 — Region lock:** Denies all actions outside `us-east-1` and `eu-west-1`. Uses `NotAction` to exclude global services (IAM, STS, Route53, CloudFront) because those services do not operate in a specific region. If you used `Action: ["*"]` with a region condition, IAM calls would fail because `aws:RequestedRegion` is empty for global services.

**Rule 2 — CloudTrail protection:** Denies all CloudTrail modification actions unconditionally. CloudTrail is the audit backbone. An attacker who disables it can operate without leaving traces. This rule has no condition — it applies to everyone including admins.

**Rule 3 — Organization lock:** Denies `organizations:LeaveOrganization`. An account that detaches itself from the OU escapes all SCPs immediately. This rule prevents that escape.

**Rule 4 — Root user restriction:** Denies all actions when `aws:PrincipalArn` matches the root user pattern `arn:aws:iam::*:root`. Root should never be used for day-to-day operations. This forces all operations through IAM identities.

### How to modify

**Add a region to the allowlist:**
```hcl
condition {
  test     = "StringNotEquals"
  variable = "aws:RequestedRegion"
  values   = ["us-east-1", "eu-west-1", "ap-southeast-1"]
}
```

**Enable automatic SCP creation** (requires Organizations):
```hcl
resource "aws_organizations_policy" "lab_scp" {
  count = 1  # change from 0 to 1
  ...
}

resource "aws_organizations_policy_attachment" "lab_scp" {
  count     = 1
  policy_id = aws_organizations_policy.lab_scp[0].id
  target_id = "ou-xxxx-yyyyyyyy"  # your OU ID from Organizations console
}
```

**Add a new protection rule** (e.g., deny disabling GuardDuty):
```hcl
statement {
  sid    = "DenyGuardDutyDisable"
  effect = "Deny"
  actions = [
    "guardduty:DeleteDetector",
    "guardduty:StopMonitoringMembers",
  ]
  resources = ["*"]
}
```

---

## `access_analyzer.tf` — Public exposure scanner

### Purpose

IAM Access Analyzer continuously monitors your account for resources accessible by principals **outside your AWS account**. It does not alert on internal IAM access — it specifically looks for cross-account or fully public access.

It scans S3 bucket policies, IAM roles with cross-account trust, KMS key policies, Lambda function policies, SQS queues, and Secrets Manager secrets. For each finding it reports which resource is exposed, which external principal can access it, and what actions they can take.

In this project the expected result is zero findings on our S3 buckets because all four `block_public_access` settings are enabled. The analyzer validates that the security posture is not just configured but actually effective.

**`ACCOUNT` vs `ORGANIZATION` type:**

`ACCOUNT` detects access granted to principals outside this account. `ORGANIZATION` detects access granted outside the entire AWS organization. `ORGANIZATION` is stronger but requires Organizations. For a standalone lab account, `ACCOUNT` is correct.

### How to modify

**Switch to organization-level analysis:**
```hcl
resource "aws_accessanalyzer_analyzer" "lab" {
  analyzer_name = "${var.resource_prefix}-lab-access-analyzer"
  type          = "ORGANIZATION"
}
```

**Add an archive rule** to suppress a known-good cross-account finding:
```hcl
resource "aws_accessanalyzer_archive_rule" "known_cicd" {
  analyzer_name = aws_accessanalyzer_analyzer.lab.analyzer_name
  rule_name     = "known-cicd-account-access"

  filter {
    criteria = "principal.AWS"
    eq       = ["arn:aws:iam::111122223333:root"]
  }
}
```

Archive rules tell the analyzer "this finding is intentional." Use them for known patterns like a CI/CD account reading from an artifact bucket — you acknowledge the access is correct and it stops appearing as active.

---

## `outputs.tf` — Exported values

### Purpose

Outputs make Terraform state values accessible to external tools without parsing the state file. After `terraform apply`, any output is retrievable with:

```bash
terraform output -raw output_name
```

The Python test scripts depend entirely on outputs exported as environment variables. If you skip the export step, the scripts exit immediately with a missing variable error.

Sensitive outputs (`sensitive = true`) are hidden in plain `terraform output` display but fully accessible with `-raw`. This prevents credentials from appearing in CI/CD logs accidentally.

### How to modify

**Add a new output:**
```hcl
output "subnet_id" {
  description = "ID of the public subnet — useful for EC2 launch testing"
  value       = aws_subnet.public.id
}
```

**Mark an existing output as sensitive:**
```hcl
output "lab_vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.lab.id
  sensitive   = true  # add this
}
```

**Use an output in a different Terraform project** (remote state):
```hcl
data "terraform_remote_state" "iam_lab" {
  backend = "s3"
  config = {
    bucket = "my-tfstate-bucket"
    key    = "iam-policy-testing/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_something" "example" {
  vpc_id = data.terraform_remote_state.iam_lab.outputs.lab_vpc_id
}
```
