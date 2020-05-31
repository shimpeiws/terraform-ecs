variable "image_uri" {}

data "aws_iam_policy" "ecs_task_execution_role_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_task_execution" {
  source_json = data.aws_iam_policy.ecs_task_execution_role_policy.policy
}

module "ecs_task_execution_role" {
  source = "./iam_role"
  name = "ecs-task-execution"
  identifier = "ecs-tasks.amazonaws.com"
  policy = data.aws_iam_policy_document.ecs_task_execution.json
}

resource "aws_ecs_task_definition" "example" {
  family                   = "example"
  cpu                      = "256"
  memory                   = "512"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  container_definitions =<<DEFINITION
  [
    {
      "name": "example",
      "image": "${var.image_uri}",
      "essential": true,
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-region": "ap-northeast-1",
          "awslogs-stream-prefix": "blank-container",
          "awslogs-group": "/ecs/example"
        }
      },
      "portMappings": [
        {
          "protocol": "tcp",
          "containerPort": 80
        }
      ],
      "healthCheck": {
        "command": ["CMD-SHELL", "sh health-check.sh"],
        "interval": 30,
        "timeout": 5,
        "startPeriod": 3,
        "retries": 3
      }
    }
  ]
  DEFINITION

  task_role_arn =  module.ecs_task_execution_role.iam_role_arn
  execution_role_arn = module.ecs_task_execution_role.iam_role_arn
}

resource "aws_vpc" "example" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "example"
  }
}

resource "aws_internet_gateway" "igw-1" {
  vpc_id = aws_vpc.example.id
  tags = {
    Name = "igw-1"
  }
}

resource "aws_route_table" "public-route-table" {
  vpc_id = aws_vpc.example.id
  route {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.igw-1.id
  }
  tags = {
    Name = "public-route-table"
  }
}

resource "aws_subnet" "public_0" {
    vpc_id = aws_vpc.example.id
    cidr_block = "10.0.1.0/24"
    availability_zone = "ap-northeast-1a"
    tags = {
      Name = "subnet-public-1a"
    }
}

resource "aws_route_table_association" "public-association" {
    subnet_id = aws_subnet.public_0.id
    route_table_id = aws_route_table.public-route-table.id
}

resource "aws_subnet" "private_0" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.65.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = false
}

resource "aws_subnet" "private_1" {
  vpc_id                  = aws_vpc.example.id
  cidr_block              = "10.0.66.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = false
}

resource "aws_security_group" "my_security_group" {
  name        = "my-security-group"
  vpc_id      = aws_vpc.example.id

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

resource "aws_ecs_service" "example" {
  name                              = "example"
  cluster                           = aws_ecs_cluster.example.arn
  task_definition                   = aws_ecs_task_definition.example.arn
  desired_count                     = 2
  launch_type                       = "FARGATE"
  platform_version                  = "1.3.0"

  network_configuration {
    assign_public_ip = true
    security_groups  = [aws_security_group.my_security_group.id]

    subnets = [
      aws_subnet.private_0.id,
      aws_subnet.private_1.id,
      aws_subnet.public_0.id
    ]
  }
}

resource "aws_appautoscaling_target" "test_ecs_target" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.example.name}/${aws_ecs_service.example.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  role_arn           = data.aws_iam_role.ecs_service_autoscaling.arn
  min_capacity       = 2
  max_capacity       = 4
}

# Automatically scale capacity up by one
resource "aws_appautoscaling_policy" "test_ecs_scale_up" {
  name               = "scale_up"
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.example.name}/${aws_ecs_service.example.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 600
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 2
    }
  }

  depends_on = [aws_appautoscaling_target.test_ecs_target]
}

# Automatically scale capacity down by one
resource "aws_appautoscaling_policy" "test_ecs_scale_down" {
  name               = "scale_down"
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.example.name}/${aws_ecs_service.example.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 600
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = -2
    }
  }
}

# Cloudwatch alarm that triggers the autoscaling up policy
resource "aws_cloudwatch_metric_alarm" "test_cpu_high" {
  alarm_name          = "cpu_utilization_high"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "50"

  dimensions = {
    ClusterName = aws_ecs_cluster.example.name
    ServiceName = aws_ecs_service.example.name
  }

  alarm_actions = [aws_appautoscaling_policy.test_ecs_scale_up.arn]
}

# Cloudwatch alarm that triggers the autoscaling down policy
resource "aws_cloudwatch_metric_alarm" "test_cpu_low" {
  alarm_name          = "cpu_utilization_low"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = "60"
  statistic           = "Average"
  threshold           = "50"

  dimensions = {
    ClusterName = aws_ecs_cluster.example.name
    ServiceName = aws_ecs_service.example.name
  }

  alarm_actions = [aws_appautoscaling_policy.test_ecs_scale_down.arn]
}

data "aws_iam_role" "ecs_service_autoscaling" {
  name = "AWSServiceRoleForApplicationAutoScaling_ECSService"
}
