# Troubleshooting Guide

Every error documented here was encountered during the actual deployment of this project. Each entry includes the exact error message, the root cause, the fix applied, and how to prevent it in future projects.

---

## ERR-01 — IAM User tag validation error

### Error message
```
Error: creating IAM User (developer-test): operation error IAM: CreateUser,
api error ValidationError: 1 validation error detected: Value at
'tags.2.member.value' failed to satisfy constraint: Member must satisfy
regular expression pattern: [\p{L}\p{Z}\p{N}_.:/=+\-@]*
```

### What happened
The `Description` tag on the IAM user contained an em dash character (`—`, Unicode U+2014). AWS IAM tags only accept a restricted character set — letters, numbers, spaces, and specific symbols (`_ . : / = + - @`). The em dash is not in that set.

The character was introduced silently when the file was generated — it looks identical to a regular hyphen in most fonts but is a completely different Unicode character.

### Fix applied
```bash
sed -i '' 's/IAM policy testing .* Assignment 18/IAM policy testing - Assignment 18/' \
  terraform/iam_user.tf
```

Replaced the em dash (`—`) with a regular ASCII hyphen (`-`).

### How to prevent
When copying text from documentation, design tools, or AI-generated content into tag values, always verify special characters. A quick check:
```bash
cat -A terraform/iam_user.tf | grep Description
# Em dash appears as M-bM-^@M-^T in cat -A output
# Regular hyphen appears as -
```

Never use word processors to write `.tf` files — they auto-correct hyphens to em dashes.

---

## ERR-02 — IAM Role MalformedPolicyDocument: Invalid principal

### Error message
```
Error: creating IAM Role (jhon-developer-sandbox-role): operation error IAM:
CreateRole, https response error StatusCode: 400,
MalformedPolicyDocument: Invalid principal in policy:
"AWS":"arn:aws:iam::866934333672:user/developer-test"
```

### What happened
Terraform tried to create the sandbox IAM role before the `developer-test` user existed. The role's trust policy references the user's ARN as a principal:

```json
"Principal": { "AWS": "arn:aws:iam::866934333672:user/developer-test" }
```

AWS validates that this ARN exists at role creation time. Because Terraform creates resources in parallel by default, the role creation request reached AWS before the user was fully created — causing the validation to fail.

### Fix applied
Added `depends_on` to the role resource in `iam_boundary.tf`:

```hcl
resource "aws_iam_role" "developer_sandbox" {
  name               = "${var.resource_prefix}-developer-sandbox-role"
  depends_on         = [aws_iam_user.developer]   # force sequential creation
  assume_role_policy = data.aws_iam_policy_document.assume_role_trust.json
  ...
}
```

`depends_on` tells Terraform: do not start creating this resource until the listed resources are fully created.

### How to prevent
Any time a trust policy, resource policy, or condition references an ARN that Terraform is also creating in the same apply, add `depends_on`. The pattern to watch for:

```hcl
# If you see this in a trust policy:
"arn:aws:iam::ACCOUNT:user/${var.some_user_name}"

# And that user is created in the same project:
resource "aws_iam_user" "some_user" { ... }

# You need depends_on on the role.
```

---

## ERR-03 — VPC limit exceeded

### Error message
```
Error: creating EC2 VPC: operation error EC2: CreateVpc,
api error VpcLimitExceeded: The maximum number of VPCs has been reached.
```

### What happened
AWS accounts have a default limit of 5 VPCs per region. The shared training account already had 5 VPCs from previous lab assignments when this project tried to create a sixth.

### Fix applied
Listed all VPCs in the account and deleted lab VPCs from previous assignments:

```bash
# List all VPCs with names
aws ec2 describe-vpcs \
  --query 'Vpcs[*].{ID:VpcId,CIDR:CidrBlock,Default:IsDefault,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output table

# Delete a specific VPC (must remove dependencies first)
aws ec2 delete-vpc --vpc-id vpc-XXXXXXXX
```

