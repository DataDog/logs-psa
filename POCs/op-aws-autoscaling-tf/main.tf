terraform {
  required_version = ">= 1.4.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

########################
# Variables
########################

variable "aws_region" {
  type = string
}

variable "name_prefix" {
  type    = string
  default = "opw"
}

variable "api_key" {
  type      = string
  sensitive = true
}

variable "pipeline_id" {
  type = string
}

variable "datadog_site" {
  type    = string
  default = "datadoghq.com"

  validation {
    condition     = contains(["datadoghq.com", "us3.datadoghq.com", "us5.datadoghq.com", "datadoghq.eu", "ap1.datadoghq.com"], var.datadog_site)
    error_message = "datadog_site must be one of the allowed values."
  }
}

# opw_env allows you to pass additional environment variables to the
# Observability Pipelines Worker.
#
# FORMAT:
# - Single string
# - Key/value pairs separated by semicolons (;)
# - Each entry must be KEY=VALUE
#
# At boot time, this string is transformed so that each semicolon (;) becomes
# a newline and is written into:
#   /etc/default/observability-pipelines-worker
#
# EXAMPLE:
#   opw_env = "DD_OP_SOURCE_HTTP_SERVER_ADDRESS=0.0.0.0:8686;DD_OP_DESTINATION_SPLUNK_HEC_TOKEN=abc123;DD_OP_DESTINATION_SPLUNK_HEC_ENDPOINT_URL=https://splunk.example.com:8088"
#
# RESULTS IN /etc/default/observability-pipelines-worker:
#   DD_OP_SOURCE_HTTP_SERVER_ADDRESS=0.0.0.0:8686
#   DD_OP_DESTINATION_SPLUNK_HEC_TOKEN=abc123
#   DD_OP_DESTINATION_SPLUNK_HEC_ENDPOINT_URL=https://splunk.example.com:8088
#
# NOTES:
# - Do NOT include trailing semicolons
# - Values may include numbers or strings
# - This variable is marked sensitive to avoid leaking secrets in plans
variable "opw_env" {
  type      = string
  sensitive = true
  default   = ""
}

variable "opw_port" {
  type    = number
  default = 8282
}

variable "op_api_port" {
  type    = number
  default = 8686
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "instance_type" {
  type    = string
  default = "c6g.large"
}

variable "ebs_size_gb" {
  type    = number
  default = 288
}

variable "asg_min_size" {
  type    = number
  default = 2
}

variable "asg_max_size" {
  type    = number
  default = 10
}

variable "asg_capacity" {
  type    = number
  default = 2
}

########################
# AMI mapping & user_data
########################

data "aws_region" "current" {}

locals {
  aws_region_to_ami = {
    "af-south-1"     = "ami-0d39ef5932bf23109"
    "ap-east-1"      = "ami-021c24082c69e2867"
    "ap-northeast-1" = "ami-02b8b87a5bfed4c7a"
    "ap-northeast-2" = "ami-0ee413af3d419b913"
    "ap-northeast-3" = "ami-0707b5724f3d370a1"
    "ap-south-1"     = "ami-0041facac80f93bbe"
    "ap-south-2"     = "ami-0544ba2d7ff852b4c"
    "ap-southeast-1" = "ami-084594bed915f5e8f"
    "ap-southeast-2" = "ami-07bf7b6acb5db5e13"
    "ap-southeast-3" = "ami-07f185c39796fd830"
    "ap-southeast-4" = "ami-0ce7ff6086582795a"
    "ap-southeast-5" = "ami-0768220bae79b4901"
    "ap-southeast-7" = "ami-0e4a91f0466e0c675"
    "ca-central-1"   = "ami-0d1bde699564f5a7a"
    "ca-west-1"      = "ami-0c62ba0d6cc805ca7"
    "eu-central-1"   = "ami-0bc586dd8476ba5b1"
    "eu-central-2"   = "ami-00f504206d607395a"
    "eu-north-1"     = "ami-008e58f8f6505bf76"
    "eu-south-1"     = "ami-0be337e76511c7b7b"
    "eu-south-2"     = "ami-0d777f40ee93f0622"
    "eu-west-1"      = "ami-04434961757c31b63"
    "eu-west-2"      = "ami-02c510094a29f0052"
    "eu-west-3"      = "ami-0bbeecfe5196eab29"
    "il-central-1"   = "ami-0a91f8186ca9ab853"
    "me-central-1"   = "ami-079335fbdd6702aa0"
    "me-south-1"     = "ami-0bb7bf7951ae5ff2c"
    "mx-central-1"   = "ami-09a423ffd5b0cbaaa"
    "sa-east-1"      = "ami-080924daa71cbdad8"
    "us-east-1"      = "ami-06daf9c2d2cf1cb37"
    "us-east-2"      = "ami-0edd45507c30e47d4"
    "us-west-1"      = "ami-01557579a54cccc40"
    "us-west-2"      = "ami-057a2512faa740640"
  }

  selected_ami = try(local.aws_region_to_ami[data.aws_region.current.name], null)

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    get_opw_ebs_drive() {
      echo "/dev/nvme1n1"
    }

    sudo apt -y update
    sudo apt -y install apt-transport-https curl gnupg

    sudo sh -c "echo 'deb [signed-by=/usr/share/keyrings/datadog-archive-keyring.gpg] https://apt.datadoghq.com/ stable observability-pipelines-worker-2' > /etc/apt/sources.list.d/datadog-observability-pipelines-worker.list"
    sudo touch /usr/share/keyrings/datadog-archive-keyring.gpg
    sudo chmod a+r /usr/share/keyrings/datadog-archive-keyring.gpg

    curl https://keys.datadoghq.com/DATADOG_APT_KEY_CURRENT.public | sudo gpg --no-default-keyring --keyring /usr/share/keyrings/datadog-archive-keyring.gpg --import --batch
    curl https://keys.datadoghq.com/DATADOG_APT_KEY_C0962C7D.public   | sudo gpg --no-default-keyring --keyring /usr/share/keyrings/datadog-archive-keyring.gpg --import --batch
    curl https://keys.datadoghq.com/DATADOG_APT_KEY_F14F620E.public   | sudo gpg --no-default-keyring --keyring /usr/share/keyrings/datadog-archive-keyring.gpg --import --batch

    sudo apt -y update
    sudo apt -y install observability-pipelines-worker datadog-signing-keys

    OPW_ENV_ENCODED='${replace(var.opw_env, "'", "'\"'\"'")}'
    OPW_ENV_DECODED="$${OPW_ENV_ENCODED//;/$'\\n'}"

    sudo tee /etc/default/observability-pipelines-worker >/dev/null <<EOT
    DD_OP_API_ENABLED=true
    DD_SITE=${var.datadog_site}
    DD_API_KEY=${var.api_key}
    DD_OP_PIPELINE_ID=${var.pipeline_id}
    DD_OP_API_ADDRESS=0.0.0.0:${var.op_api_port}
    $${OPW_ENV_DECODED}
    EOT

    device=$$(get_opw_ebs_drive)
    sudo mkfs.xfs "$${device}" || true
    sudo mkdir -p /var/lib/observability-pipelines-worker
    sudo mount -o rw "$${device}" /var/lib/observability-pipelines-worker || true
    sudo chown observability-pipelines-worker:observability-pipelines-worker /var/lib/observability-pipelines-worker || true

    sudo systemctl restart observability-pipelines-worker
  EOF
}

