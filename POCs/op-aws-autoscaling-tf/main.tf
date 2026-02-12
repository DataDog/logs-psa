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

# Disk buffering allows OPW to buffer data to disk when downstream destinations
# are unavailable or slow, preventing data loss during outages.
#
# Datadog recommends a dedicated EBS volume for disk buffering to:
# - Isolate buffer I/O from the root volume
# - Prevent root volume from filling up during buffer growth
# - Allow independent sizing based on buffering requirements
#
# To calculate size needed: (expected throughput MB/s) × (max outage duration seconds)
# Example: 10 MB/s × 3600s (1 hour) = 36 GB recommended
#
# Documentation: https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/handling_load_and_backpressure/#destination-buffer-behavior
variable "ebs_size_gb" {
  description = "Size of the gp3 EBS volume for disk buffering (GB). Set to 0 to disable the extra volume if not using disk buffering."
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

# If your VPC subnets have a NAT gateway configured, instances can reach the internet
# without a public IP address. However, if your subnets do NOT have a NAT gateway,
# you must set this to true so instances can download packages and dependencies
# during the user data script execution.
variable "assign_public_ip" {
  description = "Whether to assign a public IP address to instances. Set to true if your VPC subnets do not have a NAT gateway."
  type        = bool
  default     = false
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
set -euxo pipefail

# Log everything to file and console for debugging
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "=========================================="
echo "Starting OPW user-data script"
echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo "=========================================="

# Wait for network connectivity before continuing
wait_for_network() {
  local tries=0
  while [ $tries -lt 12 ]; do
    # Test basic IP connectivity
    if ping -c1 -W1 8.8.8.8 >/dev/null 2>&1; then
      # Test HTTPS connectivity to Datadog
      if curl -sS --connect-timeout 5 --max-time 10 https://keys.datadoghq.com/ -I >/dev/null 2>&1; then
        echo "Network connectivity confirmed"
        return 0
      fi
    fi
    tries=$((tries + 1))
    echo "Network not ready, attempt $tries/12 - waiting 5s..."
    sleep 5
  done
  return 1
}

if ! wait_for_network; then
  echo "ERROR: Network unreachable after retries. Dumping diagnostics:" >&2
  ip -4 addr show || true
  ip route show || true
  echo "iptables rules:" >&2
  iptables -L -n || true
  echo "WARNING: Continuing anyway, but installation may fail" >&2
fi

# Install minimal required tools
echo "Installing base dependencies..."
apt-get update
apt-get install -y apt-transport-https curl gnupg xfsprogs

# Add Datadog apt key with retries
add_datadog_key() {
  local tries=0
  while [ $tries -lt 5 ]; do
    if curl -fsSL https://keys.datadoghq.com/DATADOG_APT_KEY_CURRENT.public -o /tmp/datadog-key.asc; then
      if gpg --dearmor < /tmp/datadog-key.asc > /usr/share/keyrings/datadog-archive-keyring.gpg; then
        chmod 644 /usr/share/keyrings/datadog-archive-keyring.gpg
        rm -f /tmp/datadog-key.asc
        echo "Datadog GPG key added successfully"
        return 0
      fi
    fi
    tries=$((tries + 1))
    echo "Failed to fetch/install Datadog key, attempt $tries/5 - waiting 5s..."
    sleep 5
  done
  return 1
}

if ! add_datadog_key; then
  echo "FATAL: Failed to install Datadog GPG key after retries" >&2
  exit 1
fi

# Add Datadog repository
cat > /etc/apt/sources.list.d/datadog-observability-pipelines-worker.list <<'EOX'
deb [signed-by=/usr/share/keyrings/datadog-archive-keyring.gpg] https://apt.datadoghq.com/ stable observability-pipelines-worker-2
EOX

# Install OPW with retries
echo "Installing Observability Pipelines Worker..."
install_success=false
for attempt in 1 2 3; do
  if apt-get update && apt-get install -y observability-pipelines-worker datadog-signing-keys; then
    install_success=true
    echo "OPW installed successfully"
    break
  fi
  echo "apt-get install failed, attempt $attempt/3 - waiting 5s..."
  sleep 5
done

if [ "$install_success" = false ]; then
  echo "FATAL: Failed to install OPW after 3 attempts" >&2
  exit 1
fi

# Configure OPW
echo "Writing OPW configuration..."
OPW_ENV_ENCODED='${replace(var.opw_env, "'", "'\"'\"'")}'
OPW_ENV_DECODED="$(printf '%s' "$OPW_ENV_ENCODED" | tr ';' '\n')"

cat > /etc/default/observability-pipelines-worker <<'EOT'
DD_OP_API_ENABLED=true
DD_SITE=${var.datadog_site}
DD_API_KEY=${var.api_key}
DD_OP_PIPELINE_ID=${var.pipeline_id}
DD_OP_API_ADDRESS=0.0.0.0:${var.op_api_port}
EOT

if [ -n "$OPW_ENV_DECODED" ]; then
  printf '%s\n' "$OPW_ENV_DECODED" >> /etc/default/observability-pipelines-worker
fi

