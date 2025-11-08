variable "region" {
  description = "AWS region to deploy resources in"
  type        = string
}

variable "app_name" {
  description = "Base name prefix for ECS cluster and related resources"
  type        = string
}

variable "bucket_name" {
  description = "Name of S3 bucket for uploads"
  type        = string
}

variable "queue_name" {
  description = "Name of SQS queue"
  type        = string
}
