# Code Reference Guide

This document covers every script and Terraform file in detail — what each does, how it works internally, and how to modify it safely.

---

## Terraform Files

### `providers.tf`

Declares the Terraform version constraint and all provider dependencies.

```hcl
terraform {
  required_version = ">= 1.6.0"
  required_providers { ... }
}
```

**To modify:**
- Change `aws_region` default here or in `terraform.tfvars` — not in `providers.tf`
- To add a new provider (e.g., `kubernetes`), add a block inside `required_providers` and run `terraform init` again
- `default_tags` applies to every AWS resource automatically — add tags here that must appear on all resources

---

### `variables.tf` + `terraform.tfvars`

`variables.tf` declares inputs with types and descriptions. `terraform.tfvars` sets the actual values.

**Never put credentials in `terraform.tfvars`.** AWS credentials come from environment variables or `~/.aws/credentials`.

**To add a new variable:**
1. Declare it in `variables.tf`:
```hcl
variable "my_new_var" {
  description = "What this does"
  type        = string
  default     = "optional-default"
}
```
2. Set the value in `terraform.tfvars`:
```hcl
my_new_var = "my-value"
```
3. Reference it in any `.tf` file as `var.my_new_var`

---

### `vpc.tf`

Creates the network boundary and S3 test buckets.

#### Changing the VPC CIDR

Update `terraform.tfvars`:
```hcl
vpc_cidr           = "10.88.0.0/16"
public_subnet_cidr = "10.88.1.0/24"
```
Then `terraform apply`. Terraform will destroy and recreate the VPC and all dependent resources.

⚠️ If you change the VPC, the IAM policy condition in `iam_policies.tf` updates automatically because it references `aws_vpc.lab.id` dynamically — no manual ARN update needed.

#### Adding more subnets

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

#### Adding objects to the Dev bucket for testing

```hcl
resource "aws_s3_object" "test_file" {
  bucket  = aws_s3_bucket.dev_team.id
  key     = "test/hello.txt"
  content = "Hello from the Dev bucket"
}
```

This gives the test scripts a real object to call `GetObject` against.

---

### `iam_user.tf`

Creates the `developer-test` IAM user with console access and programmatic credentials.

#### Changing the username

Update `terraform.tfvars`:
```hcl
developer_user_name = "my-new-developer"
```

Also update the trust policy in `iam_boundary.tf` — it references the username in the principal ARN. Because it uses `var.developer_user_name`, the change propagates automatically.

#### Disabling console access

Remove or comment out the `aws_iam_user_login_profile` resource. The user will still have programmatic access via the access key.

#### Rotating the access key

Terraform manages one access key per user. To rotate:
```bash
terraform taint aws_iam_access_key.developer
terraform apply -auto-approve
```
This destroys the old key and creates a new one. Update any scripts that use the old key values.

---

### `iam_policies.tf`

The most complex file. Contains the nine-statement developer policy using `data.aws_iam_policy_document`.

#### How `aws_iam_policy_document` works

Terraform's `aws_iam_policy_document` data source generates valid IAM JSON from HCL blocks. Each `statement {}` block becomes one JSON statement. The `json` attribute outputs the final policy.

```hcl
data "aws_iam_policy_document" "developer" {
  statement {
    sid    = "MyStatement"
    effect = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::my-bucket/*"]
  }
}

resource "aws_iam_policy" "developer" {
  policy = data.aws_iam_policy_document.developer.json
}
```

#### Adding a new allowed S3 action

Find the `S3ReadDevBuckets` statement and add to the `actions` list:
```hcl
actions = [
  "s3:GetObject",
  "s3:GetObjectVersion",
  "s3:ListBucket",
  "s3:GetBucketVersioning",
  "s3:GetBucketTagging",
  "s3:GetObjectTagging",   # <── add here
]
```

#### Allowing a new instance type (e.g., t3.small)

Find `EC2LaunchSmallInstances` and update the condition:
```hcl
condition {
  test     = "StringEquals"
  variable = "ec2:InstanceType"
  values   = ["t2.micro", "t3.micro", "t3.small"]  # add here
}
```

#### Adding a new deny condition

Add a new `statement` block inside `data "aws_iam_policy_document" "developer"`:
```hcl
statement {
  sid    = "DenySpecificRegion"
  effect = "Deny"
  actions   = ["*"]
  resources = ["*"]

  condition {
    test     = "StringEquals"
    variable = "aws:RequestedRegion"
    values   = ["eu-west-2"]
  }
}
```

