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

### Resources

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

## Remote state (S3)

> **Status: in progress.** The lab currently uses local state (see Notes). This section documents the target setup and the migration procedure.

### Why

Local state lives on one laptop, can be lost, and offers no protection against two people running `apply` at once. An S3 backend gives:

- **Durability and history** – bucket versioning keeps every previous state, so a bad apply can be rolled back.
- **Locking** – native S3 locking (`use_lockfile = true`, Terraform >= 1.10) writes a `.tflock` object next to the state, so concurrent runs fail instead of corrupting state. No DynamoDB table is needed.
- **Security** – state can contain sensitive values, so the bucket is encrypted and blocks all public access.

### Design

| Item | Choice |
|------|--------|
| Bucket | `<unique-name>-tfstate` in `us-east-1` (bucket names are global, so pick a unique one) |
| State key | `aws-terraform-lab/terraform.tfstate` |
| Versioning | Enabled |
| Encryption | SSE-S3 (AES256); SSE-KMS if key-level access control is needed |
| Public access | All four block-public-access settings on |
| Locking | `use_lockfile = true` |
| Tags | Same `Project` / `Lab` tags as the rest of the lab |

The bucket is created **outside** this configuration (chicken-and-egg: Terraform cannot store its state in a bucket that its own state has not created yet). It is a one-time bootstrap and is not destroyed with the lab.

### 1. Bootstrap the bucket (one time, AWS CLI)

