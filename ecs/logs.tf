resource "aws_cloudwatch_log_group" "example_ecs_log_group" {
  name = "/ecs/example"
  retention_in_days = 180
}
