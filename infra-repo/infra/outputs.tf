output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service1_name" {
  value = aws_ecs_service.svc1.name
}

output "service2_name" {
  value = aws_ecs_service.svc2.name
}

output "ecr_svc1" {
  value = aws_ecr_repository.svc1.repository_url
}

output "ecr_svc2" {
  value = aws_ecr_repository.svc2.repository_url
}

output "alb_dns_name" {
  value = aws_lb.public.dns_name
}

output "s3_bucket" {
  value = aws_s3_bucket.uploads.bucket
}

output "sqs_url" {
  value = aws_sqs_queue.messages.url
}
