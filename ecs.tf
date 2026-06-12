resource "aws_ecs_cluster" "whisper_ecs_cluster" {
  name = "whisper-ecs-cluster-v2"

  tags = {
    component = "transcribe"
  }
}

resource "aws_ecs_task_definition" "whisper_task" {
  family                   = "whisper-transcribe"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_exec.arn
  task_role_arn            = aws_iam_role.ecs_task_exec.arn

  tags = {
    component = "transcribe"
  }

  container_definitions = jsonencode([
    {
      name      = "whisper-container",
      image     = "340752829546.dkr.ecr.eu-west-1.amazonaws.com/whisper-ecs:v1",
      essential = true,
      environment = [
        {
          name  = "S3_BUCKET"
          value = aws_s3_bucket.recordings.bucket
        },
        {
          name  = "S3_KEY"
          value = "PLACEHOLDER"
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
