# Internet -> ALB : TCP 80
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"

  description = "Allow public HTTP access to ALB"
}

# ALB -> EC2 : TCP 80
resource "aws_vpc_security_group_egress_rule" "alb_to_ec2" {
  security_group_id = aws_security_group.alb.id

  referenced_security_group_id = aws_security_group.ssm.id

  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"

  description = "Allow HTTP traffic from ALB to EC2"
}

# EC2 <- ALB : TCP 80
resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  security_group_id = aws_security_group.ssm.id

  referenced_security_group_id = aws_security_group.alb.id

  from_port   = 80
  to_port     = 80
  ip_protocol = "tcp"

  description = "Allow HTTP traffic only from ALB"
}

# https egress rule for SSM
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.ssm.id

  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
  cidr_ipv4   = "0.0.0.0/0"
}

# alb target group
resource "aws_lb_target_group" "lab" {
  name        = "lab-http-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.lab.id

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "lab-http-tg"
  }
}

# alb target group attachment
resource "aws_lb_target_group_attachment" "lab" {
  target_group_arn = aws_lb_target_group.lab.arn
  target_id        = aws_instance.lab.id
  port             = 80
}

resource "aws_lb" "lab" {
  name               = "lab-http-alb"
  load_balancer_type = "application"
  internal           = false

  security_groups = [
    aws_security_group.alb.id
  ]

  subnets = [
    aws_subnet.public_b.id,
    aws_subnet.public_c.id
  ]

  tags = {
    Name = "lab-http-alb"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.lab.arn

  port     = 80
  protocol = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lab.arn
  }
}

output "alb_dns_name" {
  description = "Public DNS name of the ALB"
  value       = aws_lb.lab.dns_name
}
