# Getting Started

This guide is the entry point for anyone working with this repository for the first time.

---

## What this project does

This project deploys a layered IAM security model in AWS that answers a common real-world problem:

> How do you give a developer scoped AWS access without risking they break production, escalate their own privileges, or bypass controls?

The answer implemented here uses four independent layers — SCP, Permission Boundary, Identity Policy, and Session Policy — so that a misconfiguration in any single layer does not expose the account.

---

## What you need before starting

| Requirement | Version | Check |
|-------------|---------|-------|
| Terraform | >= 1.6.0 | `terraform --version` |
| AWS CLI | any recent | `aws --version` |
| Python | >= 3.10 | `python3 --version` |
| boto3 | any recent | `pip3 install boto3` |
| AWS credentials | admin IAM user | `aws sts get-caller-identity` |

Your AWS credentials must have admin-level permissions. The test scripts use a separate scoped user (`developer-test`) that Terraform creates.

---

## Quick start

```bash
# 1. Clone the repo
git clone https://github.com/JohnMaldonado/iam-policy-testing.git
cd iam-policy-testing

# 2. Deploy all infrastructure
cd terraform
terraform init
terraform apply -auto-approve

# 3. Export output values for the test scripts
export DEV_BUCKET=$(terraform output -raw dev_bucket_name)
export PROD_BUCKET=$(terraform output -raw production_bucket_name)
export LAB_VPC_ID=$(terraform output -raw lab_vpc_id)
export ANALYZER_ID=$(terraform output -raw access_analyzer_id)
export SANDBOX_ROLE_ARN=$(terraform output -raw sandbox_role_arn)
export ACCOUNT_ID=866934333672

# 4. Run the test suite
cd ..
python3 scripts/01_test_policy_simulator.py   # 8 policy tests
python3 scripts/02_test_access_analyzer.py    # public access check

# Test 3 requires the developer-test credentials
export AWS_ACCESS_KEY_ID=$(terraform -chdir=terraform output -raw developer_access_key_id)
export AWS_SECRET_ACCESS_KEY=$(terraform -chdir=terraform output -raw developer_secret_access_key)
python3 scripts/03_test_assume_role.py        # session policy demo

# 5. Destroy when done
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
cd terraform
terraform destroy -auto-approve
```

---

## Repository structure

```
iam-policy-testing/
├── terraform/               All infrastructure as code
│   ├── providers.tf         Terraform + AWS provider config
│   ├── variables.tf         Input variable declarations
│   ├── terraform.tfvars     Variable values (region, account ID, prefix)
│   ├── vpc.tf               Lab VPC and S3 test buckets
│   ├── iam_user.tf          developer-test user and credentials
│   ├── iam_policies.tf      Core developer policy (9 statements)
│   ├── iam_boundary.tf      Permission boundary + sandbox IAM role
│   ├── scp.tf               SCP policy document
│   ├── access_analyzer.tf   IAM Access Analyzer
│   └── outputs.tf           Exported ARNs, names, IDs
├── policies/
│   └── scp_policy.json      Generated SCP for manual Organizations application
├── scripts/
│   ├── 01_test_policy_simulator.py   Automated allow/deny validation (8 tests)
│   ├── 02_test_access_analyzer.py    Public access finding check
│   └── 03_test_assume_role.py        AssumeRole + session policy demo
└── docs/
    ├── 00-getting-started.md         This file
    ├── 01-architecture.md            Architecture diagram and decision flow
    ├── 02-infrastructure.md          Every resource explained + how to modify
    └── 03-code-reference.md          Scripts explained + how to extend
```

---

## Where to go next

| I want to... | Go to |
|--------------|-------|
| Understand the architecture and security layers | `docs/01-architecture.md` |
| Know what every Terraform resource does and how to change it | `docs/02-infrastructure.md` |
| Understand the Python scripts and extend the test suite | `docs/03-code-reference.md` |
| Change the allowed regions, instance types, or tags | `docs/02-infrastructure.md` → relevant resource section |
| Add a new test case to the Policy Simulator | `docs/03-code-reference.md` → `01_test_policy_simulator.py` |

---

## Common issues

**`VpcLimitExceeded` on apply**
Your account has reached the 5 VPC limit. Delete an unused VPC from a previous lab:
```bash
aws ec2 describe-vpcs --query 'Vpcs[*].{ID:VpcId,Name:Tags[?Key==`Name`]|[0].Value}' --output table
aws ec2 delete-vpc --vpc-id vpc-XXXXXXXX
```

**`MalformedPolicyDocument: Invalid principal` on IAM Role**
The `developer-test` user did not exist when Terraform tried to create the sandbox role. This is fixed by `depends_on = [aws_iam_user.developer]` in `iam_boundary.tf`. If you see this error, ensure you have the latest version of the file.

**`ValidationError` on IAM User tag**
IAM tags do not allow em dashes (`—`). Use a regular hyphen (`-`) in all tag values.

**Access Analyzer shows 76+ findings**
This is normal in a shared training account — other users' resources appear in the scan. The important check is that our two lab buckets (`jhon-lab-dev-team-*` and `jhon-lab-production-*`) show no findings. The script filters for this specifically.

**Test 3 fails with `AccessDenied` on S3**
`aws:ResourceTag` conditions on S3 are not evaluated the same way in real API calls as in the Policy Simulator. The test script uses `ec2:DescribeInstances` instead, which validates the session policy intersection correctly without relying on tag context.
