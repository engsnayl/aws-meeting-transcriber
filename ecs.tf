resource "aws_ecs_cluster" "whisper_ecs_cluster" {
  name = "whisper-ecs-cluster-v2"

  tags = {
    component = "transcribe"
  }
}

# Matches live revision 6 exactly (image v5, 2048/4096, UTF-8 locale env)
resource "aws_ecs_task_definition" "whisper_task" {
  family                   = "whisper-transcribe"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "2048"
  memory                   = "4096"
  execution_role_arn       = aws_iam_role.ecs_task_exec.arn
  task_role_arn            = aws_iam_role.ecs_task_exec.arn

  tags = {
    component = "transcribe"
  }

  # skip_destroy is Terraform-only bookkeeping (no AWS counterpart);
  # ignored so the adopted resource shows tag-only changes.
  lifecycle {
    ignore_changes = [skip_destroy]
  }

  container_definitions = jsonencode([
    {
      name      = "whisper-container",
      image     = "340752829546.dkr.ecr.eu-west-1.amazonaws.com/whisper-ecs:v5",
      cpu       = 2048,
      memory    = 4096,
      essential = true,
      environment = [
        {
          name  = "LANG"
          value = "C.UTF-8"
        },
        {
          name  = "LC_ALL"
          value = "C.UTF-8"
        },
        {
          name  = "PYTHONIOENCODING"
          value = "utf-8"
        }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_whisper_logs.name,
          awslogs-region        = "eu-west-1",
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}
