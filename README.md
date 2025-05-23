
---

## 🚀 Deploying Medusa Backend on AWS ECS with Terraform & GitHub Actions

### 👨‍💻 Overview

This project demonstrates the complete IaC using Terraform  to deploy the  Medusa open source headless commerce platform backend (https://docs.medusajs.com/deployments/server/general-guide),on Aws ECS with Fargate and set up CD pipeline using GitHub Actions

---

## 🔧 Prerequisites

- AWS Account
- GitHub Account
- Terraform Installed
- Docker Installed
- Git Installed

---

## 🌐 Step 1: AWS Setup

1. **Create IAM User**  
   - Enable programmatic access  
   - Attach policies:
     - `AmazonEC2ContainerServiceFullAccess`
     - `AmazonRDSFullAccess`
     - `IAMFullAccess`
     - `AmazonECS_FullAccess`

2. **Note** your `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` — we'll use them in GitHub Actions.

---

## 📦 Step 2: Terraform Infrastructure (IaC)

**File: `main.tf`**
```hcl
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
```

---

## 🐳 Step 3: Docker Setup

**File: `Dockerfile`**
```Dockerfile
FROM node:18-alpine

WORKDIR /app

COPY . .

RUN npm install

EXPOSE 9000

CMD ["npm", "run", "start"]
```

**File: `.env`**
```env
DATABASE_URL=postgres://admin:yourpassword@<REPLACE_WITH_RDS_ENDPOINT>:5432/medusa
```

**File: `docker-compose.yml`**
```yaml
version: "3.9"
services:
  medusa:
    build: .
    ports:
      - "9000:9000"
    env_file:
      - .env
```

---

## 🔁 Step 4: GitHub Actions CI/CD

**File: `.github/workflows/deploy.yml`**
```yaml
name: Deploy Medusa to AWS ECS

on:
  push:
    branches:
      - main

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repo
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.ACCESS_KEY }}
          aws-secret-access-key: ${{ secrets.SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Set ECR image URI
        id: vars
        run: |
          echo "REPO_URI=$(aws ecr describe-repositories --repository-names medusa-store --region us-east-1 --query 'repositories[0].repositoryUri' --output text)" >> $GITHUB_ENV

      - name: Build, tag, and push Docker image to ECR
        run: |
          docker build -t $REPO_URI:latest .
          docker push $REPO_URI:latest

      - name: Update ECS Task Definition with new ECR image
        id: update-task-def
        run: |
          TASK_DEF=$(aws ecs describe-task-definition --task-definition medusa-task)
          NEW_TASK_DEF=$(echo "$TASK_DEF" | jq \
            --arg IMAGE "$REPO_URI:latest" \
            '.taskDefinition |
            .containerDefinitions[0].image = $IMAGE |
            del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')
          echo "$NEW_TASK_DEF" > new-task-def.json
          NEW_ARN=$(aws ecs register-task-definition --cli-input-json file://new-task-def.json | jq -r '.taskDefinition.taskDefinitionArn')
          echo "task_definition_arn=$NEW_ARN" >> $GITHUB_OUTPUT

      - name: Deploy updated task to ECS
        run: |
          aws ecs update-service \
            --cluster medusa-cluster \
            --service medusa-service \
            --task-definition ${{ steps.update-task-def.outputs.task_definition_arn }} \
            --force-new-deployment
```

---

## 🔐 Step 5: Add Secrets to GitHub

Go to your GitHub Repo → `Settings > Secrets and variables > Actions` and add:

- `ACCESS_KEY`
- `SECRET_ACCESS_KEY`

---

## 🚀 Step 6: Run It All

1. Initialize Terraform:
```bash
terraform init
terraform apply
```

2. Get the RDS Endpoint from output and update `.env`

3. Build and Push Docker image:
```bash
docker build -t yourdockeruser/medusa-backend .
docker push yourdockeruser/medusa-backend
```

4. Push code to GitHub `main` branch → GitHub Actions takes over and deploys.

---

## ✅ Final Result

- ECS Service running Medusa backend
- CI/CD with GitHub Actions
- Docker image pushed to ECS
- Live, scalable, serverless deployment 🎉

---

## 🎥 Video

> 🔗 **[Insert YouTube Video Link Here]**  
> In this video, I walk through everything — including my face and live output. Check it out!

---

## 🔗 GitHub Repo

> 🔗 **[https://github.com/ATHITHYAN-V/medusa-aws-ecs-deploy/tree/main]**  
> Feel free to fork or star it! Contributions welcome.

---