# ==================================================================================
# Setup dedicated data disk for disk buffering
# ==================================================================================
#
# Disk buffering is a critical resiliency feature that prevents data loss when
# downstream destinations (Splunk, S3, etc.) are unavailable or experiencing issues.
#
# How it works:
# - OPW buffers incoming data to DD_OP_DATA_DIR (default: /var/lib/observability-pipelines-worker)
# - If destinations are down, data accumulates on disk instead of being dropped
# - When destinations recover, buffered data is automatically sent
#
# Why a dedicated volume:
# - Isolates buffer I/O from root volume (better performance)
# - Prevents root volume from filling up during long outages
# - Allows independent sizing based on throughput and expected outage duration
#
# Configuration:
# - Configure disk buffering in your OPW pipeline via DD_OP_* environment variables
# - Set buffer size limits to prevent unbounded growth
# - Optionally set DD_OP_DATA_DIR in opw_env to customize the data directory
#
# Documentation:
# - Disk buffering: https://docs.datadoghq.com/observability_pipelines/scaling_and_performance/handling_load_and_backpressure/#destination-buffer-behavior
# - Bootstrap options: https://docs.datadoghq.com/observability_pipelines/configuration/install_the_worker/advanced_worker_configurations/#bootstrap-options
#
# To remove this section: Also remove block_device_mappings from launch template
# ==================================================================================

echo "Setting up data disk for buffering..."
device="/dev/nvme1n1"

# Detect DD_OP_DATA_DIR from opw_env if set, otherwise use default
# This ensures we mount the disk at the correct location
data_dir="/var/lib/observability-pipelines-worker"
if [ -n "$OPW_ENV_DECODED" ]; then
  custom_data_dir=$(echo "$OPW_ENV_DECODED" | grep -E '^DD_OP_DATA_DIR=' | cut -d'=' -f2- | tr -d '[:space:]' || true)
  if [ -n "$custom_data_dir" ]; then
    data_dir="$custom_data_dir"
    echo "Detected custom DD_OP_DATA_DIR: $data_dir"
  fi
fi

if [ -b "$device" ]; then
  # Only format if the device is not already formatted (preserves data on instance refresh)
  if ! blkid "$device" >/dev/null 2>&1; then
    echo "Formatting $device with XFS..."
    mkfs.xfs "$device"
  else
    echo "Device $device already formatted, skipping mkfs"
  fi

  # Mount at the detected data directory
  mkdir -p "$data_dir"

  # Check if device is already mounted at the target location
  if mount | grep -q "^$device on $data_dir"; then
    echo "Device $device is already mounted at $data_dir"
  elif mount | grep -q "^$device "; then
    # Device is mounted but not at our target location
    current_mount=$(mount | grep "^$device " | awk '{print $3}')
    echo "WARNING: Device $device is already mounted at $current_mount, not $data_dir" >&2
    echo "This might cause issues. Consider unmounting or adjusting configuration." >&2
  elif mountpoint -q "$data_dir"; then
    # Directory is a mount point but not our device
    echo "WARNING: Mount point $data_dir is busy with a different device" >&2
  else
    # Safe to mount
    mount -o rw "$device" "$data_dir"
    echo "Mounted $device at $data_dir"
  fi

  # Add to fstab for automatic mounting after reboots
  if ! grep -q "$device" /etc/fstab; then
    echo "$device $data_dir xfs defaults 0 0" >> /etc/fstab
  fi

  chown -R observability-pipelines-worker:observability-pipelines-worker "$data_dir"
  echo "Data disk mounted successfully at $data_dir"
else
  echo "WARNING: Device $device not found - OPW will use root volume for buffering" >&2
  echo "This may cause root volume to fill up if buffering is enabled" >&2
fi

# Start and verify OPW service
echo "Starting Observability Pipelines Worker service..."
systemctl daemon-reload
systemctl enable observability-pipelines-worker
systemctl start observability-pipelines-worker

# Wait for service to start and verify
sleep 5
if systemctl is-active --quiet observability-pipelines-worker; then
  echo "SUCCESS: OPW service is running"
  journalctl -u observability-pipelines-worker -n 50 --no-pager
else
  echo "ERROR: OPW service failed to start" >&2
  systemctl status observability-pipelines-worker --no-pager || true
  journalctl -u observability-pipelines-worker -n 200 --no-pager || true
  exit 1
fi

echo "=========================================="
echo "User-data script completed successfully"
echo "Timestamp: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo "=========================================="
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
  key_name      = var.ssh_key_pair_name

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
    associate_public_ip_address = var.assign_public_ip
    security_groups             = [aws_security_group.instance_sg.id]
  }

  # Attach a dedicated EBS volume for disk buffering.
  #
  # Disk buffering is a key resiliency feature that allows OPW to buffer data to disk
  # when downstream destinations are slow or unavailable, preventing data loss.
  #
  # This dedicated volume:
  # - Gets mounted at /var/lib/observability-pipelines-worker by user_data
  # - Isolates buffer I/O from the root volume
  # - Prevents root volume from filling up during buffer growth
  # - Can be sized independently based on your buffering needs
  #
  # To disable: Set ebs_size_gb = 0 and remove the disk setup section from user_data
  # Documentation: https://docs.datadoghq.com/observability_pipelines/setup/
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
    version = aws_launch_template.opw.latest_version
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

  # When the launch template changes, trigger a rolling instance refresh
  # to gradually replace existing instances with new ones using the updated template
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 60
    }
  }

  # Force instance refresh when launch template version changes
  tag {
    key                 = "LaunchTemplateVersion"
    value               = aws_launch_template.opw.latest_version
    propagate_at_launch = false
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
