# aws-terraform-lab

Terraform lab that deploys a small web tier on AWS (`us-east-1`): one EC2 instance reachable through an Application Load Balancer, with shell access via AWS Systems Manager (SSM) instead of SSH.

## Architecture

```
Internet ──HTTP:80──▶ ALB (lab-http-alb, subnets b + c)
                          │ HTTP:80
                          ▼
                   Target group (lab-http-tg)
                          │
                          ▼
                EC2 t3.micro (lab-ec2-ssm, public subnet)
                          │ HTTPS:443 outbound
                          ▼
                   SSM endpoints (Session Manager)
```

### Resources (all in `main.tf`)

| Area | Resources |
|------|-----------|
| Provider | `hashicorp/aws ~> 6.0`, region `us-east-1`, default tags `Project=aws-terraform-lab`, `Lab=ec2-ssm` |
| Network | VPC `10.0.0.0/16`; subnets `10.0.1.0/24` (public, EC2), `10.0.3.0/24` (us-east-1b), `10.0.4.0/24` (us-east-1c); internet gateway; public route table (`0.0.0.0/0` → IGW) and associations |
| Security groups | `lab-alb-sg`: inbound TCP 80 from `0.0.0.0/0`, outbound TCP 80 to the EC2 SG. `lab-ssm-sg`: inbound TCP 80 from the ALB SG only, outbound TCP 443 to `0.0.0.0/0` |
| Load balancing | Application Load Balancer, HTTP:80 listener, target group with `/` health check (expects 200), instance attachment |
| IAM | Role `lab-ec2-ssm-role` with `AmazonSSMManagedInstanceCore`, instance profile `lab-ec2-ssm-profile` |
| Compute | `t3.micro` Amazon Linux 2023 (AMI from the public SSM parameter), gp3 8 GB root volume, IMDSv2 required, standard CPU credits |

### Outputs

- `alb_dns_name` – public DNS name of the ALB
- `instance_id` – EC2 instance ID (use it for SSM sessions)

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.x
- AWS credentials configured (e.g. `aws configure` or `AWS_PROFILE`) with permissions for EC2, VPC, ELB, and IAM
- [AWS CLI](https://aws.amazon.com/cli/) + [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) to connect to the instance

## Usage

```sh
terraform init      # download providers
terraform plan      # preview changes
terraform apply     # create resources
```

Connect to the instance (no SSH key or open port 22 needed):

```sh
aws ssm start-session --target "$(terraform output -raw instance_id)" --region us-east-1
```

Test the load balancer (needs something listening on port 80 on the instance):

```sh
curl "http://$(terraform output -raw alb_dns_name)"
```

Tear everything down when finished to avoid charges (the ALB bills hourly):

```sh
terraform destroy
```

## Notes

- **No web server is installed.** The instance has no `user_data`, so the target will report unhealthy until you install one (e.g. `sudo dnf install -y nginx && sudo systemctl enable --now nginx` from an SSM session).
- **Availability zones:** the ALB uses the `us-east-1b` and `us-east-1c` subnets, while the EC2 instance lives in the `10.0.1.0/24` subnet, which has no explicit AZ. Make sure it lands in an AZ the ALB covers, or the target will not receive traffic.
- **State** is local (`terraform.tfstate`) and git-ignored because it can contain sensitive values. Use a remote backend (e.g. S3 + DynamoDB/lockfile) for anything shared.
- `.terraform.lock.hcl` is committed to pin provider versions.
- This is a lab: HTTP only, no TLS, public ALB.

## Repository layout

```
.
├── main.tf              # all infrastructure
├── .terraform.lock.hcl  # provider version lock (committed)
├── .gitignore
└── README.md
```
