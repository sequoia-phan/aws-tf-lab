# Security Group ssm
resource "aws_security_group" "ssm" {
  name        = "lab-ssm-sg"
  description = "SSM access via outbound HTTPS only"
  vpc_id      = aws_vpc.lab.id

  tags = {
    Name = "lab-ssm-sg"
  }
}

# Security Group alb
resource "aws_security_group" "alb" {
  name        = "lab-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = aws_vpc.lab.id

  tags = {
    Name = "lab-alb-sg"
  }
}
