########################################
# Data Sources
########################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_vpc" "default" { id = "vpc-090223335abb8d785" }
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

########################################
# S3 Bucket & SQS Queue
########################################

resource "aws_s3_bucket" "uploads" {
  bucket        = var.bucket_name
  force_destroy = true
}

resource "aws_sqs_queue" "messages" {
  name = var.queue_name
}

########################################
# ECR Repositories
########################################

resource "aws_ecr_repository" "svc1" {
  name         = "${var.app_name}-service1"
  force_delete = true
}

resource "aws_ecr_repository" "svc2" {
  name         = "${var.app_name}-service2"
  force_delete = true
}

########################################
# ECS Cluster
########################################

resource "aws_ecs_cluster" "this" {
  name = "${var.app_name}-cluster"
}

########################################
# IAM Roles
########################################

# Task execution role (pull images, send logs)
data "aws_iam_policy_document" "task_exec_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${var.app_name}-ecs-task-exec"
  assume_role_policy = data.aws_iam_policy_document.task_exec_assume.json
}

resource "aws_iam_role_policy_attachment" "exec_policy" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Service 1 task role (S3 access)
resource "aws_iam_role" "task_role_svc1" {
  name               = "${var.app_name}-svc1-role"
  assume_role_policy = data.aws_iam_policy_document.task_exec_assume.json
}

resource "aws_iam_role_policy" "svc1_s3_policy" {
  name = "${var.app_name}-svc1-s3-access"
  role = aws_iam_role.task_role_svc1.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      Resource = [
        aws_s3_bucket.uploads.arn,
        "${aws_s3_bucket.uploads.arn}/*"
      ]
    }]
  })
}

# Service 2 task role (SQS access)
resource "aws_iam_role" "task_role_svc2" {
  name               = "${var.app_name}-svc2-role"
  assume_role_policy = data.aws_iam_policy_document.task_exec_assume.json
}

resource "aws_iam_role_policy" "svc2_sqs_policy" {
  name = "${var.app_name}-svc2-sqs-access"
  role = aws_iam_role.task_role_svc2.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["sqs:SendMessage"],
      Resource = aws_sqs_queue.messages.arn
    }]
  })
}

########################################
# Security Groups
########################################

resource "aws_security_group" "alb" {
  name        = "${var.app_name}-alb-sg"
  description = "Allow HTTP inbound"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "tasks" {
  name   = "${var.app_name}-tasks-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    from_port       = 5000
    to_port         = 5000
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

########################################
# ALB
########################################

resource "aws_lb" "public" {
  name               = "${var.app_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]

  # Pick only 2 subnets across different AZs
  subnets = tolist(slice(distinct(data.aws_subnets.public.ids), 0, 2))
}

resource "aws_lb_target_group" "svc1" {
  name        = "${var.app_name}-svc1-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
  health_check {
    path = "/health"
  }
}

resource "aws_lb_target_group" "svc2" {
  name        = "${var.app_name}-svc2-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
  health_check {
    path = "/health"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.public.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "svc1" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc1.arn
  }

  condition {
    path_pattern { values = ["/upload*"] }
  }
}

resource "aws_lb_listener_rule" "svc2" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.svc2.arn
  }

  condition {
    path_pattern { values = ["/queue*"] }
  }
}

########################################
# CloudWatch Logs
########################################

resource "aws_cloudwatch_log_group" "svc1" {
  name              = "/ecs/${var.app_name}/service1"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "svc2" {
  name              = "/ecs/${var.app_name}/service2"
  retention_in_days = 7
}

########################################
# ECS Task Definitions
########################################

resource "aws_ecs_task_definition" "svc1" {
  family                   = "${var.app_name}-svc1"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role_svc1.arn

  container_definitions = jsonencode([{
    name  = "svc1"
    image = "${aws_ecr_repository.svc1.repository_url}:latest"
    portMappings = [{ containerPort = 5000 }]
    environment = [{ name = "BUCKET_NAME", value = aws_s3_bucket.uploads.bucket }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.svc1.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

resource "aws_ecs_task_definition" "svc2" {
  family                   = "${var.app_name}-svc2"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task_role_svc2.arn

  container_definitions = jsonencode([{
    name  = "svc2"
    image = "${aws_ecr_repository.svc2.repository_url}:latest"
    portMappings = [{ containerPort = 5000 }]
    environment = [{ name = "QUEUE_URL", value = aws_sqs_queue.messages.url }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.svc2.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

########################################
# ECS Services
########################################

resource "aws_ecs_service" "svc1" {
  name            = "${var.app_name}-svc1"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.svc1.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = data.aws_subnets.public.ids
    security_groups = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.svc1.arn
    container_name   = "svc1"
    container_port   = 5000
  }

  depends_on = [aws_lb_listener_rule.svc1]
}

resource "aws_ecs_service" "svc2" {
  name            = "${var.app_name}-svc2"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.svc2.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = data.aws_subnets.public.ids
    security_groups = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.svc2.arn
    container_name   = "svc2"
    container_port   = 5000
  }

  depends_on = [aws_lb_listener_rule.svc2]
}
