########################
# Required variables
########################

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "api_key" {
  description = "Datadog API key used by the Observability Pipelines Worker."
  type        = string
  sensitive   = true
  # Example: set via terraform.tfvars or TF_VAR_api_key
  # default   = "dd_api_key_goes_here"
}

variable "pipeline_id" {
  description = "Datadog Observability Pipelines pipeline ID."
  type        = string
  # Example:
  # default = "00000000-0000-0000-0000-000000000000"
}

variable "vpc_id" {
  description = "VPC ID where the worker instances and load balancer will be deployed."
  type        = string
  # Example:
  # default = "vpc-0123456789abcdef0"
}

variable "subnet_ids" {
  description = "List of private subnet IDs for the Auto Scaling Group and NLB."
  type        = list(string)
  # Example:
  # default = [
  #   "subnet-0123456789abcdef0",
  #   "subnet-0123456789abcdef1",
  #   "subnet-0123456789abcdef2",
  # ]
}

########################
# Optional / tunable variables
########################

variable "name_prefix" {
  description = "Prefix applied to all resource names."
  type        = string
  default     = "opw"
}

variable "datadog_site" {
  description = "Datadog site to send data to."
  type        = string
  default     = "datadoghq.com"
}

variable "instance_type" {
  description = "EC2 instance type for OPW workers (ARM recommended)."
  type        = string
  default     = "c6g.large"
}

variable "ebs_size_gb" {
  description = "Size of the gp3 EBS volume attached to each instance (GB)."
  type        = number
  default     = 20
}

variable "opw_port" {
  description = "TCP port the Observability Pipelines Worker listens on for incoming data."
  type        = number
  default     = 8282
}

variable "op_api_port" {
  description = "Port used for the OP API and NLB TCP health checks."
  type        = number
  default     = 8686
}

variable "asg_min_size" {
  description = "Minimum number of instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of instances in the Auto Scaling Group."
  type        = number
  default     = 10
}

variable "asg_capacity" {
  description = "Desired number of instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

########################
# Extra environment variables
########################

# opw_env allows you to pass additional environment variables to the
# Observability Pipelines Worker.
#
# FORMAT:
# - Single string
# - Key/value pairs separated by semicolons (;)
# - Each entry must be KEY=VALUE
#
# EXAMPLE:
#   opw_env = "DD_LOG_LEVEL=debug;VECTOR_LOG=info;MY_CUSTOM_FLAG=true"
#
# This will be expanded into newline-separated entries in:
#   /etc/default/observability-pipelines-worker
variable "opw_env" {
  type      = string
  sensitive = true
  default   = ""
}
