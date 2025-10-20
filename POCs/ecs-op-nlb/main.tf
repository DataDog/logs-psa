terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

variable "aws_vpc" {
  type    = string
  default = "vpc-0c1c86691d6752f1e"
}

variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "fargate_cpu" {
  type    = number
  default = 1024
}

variable "fargate_memory" {
  type    = number
  default = 2048
}

data "aws_subnets" "all" {
  filter {
    name   = "vpc-id"
    values = [var.aws_vpc]
  }
}

# Security Groups
resource "aws_security_group" "nlb" {
  name        = "datadog-test-app-nlb"
  description = "Security group for NLB"
  vpc_id      = var.aws_vpc

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["216.243.40.162/32", "34.111.173.86/32"]
    security_groups = [aws_security_group.ecs_tasks_nlb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "datadog-test-ecs-tasks"
  description = "Allow inbound traffic from NLB"
  vpc_id      = var.aws_vpc

  ingress {
    from_port       = 9997
    to_port         = 9997
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  # Required for healthcheck to pass
  ingress {
    from_port       = 8181
    to_port         = 8181
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# second sg to attach to the tasks and provide an id to the NLB
resource "aws_security_group" "ecs_tasks_nlb" {
  name        = "datadog-test-ecs-tasks-nlb"
  description = "Allow traffic to NLB"
  vpc_id      = var.aws_vpc

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# NLB
resource "aws_lb" "main" {
  name               = "datadog-test-app-nlb"
  internal           = false
  load_balancer_type = "network"
  security_groups    = [aws_security_group.nlb.id]
  subnets            = data.aws_subnets.all.ids

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "opworker" {
  name        = "datadog-op-worker-tg"
  port        = 9997
  protocol    = "TCP"
  vpc_id      = var.aws_vpc
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = "3"
    interval            = "30"
    matcher             = "200"
    path                = "/health"
    port                = "8181"
    protocol            = "HTTP"
    timeout             = "5"
    unhealthy_threshold = "2"
  }
}

resource "aws_lb_listener" "opworker" {
  load_balancer_arn = aws_lb.main.arn
  port              = "9997"
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.opworker.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "khax-test-ecs-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = "datadog-op-worker-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  execution_role_arn       = "arn:aws:iam::439537465448:role/ecsTaskExecutionRole"
  tags                     = {}

  container_definitions = jsonencode([
    #DataDog Observability Pipelines Worker
    {
      name: "dd-observability-pipelines-worker",
      image: "public.ecr.aws/datadog/observability-pipelines-worker:latest",
      #cpu: 50,
      memory: 512,
      essential: true,
      command: ["run"],
      mountPoints: [],
      systemControls: [],
      volumesFrom: [],
      portMappings: [
        {
          containerPort: 9997,
          hostPort: 9997,
          protocol: "tcp"
        }
      ],
      environment = [
        { name = "DD_OP_API_ENABLED", value = "true" },
        { name = "DD_OP_API_ADDRESS", value = "0.0.0.0:8181" },
        { name = "DD_OP_SOURCE_SPLUNK_TCP_ADDRESS", value = "0.0.0.0:9997" },
        { name = "DD_SITE", value = "datadoghq.com" },
        { name = "DD_OP_PIPELINE_ID", value ="49ce7acc-a612-11f0-9c7d-da7ad0900002" },
        { name = "DD_API_KEY", value="<redacted>" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = "/ecs/datadog-test"
          awslogs-create-group  = "true"
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "opworker"
        }
      }
    }
  ])
}

# ECS Service
resource "aws_ecs_service" "main" {
  name            = "datadog-test-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks.id, aws_security_group.ecs_tasks_nlb.id]
    subnets          = data.aws_subnets.all.ids
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.opworker.arn
    container_name   = "dd-observability-pipelines-worker"
    container_port   = 9997
  }
}

# IAM roles
resource "aws_iam_role" "ecs_task_role" {
  name = "datadog-test-app-ecsTaskRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}