```sh
BUCKET=<unique-name>-tfstate
REGION=us-east-1

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
# For any region other than us-east-1 add:
#   --create-bucket-configuration LocationConstraint="$REGION"

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### 2. Configure the backend

Create `backend.tf` (commit it; it contains no secrets):

```hcl
terraform {
  backend "s3" {
    bucket       = "<unique-name>-tfstate"
    key          = "aws-terraform-lab/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

### 3. Migrate the existing local state

```sh
terraform init -migrate-state   # answer "yes" to copy local state to S3
terraform plan                  # must show "No changes"
```

If `plan` shows changes after migration, stop and investigate before applying anything. Once it is clean, keep the local `terraform.tfstate*` files until you have confirmed the object exists in S3, then delete them:

```sh
aws s3 ls "s3://$BUCKET/aws-terraform-lab/"
```

### IAM permissions needed

The identity running Terraform needs, on the state bucket and key prefix:

- `s3:ListBucket` on `arn:aws:s3:::<bucket>`
- `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` on `arn:aws:s3:::<bucket>/aws-terraform-lab/*` (`DeleteObject` is required to release the lock file)

### Operational notes

- **Stuck lock** (a run was interrupted): `terraform force-unlock <LOCK_ID>`. Only do this when you are sure no other run is active.
- **Recovering an old state:** list versions with `aws s3api list-object-versions --bucket "$BUCKET" --prefix aws-terraform-lab/`, then copy the wanted version back as the current object.
- **Cost:** a few KB of state is effectively free; versioning only adds storage for old versions. Consider a lifecycle rule to expire non-current versions after 90 days.
- **Teardown:** `terraform destroy` removes the lab but not the state bucket. Delete the bucket manually (empty all versions first) only when you are done with the lab permanently.

## TLS for the load balancer (HTTPS)

> **Status: in progress.** The ALB currently serves plain HTTP on port 80 only (see Notes). This section documents the target setup and how to verify it.

### Why

Without TLS, traffic between clients and the ALB is readable and modifiable on the network, and browsers flag the site as insecure. The goal is HTTPS on 443 with a managed certificate, and port 80 reduced to a redirect.

### Design

| Item | Choice |
|------|--------|
| TLS termination | At the ALB. Traffic ALB → EC2 stays HTTP:80 inside the VPC and is restricted to the ALB security group, so the instance needs no certificate |
| Listeners | `HTTPS:443` forwards to the existing target group. `HTTP:80` returns a `301` redirect to HTTPS |
| Certificate | ACM public certificate, DNS-validated, auto-renewed (see options below) |
| TLS policy | `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.3 and 1.2 only) |
| Security group | `lab-alb-sg` gains inbound TCP 443 from `0.0.0.0/0`. The existing inbound 80 stays so the redirect works. Egress to the EC2 SG on 80 is unchanged |

### Certificate options

ACM cannot issue a public certificate for the default `*.elb.amazonaws.com` name, so a certificate needs a name you control.

| Option | When to use | Trade-offs |
|--------|-------------|------------|
| **A. ACM certificate for your own domain** (recommended) | You own a domain (or a subdomain such as `lab.example.com`) | Free, trusted by browsers, renews automatically. Needs one DNS CNAME for validation and a CNAME/alias from your name to the ALB |
| **B. Self-signed certificate imported into ACM** | Lab only, no domain | No cost and no domain, but browsers show a warning, clients need `curl -k`, and there is no auto-renewal |

### Terraform changes (option A)

Add a variable for the name (`variables.tf`):

```hcl
variable "domain_name" {
  description = "FQDN that will point to the ALB, e.g. lab.example.com"
  type        = string
}
```

Request and validate the certificate (e.g. in a new `acm.tf`):

```hcl
resource "aws_acm_certificate" "lab" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# If the zone is hosted in Route 53, create the validation records automatically.
# Otherwise add the CNAME shown in the ACM console at your DNS provider and
# drop the `validation_record_fqdns` argument below.
data "aws_route53_zone" "lab" {
  name = "example.com"
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.lab.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.lab.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "lab" {
  certificate_arn         = aws_acm_certificate.lab.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}
```

Open port 443 on the ALB security group (`security_groups.tf` / `alb.tf`):

```hcl
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  description = "Allow public HTTPS access to ALB"
}
```

Add the HTTPS listener and turn the existing HTTP listener into a redirect (`alb.tf`):

```hcl
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.lab.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.lab.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lab.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.lab.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}
```

Finally point the name at the ALB, either with a Route 53 alias record or a CNAME to `alb_dns_name` at your DNS provider.

### Terraform changes (option B, self-signed, lab only)

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 90 \
  -keyout lab.key -out lab.crt -subj "/CN=lab.local"

aws acm import-certificate \
  --certificate fileb://lab.crt \
  --private-key fileb://lab.key \
  --region us-east-1
```

Use the returned ARN as `certificate_arn` in the `aws_lb_listener.https` resource (instead of the `aws_acm_certificate_validation` reference) and skip the `acm.tf` block entirely. Never commit `lab.key`. Add `*.key` and `*.crt` to `.gitignore` first.

### Apply and verify

```sh
terraform plan     # review: new SG rule, HTTPS listener, changed HTTP listener, ACM resources
terraform apply
```

```sh
# 1. HTTP must redirect
curl -sI "http://<domain>" | head -n 3          # expect: HTTP/1.1 301 ... Location: https://<domain>:443/

# 2. HTTPS must answer with the target's response
curl -sI "https://<domain>" | head -n 1         # expect: HTTP/2 200 (option B: add -k)

# 3. Inspect the certificate and negotiated protocol
openssl s_client -connect <domain>:443 -servername <domain> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# 4. Old protocols must be rejected
curl -sI --tlsv1.1 --tls-max 1.1 "https://<domain>"   # expect: handshake failure
```

### Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Certificate stays `PENDING_VALIDATION` | The validation CNAME is missing or wrong in DNS. Compare it with `domain_validation_options` |
| Connection times out on 443 | `lab-alb-sg` has no inbound 443 rule |
| `503 Service Temporarily Unavailable` | No healthy targets. The instance has no web server yet (see Notes) or is in an AZ the ALB does not cover |
| Browser says name mismatch | You opened the ALB's `*.elb.amazonaws.com` name. Use the domain the certificate was issued for |
| `terraform apply` errors on the listener | The certificate is not yet `ISSUED`. Make sure the listener references `aws_acm_certificate_validation`, not the raw certificate |

### Operational notes

- **Renewal:** ACM renews DNS-validated certificates automatically as long as the validation CNAME stays in place. Do not delete it.
- **Cost:** ACM public certificates are free. The ALB bill is unchanged apart from a small increase in LCU usage for TLS connections.
- **Not covered yet:** HSTS (set it in the application), end-to-end TLS to the instance, WAF, and access logs to S3. These are sensible next steps.

## Notes

- **No web server is installed.** The instance has no `user_data`, so the target will report unhealthy until you install one (e.g. `sudo dnf install -y nginx && sudo systemctl enable --now nginx` from an SSM session).
- **Availability zones:** the ALB uses the `us-east-1b` and `us-east-1c` subnets, while the EC2 instance lives in the `10.0.1.0/24` subnet, which has no explicit AZ. Make sure it lands in an AZ the ALB covers, or the target will not receive traffic.
- **State** is currently local (`terraform.tfstate`) and git-ignored because it can contain sensitive values. See [Remote state (S3)](#remote-state-s3) for the move to an encrypted, versioned, locked S3 backend.
- `.terraform.lock.hcl` is committed to pin provider versions.
- This is a lab: the ALB is public and currently HTTP only. See [TLS for the load balancer](#tls-for-the-load-balancer-https) for the planned HTTPS setup.

## Repository layout

```
.
├── main.tf                # provider, default tags, AMI lookup
├── vpc.tf                 # VPC, subnets, IGW, route table
├── security_groups.tf     # ALB and instance security groups
├── alb.tf                 # load balancer, listener, target group
├── ec2.tf                 # EC2 instance
├── ima.tf                 # IAM role and instance profile
├── backend.tf             # S3 remote state (added when the migration is done)
├── .terraform.lock.hcl    # provider version lock (committed)
├── .gitignore
└── README.md
```
