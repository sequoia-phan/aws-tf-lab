# EC2 Instance
resource "aws_instance" "lab" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.ssm.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name
  associate_public_ip_address = true

  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  depends_on = [
    aws_route_table_association.public,
    # aws_vpc_security_group_egress_rule.https,
    aws_iam_role_policy_attachment.ssm
  ]

  tags = {
    Name = "lab-ec2-ssm"
  }
}

output "instance_id" {
  value = aws_instance.lab.id
}