resource "null_resource" "validate_region" {
  triggers = {
    region = data.aws_region.current.name
    ami    = local.selected_ami == null ? "UNSUPPORTED" : local.selected_ami
  }

  lifecycle {
    precondition {
      condition     = local.selected_ami != null
      error_message = "Region ${data.aws_region.current.name} is not present in the AMI mapping. Add it to local.aws_region_to_ami."
    }
  }
}

########################
# Security Groups
########################

resource "aws_security_group" "instance_sg" {
  name        = "${var.name_prefix}-instance-sg"
  description = "Instance SG for OPW backend"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-instance-sg" }
}

resource "aws_security_group" "nlb_sg" {
  name        = "${var.name_prefix}-nlb-sg"
  description = "Security group to attach to the NLB frontend"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = var.opw_port
    to_port     = var.opw_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow client access to NLB on OPW input port (adjust as needed)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-nlb-sg" }
}

resource "aws_security_group_rule" "allow_nlb_to_instances" {
  type                     = "ingress"
  from_port                = var.opw_port
  to_port                  = var.opw_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.instance_sg.id
  source_security_group_id = aws_security_group.nlb_sg.id
  description              = "Allow traffic from NLB to instances on OPW port"
}

########################
# IAM Role / Instance Profile
########################

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "opw_role" {
  name               = "${var.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.opw_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "opw_profile" {
  name = "${var.name_prefix}-instance-profile"
  role = aws_iam_role.opw_role.name
}

########################
# Launch Template
########################

resource "aws_launch_template" "opw" {
  name_prefix   = "${var.name_prefix}-lt-"
  image_id      = local.selected_ami
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.opw_profile.name
  }

  network_interfaces {
    device_index                = 0
    associate_public_ip_address = false
    security_groups             = [aws_security_group.instance_sg.id]
  }

  block_device_mappings {
    device_name = "/dev/sdf"
    ebs {
      volume_size           = var.ebs_size_gb
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  user_data = base64encode(local.user_data)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-instance"
    }
  }
}

########################
# Network Load Balancer (with security group) + TG + Listener
########################

resource "aws_lb" "nlb" {
  name               = "${var.name_prefix}-nlb"
  load_balancer_type = "network"
  internal           = true
  subnets            = var.subnet_ids

  security_groups = [aws_security_group.nlb_sg.id]

  tags = { Name = "${var.name_prefix}-nlb" }
}

resource "aws_lb_target_group" "tg" {
  name        = "${var.name_prefix}-tg"
  port        = var.op_api_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    protocol            = "TCP"
    port                = tostring(var.op_api_port)
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
    timeout             = 5
  }

  tags = { Name = "${var.name_prefix}-tg" }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = var.opw_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

########################
# Auto Scaling Group
########################

resource "aws_autoscaling_group" "asg" {
  name                = "${var.name_prefix}-asg"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  desired_capacity    = var.asg_capacity
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.opw.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.tg.arn]

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-instance"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

########################
# Autoscaling Target Tracking (CPU 60%)
########################

resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "${var.name_prefix}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60.0
  }
}

########################
# Outputs
########################

output "load_balancer_dns" {
  description = "DNS name for the internal NLB."
  value       = aws_lb.nlb.dns_name
}

output "instance_profile" {
  description = "Instance profile name."
  value       = aws_iam_instance_profile.opw_profile.name
}