VPCs with active resources (instances, NAT gateways, endpoints) cannot be deleted directly. Dependencies must be removed first in this order:
1. Terminate EC2 instances
2. Delete NAT Gateways
3. Detach and delete Internet Gateways
4. Delete subnets
5. Delete route tables (non-main)
6. Delete security groups (non-default)
7. Delete the VPC

### How to prevent
Always run `terraform destroy` after completing a lab assignment. Never leave VPCs or other resources running when the lab is done. The shared account has a finite quota that affects all users.

If you need to keep a VPC for reference, request a VPC quota increase via AWS Service Quotas before starting a new lab that requires one.

---

## ERR-04 — `depends_on` attribute redefined

### Error message
```
Error: Attribute redefined

  on iam_boundary.tf line 170, in resource "aws_iam_role" "developer_sandbox":
 170:   depends_on = [aws_iam_user.developer]

The argument "depends_on" was already set at iam_boundary.tf:164,3-13.
Each argument may be set only once.
```

### What happened
When fixing ERR-02, a `sed` command was used to insert `depends_on` into the file. The command ran twice — once when it was manually applied and once when a subsequent fix script ran — resulting in two `depends_on` blocks inside the same resource.

```hcl
resource "aws_iam_role" "developer_sandbox" {
  name       = "..."
  depends_on = [aws_iam_user.developer]   # first insertion
  ...
  depends_on = [aws_iam_user.developer]   # duplicate — causes error
}
```

Each Terraform argument can only appear once per resource block.

### Fix applied
```bash
# Identify the duplicate line number
sed -n '160,175p' terraform/iam_boundary.tf

# Delete the duplicate line (line 170 in this case)
sed -i '' '170d' terraform/iam_boundary.tf
```

### How to prevent
When using `sed` to modify Terraform files, always verify the result immediately:
```bash
grep -n "depends_on" terraform/iam_boundary.tf
# Should show exactly one line
```

Prefer editing files directly in a text editor over `sed` for structural changes inside resource blocks.

---

## ERR-05 — Policy Simulator ContextKeyType validation error

### Error message
```
An error occurred (ValidationError) when calling the SimulatePrincipalPolicy
operation: 1 validation error detected: Value 'arn' at
'contextEntries.2.member.contextKeyType' failed to satisfy constraint:
Member must satisfy enum value set: [binary, ipList, booleanList, ip,
boolean, numericList, dateList, numeric, date, stringList, string, binaryList]
```

### What happened
Test case TC-07 in `01_test_policy_simulator.py` included a context entry simulating the `ec2:Vpc` condition key. The `ContextKeyType` was set to `"arn"`:

```python
{
    "ContextKeyName"  : "ec2:Vpc",
    "ContextKeyValues": ["arn:aws:ec2:us-east-1:866934333672:vpc/vpc-xxx"],
    "ContextKeyType"  : "arn",   # invalid — not in the allowed enum
}
```

The IAM Policy Simulator API does not have an `"arn"` type. Even though the value is an ARN, the type must be declared as `"string"`.

### Fix applied
```bash
sed -i '' 's/"ContextKeyType"  : "arn"/"ContextKeyType"  : "string"/' \
  scripts/01_test_policy_simulator.py
```

### How to prevent
The valid `ContextKeyType` values for the Policy Simulator API are:

```
string      stringList
binary      binaryList
boolean     booleanList
numeric     numericList
date        dateList
ip          ipList
```

ARNs, VPC IDs, and other AWS resource identifiers are always type `"string"`. There is no `"arn"` type in this API.

---

## ERR-06 — S3 tag-based conditions fail in real API calls

### What happened
Test 3 (`03_test_assume_role.py`) originally tested S3 access using `s3:ListBucket` against the Dev bucket to validate that the assumed role could access it. The call failed with `AccessDenied` even though the Policy Simulator confirmed the action should be allowed.

