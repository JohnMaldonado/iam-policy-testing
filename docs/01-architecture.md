# IAM Policy Testing & Validation — Architecture

## Overview

This project implements a layered IAM security model for a developer persona within AWS, demonstrating tag-based access control, instance type restrictions, VPC-scoped permissions, permission boundaries, SCPs, and IAM Access Analyzer.

---

## Architecture Diagram

```mermaid
flowchart TD
    subgraph OU[AWS Organizations OU]
        SCP[Service Control Policy\n Deny non us-east-1 or eu-west-1\n Deny CloudTrail deletion\n Deny LeaveOrganization]
    end

    subgraph Account[AWS Account 866934333672]
        subgraph Boundary[Permission Boundary ceiling]
            User[developer-test\n IAM User]
            Policy[Custom Developer Policy\n S3 read if Team=Dev\n EC2 t2.micro or t3.micro\n EC2 only in lab VPC\n Deny Environment=production]
            User -- has attached --> Policy
        end

        Role[sandbox-role\n IAM Role]
        User -- can assume --> Role

        subgraph VPC[Lab VPC 10.99.0.0/16]
            Subnet[Public Subnet\n 10.99.1.0/24]
            EC2[EC2 Instance\n t2.micro or t3.micro only]
            Subnet --> EC2
        end

        S3Dev[S3 Bucket\n Tag: Team=Dev\n Accessible to developer]
        S3Prod[S3 Bucket\n Tag: Environment=production\n Blocked by explicit Deny]

        Analyzer[IAM Access Analyzer\n Monitors for public resource exposure]
        Analyzer -. scans .-> S3Dev
        Analyzer -. scans .-> S3Prod
    end

    SCP -. caps account .-> Account
    Policy -- allows read --> S3Dev
    Policy -- explicit deny --> S3Prod
    Policy -- allows launch in --> VPC
```

---

## IAM Decision Flow

```
Request arrives
      │
      ▼
┌─────────────────────────────────────────────────┐
│  1. Is there an explicit DENY anywhere?          │
│     (SCP, Permission Boundary, Identity Policy)  │
│     YES → DENY (stops here, no appeal)           │
│     NO  → continue                               │
└─────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────┐
│  2. Does the SCP ALLOW this action in this       │
│     region?                                      │
│     NO  → DENY                                   │
│     YES → continue                               │
└─────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────┐
│  3. Does the Permission Boundary ALLOW this?     │
│     NO  → DENY                                   │
│     YES → continue                               │
└─────────────────────────────────────────────────┘
      │
      ▼
┌─────────────────────────────────────────────────┐
│  4. Does the Identity Policy ALLOW this?         │
│     NO  → IMPLICIT DENY                          │
│     YES → ALLOW                                  │
└─────────────────────────────────────────────────┘
```

---

## Policy Layers Explained

| Layer | Type | Scope | Can Override? |
|-------|------|-------|---------------|
| SCP | Organizations policy | Entire OU/account | No — root cannot bypass |
| Permission Boundary | IAM | Single user/role | Only by removing it |
| Identity Policy | IAM | Single user/role | Yes, by attaching more policies |
| Session Policy | STS inline | Single session | Never adds — only restricts |

---

## Test Cases

| ID | Action | Resource | Condition | Expected |
|----|--------|----------|-----------|----------|
| TC-01 | s3:ListAllMyBuckets | * | none | `allowed` |
| TC-02 | s3:DeleteObject | Dev bucket | Team=Dev | `explicitDeny` |
| TC-03 | ec2:RunInstances | instance/* | t2.micro | `allowed` |
| TC-04 | ec2:RunInstances | instance/* | t2.large | `implicitDeny` |
| TC-05 | s3:GetObject | Dev bucket | Team=Dev | `allowed` |
| TC-06 | s3:GetObject | Prod bucket | Environment=production | `explicitDeny` |
| TC-07 | ec2:RunInstances | instance/* | t2.large + VPC | `implicitDeny` |
| TC-08 | s3:DeleteBucket | Dev bucket | Team=Dev | `explicitDeny` |
