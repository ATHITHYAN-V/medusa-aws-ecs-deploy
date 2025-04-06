provider "aws" {
  region = "us-east-1"
}

variable "container_image" {
  description = "The container image to use for the Medusa service"
  type        = string
}

# VPC Configuration
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "medusa-vpc"
  }
}

resource "aws_subnet" "public_subnet1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet-1"
  }
}

resource "aws_subnet" "public_subnet2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet-2"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "main-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public_subnet1" {
  subnet_id      = aws_subnet.public_subnet1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_subnet2" {
  subnet_id      = aws_subnet.public_subnet2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "lb_sg" {
  vpc_id = aws_vpc.main.id

  # Allow incoming HTTP traffic on port 80
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow incoming HTTPS traffic on port 443 (if needed)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow any outbound traffic (egress)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lb-sg"
  }
}


# IAM Roles
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role" "ecs_task_role" {
  name = "ecsTaskRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy_attachment" "ecs_execution_policy_attachment" {
  name       = "ecsExecutionPolicyAttachment"
  roles      = [aws_iam_role.ecs_task_execution_role.name]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy_attachment" "ecs_task_policy_attachment" {
  name       = "ecsTaskPolicyAttachment"
  roles      = [aws_iam_role.ecs_task_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSTaskPolicy"
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "medusa-cluster"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "medusa" {
  family                   = "medusa-task"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "3072"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "medusa"
      image     = var.container_image
      essential = true
      cpu       = 1024
      portMappings = [
        {
          containerPort = 30000
          hostPort      = 30000
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = "/ecs/medusa-task"
          awslogs-region        = "us-east-1"
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

# Load Balancer
resource "aws_lb" "medusa_lb" {
  name               = "medusa-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [aws_subnet.public_subnet1.id, aws_subnet.public_subnet2.id]
  enable_deletion_protection = false
  idle_timeout       = 60

  tags = {
    Name = "medusa-alb"
  }
}

resource "aws_lb_target_group" "medusa_target_group" {
  name     = "medusa-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "medusa-target-group"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.medusa_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.medusa_target_group.arn
  }
}

# ECS Service
resource "aws_ecs_service" "medusa_service" {
  name            = "medusa-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.medusa.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.public_subnet1.id, aws_subnet.public_subnet2.id]
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs_sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.medusa_target_group.arn
    container_name   = "medusa"
    container_port   = 30000
  }
}

# Outputs
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet1_id" {
  value = aws_subnet.public_subnet1.id
}

output "publisc_subnet2_id" {
  value = aws_subnet.public_subnet2.id
}

output "load_balancer_dns" {
  value = aws_lb.medusa_lb.dns_name
}

output "target_group_arn" {
  value = aws_lb_target_group.medusa_target_group.arn
}

output "ecs_cluster_id" {
  value = aws_ecs_cluster.main.id
}

output "ecs_task_definition_arn" {
  value = aws_ecs_task_definition.medusa.arn
}