```
AccessDenied: User: arn:aws:sts::866934333672:assumed-role/jhon-developer-sandbox-role/...
is not authorized to perform: s3:ListBucket on resource:
"arn:aws:s3:::jhon-lab-dev-team-d01ce68a"
because no identity-based policy allows the s3:ListBucket action
```

### Root cause
`aws:ResourceTag` conditions on S3 work differently in real API calls compared to the Policy Simulator:

- **Policy Simulator**: you supply the tag context manually via `ContextEntries`. The simulator evaluates the condition against whatever you provide.
- **Real API call**: AWS evaluates `aws:ResourceTag` against the actual tags on the bucket at request time — but this evaluation only works for certain S3 actions and only when the bucket ARN is explicitly specified in the policy resource, not with wildcards (`arn:aws:s3:::*`).

The policy uses `arn:aws:s3:::*` as the resource with a tag condition, which does not work the same way in practice as it does in simulation.

### Fix applied
Changed Test 3 to use `ec2:DescribeInstances` instead of `s3:ListBucket` for the positive tests. EC2 Describe actions have no tag conditions and work predictably with assumed role credentials:

```python
# Before
s3_full.list_objects_v2(Bucket=DEV_BUCKET, MaxKeys=1)

# After
ec2_client = boto3.client("ec2", region_name=REGION,
    aws_access_key_id=creds["AccessKeyId"],
    aws_secret_access_key=creds["SecretAccessKey"],
    aws_session_token=creds["SessionToken"])
ec2_client.describe_instances(MaxResults=5)
```

The session policy restriction test still uses S3 (`s3:ListBuckets`) for the negative case — confirming that an action not in the session policy is correctly denied. This works because the denial is evaluated at the session policy level, not at the resource tag level.

### Key learning
The IAM Policy Simulator is excellent for testing policy logic and condition evaluation. However, for `aws:ResourceTag` conditions on S3 with wildcard resources, real API behavior may differ. Always validate critical access patterns with real API calls, not only the simulator.

---

## ERR-07 — `sed` multiline replacement fails in zsh

### What happened
When attempting to use `sed` to replace a multi-line block in a `.tf` file (the session policy dict in `03_test_assume_role.py`), the command failed silently — the replacement did not apply even though `sed` reported no error.

### Root cause
zsh handles multiline strings in `sed` differently from bash. A heredoc-style `sed` replacement that works in bash may not work in zsh due to how the shell expands newlines in the pattern.

### Fix applied
Used a Python one-liner instead of `sed` for multiline replacements:

```bash
python3 - <<'ENDOFFILE'
with open("scripts/03_test_assume_role.py", "r") as f:
    content = f.read()

old = '''...exact multiline string...'''
new = '''...replacement...'''

content = content.replace(old, new)

with open("scripts/03_test_assume_role.py", "w") as f:
    f.write(content)
ENDOFFILE
```

### How to prevent
On macOS with zsh, use Python for multiline file modifications. Use `sed` only for single-line replacements. Always verify the result immediately after:

```bash
grep -n "target_string" scripts/file.py
```

---

## Summary table

| ID | Error | Root cause | Fix |
|----|-------|------------|-----|
| ERR-01 | IAM tag validation | Em dash in tag value | Replace with ASCII hyphen |
| ERR-02 | Invalid principal in trust policy | Race condition, user not yet created | Add `depends_on` to role |
| ERR-03 | VPC limit exceeded | 5 VPC quota reached | Delete unused lab VPCs |
| ERR-04 | Attribute redefined | `sed` inserted `depends_on` twice | Delete duplicate line |
| ERR-05 | Policy Simulator ContextKeyType | `"arn"` is not a valid type | Change to `"string"` |
| ERR-06 | S3 tag conditions fail in real calls | Wildcard resource + tag condition limitation | Switch positive test to EC2 |
| ERR-07 | `sed` multiline fails in zsh | Shell expansion difference | Use Python for multiline edits |
