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
resource "aws_security_group" "alb" {
  name        = "datadog-test-app-alb"
  description = "Security group for ALB"
  vpc_id      = var.aws_vpc

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
    security_groups = [aws_security_group.ecs_tasks_alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "datadog-test-app-ecs-tasks"
  description = "Allow inbound traffic from ALB"
  vpc_id      = var.aws_vpc

  ingress {
    from_port       = 8282
    to_port         = 8282
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # Required for healthcheck to pass
  ingress {
    from_port       = 8181
    to_port         = 8181
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# second sg to attach to the tasks and provide an id to the ALB
resource "aws_security_group" "ecs_tasks_alb" {
  name        = "datadog-test-app-ecs-tasks-alb"
  description = "Allow traffic to ALB"
  vpc_id      = var.aws_vpc

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ALB
resource "aws_lb" "main" {
  name               = "datadog-test-app-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.all.ids

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "ddworker" {
  name        = "datadog-op-worker-tg"
  port        = 8282
  protocol    = "HTTP"
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

resource "aws_lb_listener" "ddworker" {
  load_balancer_arn = aws_lb.main.arn
  port              = "8282"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ddworker.arn
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "khax-paclife"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "app" {
  family                   = "datadog-test-app"
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
          containerPort: 8282,
          hostPort: 8282,
          protocol: "tcp"
        }
      ],
    #   secrets = [
    #     {
    #       name      = "DD_API_KEY",
    #       valueFrom = "arn:aws:secretsmanager:us-west-2:439537465448:secret:kelnerDogfoodAccount-EioKim:DD_API_KEY::"
    #     }
    #   ]
      environment = [
        { name = "DD_OP_API_ENABLED", value = "true" },
        { name = "DD_OP_API_ADDRESS", value = "0.0.0.0:8181" },
        { name = "DD_OP_SOURCE_HTTP_SERVER_ADDRESS", value = "0.0.0.0:8282" },
        #{ name = "DD_OP_SOURCE_FLUENT_ADDRESS", value = "0.0.0.0:8282" },
        { name = "DD_SITE", value = "datadoghq.com" },
        { name = "DD_OP_PIPELINE_ID", value ="c051b524-8358-11f0-89af-da7ad0900002" },
        # Had issues with AWS Secrets Manager, shortcut to get things working
        { name = "DD_API_KEY", value="aeb532b287b54358b0be018051ffa756" }
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
    },
    # Nginx log generator
    {
      name      = "nginx-log-generator"
      image     = "docker.io/kscarlett/nginx-log-generator:latest"
      essential = true
      mountPoints = []
      portMappings = []
      systemControls = []
      volumesFrom = []

      environment = [
        { name = "RATE", value = "10" }
      ]

      logConfiguration = {
        logDriver = "awsfirelens"
        options = {
            Name = "http"
            Host = "${aws_lb.main.dns_name}"
            Port = "8282"
            TLS = "off"
            Format = "json",
            Header = "Content-Type: application/json"
        }
      }
    },
    # firelens
    {
      name      = "log_router"
      image     = "amazon/aws-for-fluent-bit:stable"
      essential = true
      environment = []
      mountPoints = []
      portMappings = []
      systemControls = []
      user = "0"
      volumesFrom = []

      firelensConfiguration = {
        type = "fluentbit"
        options = {
            enable-ecs-log-metadata = "true"
        }
        memoryReservation = 50
      },
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = "/ecs/datadog-test"
          awslogs-create-group  = "true"
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "log_router"
        }
      }
    }
  ])
}

# ECS Service
resource "aws_ecs_service" "main" {
  name            = "datadog-test-app-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.ecs_tasks.id, aws_security_group.ecs_tasks_alb.id]
    subnets          = data.aws_subnets.all.ids
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ddworker.arn
    container_name   = "dd-observability-pipelines-worker"
    container_port   = 8282
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