#### Attaching the policy to a new user or role

```hcl
resource "aws_iam_user_policy_attachment" "another_user" {
  user       = aws_iam_user.another_user.name
  policy_arn = aws_iam_policy.developer.arn
}
```

---

### `iam_boundary.tf`

Contains three resources: the boundary policy, the boundary attachment (`null_resource`), and the sandbox IAM role.

#### Expanding what the boundary allows

Find the `BoundaryAllowEC2` or `BoundaryAllowS3` statement and add actions:
```hcl
statement {
  sid    = "BoundaryAllowEC2"
  effect = "Allow"
  actions = [
    "ec2:Describe*",
    "ec2:RunInstances",
    "ec2:StartInstances",
    "ec2:StopInstances",
    "ec2:TerminateInstances",
    "ec2:CreateSecurityGroup",  # <── add here
  ]
  resources = ["*"]
}
```

⚠️ Adding to the boundary does NOT grant the permission. The identity policy must also allow it. The boundary is a ceiling, not a grant.

#### Changing the sandbox role max session duration

```hcl
resource "aws_iam_role" "developer_sandbox" {
  max_session_duration = 7200  # 2 hours (max is 43200 = 12 hours)
}
```

#### Adding a second principal to the trust policy

```hcl
data "aws_iam_policy_document" "assume_role_trust" {
  statement {
    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${var.account_id}:user/${var.developer_user_name}",
        "arn:aws:iam::${var.account_id}:user/another-user",  # add here
      ]
    }
    actions = ["sts:AssumeRole"]
  }
}
```

---

### `scp.tf`

Generates the SCP JSON but does not apply it (Organizations not required).

#### Enabling automatic SCP creation

If your account has AWS Organizations enabled, change:
```hcl
resource "aws_organizations_policy" "lab_scp" {
  count = 1  # change from 0 to 1
  ...
}
```

Then add an attachment:
```hcl
resource "aws_organizations_policy_attachment" "lab_scp" {
  count     = 1
  policy_id = aws_organizations_policy.lab_scp[0].id
  target_id = "ou-xxxx-yyyyyyyy"  # your OU ID
}
```

#### Adding a new region to the SCP allowlist

Find `DenyNonApprovedRegions` and update the values:
```hcl
condition {
  test     = "StringNotEquals"
  variable = "aws:RequestedRegion"
  values   = ["us-east-1", "eu-west-1", "ap-southeast-1"]  # add region
}
```

---

### `access_analyzer.tf`

Minimal file — creates the analyzer and optionally archive rules.

#### Adding an archive rule (suppress a known finding)

```hcl
resource "aws_accessanalyzer_archive_rule" "known_cross_account" {
  analyzer_name = aws_accessanalyzer_analyzer.lab.analyzer_name
  rule_name     = "known-cicd-access"

  filter {
    criteria = "principal.AWS"
    eq       = ["arn:aws:iam::111122223333:root"]  # trusted account
  }
}
```

Archive rules tell Access Analyzer "this finding is expected — don't show it as active."

---

## Python Scripts

### `01_test_policy_simulator.py`

Uses `iam:SimulatePrincipalPolicy` to test allow/deny decisions without executing real API calls.

#### Key function: `run_simulation()`

```python
def run_simulation(iam_client, user_arn, action, resource_arn, context_entries):
    response = iam_client.simulate_principal_policy(
        PolicySourceArn = user_arn,       # whose policies to evaluate
        ActionNames     = [action],        # one action per call
        ResourceArns    = [resource_arn],  # target resource
        ContextEntries  = context_entries, # simulated condition context (tags, etc.)
    )
    return response["EvaluationResults"][0]
```

`ContextEntries` is how you simulate resource tags. AWS does not look up real tags during simulation — you must supply them explicitly:

```python
context_entries = [
    {
        "ContextKeyName"  : "aws:ResourceTag/Team",
        "ContextKeyValues": ["Dev"],
        "ContextKeyType"  : "string",   # must be "string", not "arn"
    }
]
```

#### Adding a new test case

Add a `TestCase` object to the list returned by `build_test_cases()`:

```python
TestCase(
    name        = "TC-09: Deny RDS access",
    action      = "rds:DescribeDBInstances",
    resource_arn= "*",
    expected    = "implicitDeny",
    context_entries=[],
    description = "Developer has no RDS permissions",
),
```

