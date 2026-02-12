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
  default     = "us-west-2"
}

variable "name_prefix" {
  type    = string
  default = "opw"
}

variable "api_key" {
  type      = string
  sensitive = true
  # Example: set via terraform.tfvars or TF_VAR_api_key
  # default   = "dd_api_key_goes_here"
}

variable "pipeline_id" {
  type = string
  # Example:
  # default = "00000000-0000-0000-0000-000000000000"
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

# This should match the port that you pass in to op_env for your source
# (e.g. DD_OP_SOURCE_HTTP_SERVER_ADDRESS=8282) and the port your NLB listens on
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
  # Example:
  # default = "vpc-0123456789abcdef0"
}

variable "subnet_ids" {
  type = list(string)
  # Example:
  # default = [
  #   "subnet-0123456789abcdef0",
  #   "subnet-0123456789abcdef1",
  #   "subnet-0123456789abcdef2",
  # ]
}

variable "internal_nlb" {
  description = "Whether the NLB should be internal (private) or internet-facing."
  type        = bool
  default     = false
}

variable "instance_type" {
  type    = string
  default = "c6g.large"
}

variable "architecture" {
  description = "CPU architecture for instances. Use 'arm64' for Graviton instances (c6g, c7g, m6g, etc.) or 'amd64' for x86_64 instances (c5, c6i, m5, etc.)"
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "amd64"], var.architecture)
    error_message = "Architecture must be either 'arm64' or 'amd64'."
  }
}

# Increase this size to fit your disk buffering needs (if configured)
variable "ebs_size_gb" {
  description = "Size of the gp3 EBS volume attached to each instance (GB)."
  type    = number
  default = 20
}

variable "nlb_ingress_cidr" {
  description = "CIDR block that is allowed to access the NLB"
  type        = string
  default = "0.0.0.0"
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

variable "ssh_key_pair_name" {
  description = "Name of the EC2 key pair to attach to instances"
  type        = string
}

########################
# AMI mapping & user_data
########################

data "aws_region" "current" {}

# Rather than using a base OS AMI and needing to run a user-data script at boot
# to install OPW, we recommend a custom AMI that already has the
# observability-pipelines-worker package and its dependencies installed.
# This allows for a faster and more reliable boot time, which is important for autoscaling.
#
# Dynamic AMI lookup for Ubuntu 24.04 LTS (Noble Numbat) using AWS SSM Parameter Store.
# This automatically retrieves the latest Ubuntu 24.04 AMI ID for the current region
# based on the architecture variable (arm64 for Graviton, amd64 for x86_64).

data "aws_ssm_parameter" "ubuntu_24_04_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/${var.architecture}/hvm/ebs-gp3/ami-id"
}

locals {
  # Use the dynamically fetched Ubuntu 24.04 LTS AMI
  selected_ami = data.aws_ssm_parameter.ubuntu_24_04_ami.value

  # Graviton (ARM64) instance type prefixes
  graviton_prefixes = ["a1.", "c6g.", "c6gd.", "c6gn.", "c7g.", "c7gd.", "c7gn.", "m6g.", "m6gd.", "m7g.", "m7gd.", "r6g.", "r6gd.", "r7g.", "r7gd.", "t4g.", "x2gd."]

  # Check if instance type is Graviton-based
  is_graviton_instance = anytrue([for prefix in local.graviton_prefixes : startswith(var.instance_type, prefix)])

  # Validate architecture matches instance type
  architecture_matches = (var.architecture == "arm64" && local.is_graviton_instance) || (var.architecture == "amd64" && !local.is_graviton_instance)

  # Rather than using a base OS AMI and needing to run a user-data script at boot
  # to install OPW, we recommend a custom AMI that already has the
  # observability-pipelines-worker package and its dependencies installed.
  # This allows for a faster and more reliable boot time, which is important for autoscaling.
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
    sudo apt -y install xfsprogs

    # Decode OPWEnv: semicolons become newlines
    OPW_ENV_ENCODED='${replace(var.opw_env, "'", "'\"'\"'")}'
    OPW_ENV_DECODED="$(printf '%s' "$OPW_ENV_ENCODED" | tr ';' '\n')"

    # Write base config
    sudo tee /etc/default/observability-pipelines-worker >/dev/null <<EOT
    DD_OP_API_ENABLED=true
    DD_SITE=${var.datadog_site}
    DD_API_KEY=${var.api_key}
    DD_OP_PIPELINE_ID=${var.pipeline_id}
    DD_OP_API_ADDRESS=0.0.0.0:${var.op_api_port}
    EOT

    # Append decoded env lines (if any)
    if [ -n "$OPW_ENV_DECODED" ]; then
    printf '%s\n' "$OPW_ENV_DECODED" | sudo tee -a /etc/default/observability-pipelines-worker >/dev/null
    fi

    device=$(get_opw_ebs_drive)
    sudo mkfs.xfs "$${device}" || true
    sudo mkdir -p /var/lib/observability-pipelines-worker
    sudo mount -o rw "$${device}" /var/lib/observability-pipelines-worker || true
    sudo chown observability-pipelines-worker:observability-pipelines-worker /var/lib/observability-pipelines-worker || true

    sudo systemctl daemon-reload
    sudo systemctl enable --now observability-pipelines-worker
  EOF
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
    cidr_blocks = [var.nlb_ingress_cidr]
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

resource "aws_security_group_rule" "allow_nlb_to_instances_api" {
  type                     = "ingress"
  from_port                = var.op_api_port
  to_port                  = var.op_api_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.instance_sg.id
  source_security_group_id = aws_security_group.nlb_sg.id
  description              = "Allow NLB to reach instances on OP API / health-check port"
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
  key_name = var.ssh_key_pair_name

  iam_instance_profile {
    name = aws_iam_instance_profile.opw_profile.name
  }

  lifecycle {
    precondition {
      condition     = local.architecture_matches
      error_message = "Instance type '${var.instance_type}' does not match architecture '${var.architecture}'. Use arm64 for Graviton instances (c6g, c7g, m6g, etc.) or amd64 for x86_64 instances (c5, c6i, m5, etc.)."
    }
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
  internal           = var.internal_nlb
  subnets            = var.subnet_ids

  security_groups = [aws_security_group.nlb_sg.id]

  tags = { Name = "${var.name_prefix}-nlb" }
}

resource "aws_lb_target_group" "tg" {
  name        = "${var.name_prefix}-tg"
  port        = var.opw_port
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

  instance_refresh {
    strategy = "Rolling"
    triggers = ["launch_template"]
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