Valid `expected` values:
- `"allowed"` — explicit Allow matched
- `"implicitDeny"` — no matching Allow found
- `"explicitDeny"` — a Deny statement matched

#### Changing the user being tested

Update `USER_ARN` at the top of the file:
```python
USER_ARN = f"arn:aws:iam::{ACCOUNT_ID}:user/different-user"
```

Or pass it as an environment variable by adding:
```python
USER_ARN = os.environ.get("USER_ARN", f"arn:aws:iam::{ACCOUNT_ID}:user/{USER_NAME}")
```

---

### `02_test_access_analyzer.py`

Queries the Access Analyzer API for active findings and validates that specific buckets have no public exposure.

#### Key logic: paginator

```python
paginator = client.get_paginator("list_findings")
pages = paginator.paginate(
    analyzerArn = analyzer["arn"],
    filter      = {"status": {"eq": ["ACTIVE"]}},
)
```

Paginators handle results automatically — Access Analyzer may return findings across multiple pages. Always use a paginator rather than calling `list_findings` directly.

#### Filtering findings by resource type

To check only S3 findings:
```python
pages = paginator.paginate(
    analyzerArn = analyzer["arn"],
    filter = {
        "status"       : {"eq": ["ACTIVE"]},
        "resourceType" : {"eq": ["AWS::S3::Bucket"]},
    },
)
```

#### Adding a new bucket to the validation list

```python
bucket_names = [
    (DEV_BUCKET,  "Dev bucket"),
    (PROD_BUCKET, "Production bucket"),
    (os.environ.get("THIRD_BUCKET", ""), "Third bucket"),  # add here
]
```

---

### `03_test_assume_role.py`

Demonstrates the session policy pattern using `sts:AssumeRole`.

#### How AssumeRole with session policy works

```python
restricted_response = sts.assume_role(
    RoleArn         = SANDBOX_ROLE_ARN,
    RoleSessionName = "my-session",       # appears in CloudTrail
    DurationSeconds = 900,                # 15 min
    Policy          = json.dumps(session_policy),  # inline session restriction
)
```

The `Policy` parameter is a JSON string. It is evaluated IN ADDITION to the role's policies:

```
Effective permissions = (Role policy) ∩ (Session policy)
```

The session policy **cannot grant more** than what the role has. Attempting to add `"Action": ["*"]` in the session policy does not give admin access — it is intersected with the role, so the result is still only what the role allows.

#### Changing what the restricted session can do

Modify the `session_policy` dict:
```python
session_policy = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect"  : "Allow",
            "Action"  : ["s3:GetObject", "s3:ListBucket"],
            "Resource": [
                f"arn:aws:s3:::{DEV_BUCKET}",
                f"arn:aws:s3:::{DEV_BUCKET}/*",
            ],
        }
    ],
}
```

#### Using the assumed role credentials

The temporary credentials returned by `AssumeRole` have three components:

```python
creds = response["Credentials"]

client = boto3.client(
    "s3",
    aws_access_key_id    = creds["AccessKeyId"],
    aws_secret_access_key= creds["SecretAccessKey"],
    aws_session_token    = creds["SessionToken"],   # required for temporary creds
)
```

`SessionToken` is mandatory when using temporary credentials. Omitting it causes `InvalidClientTokenId` errors.

---

## Common Modifications

### Test a different IAM user

```bash
export USER_ARN="arn:aws:iam::866934333672:user/another-user"
python3 scripts/01_test_policy_simulator.py
```

Update `USER_ARN` in the script to read from the environment variable.

### Add a new AWS service to the developer policy

1. Add an Allow statement in `iam_policies.tf`
2. Add the same service to the boundary `BoundaryAllow*` section in `iam_boundary.tf`
3. Add a test case in `01_test_policy_simulator.py`
4. Run `terraform apply -auto-approve` then re-run the test script

### Run tests against a different account

Update `terraform.tfvars`:
```hcl
account_id = "111122223333"
```

Update `ACCOUNT_ID` in each script or export it:
```bash
export ACCOUNT_ID=111122223333
```

### Change the resource prefix

```hcl
# terraform.tfvars
resource_prefix = "myteam"
```

All resource names update automatically on next `terraform apply`. This is useful when multiple people share the same account.
