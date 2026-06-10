output "ecr_repository_url" {
  description = "Push NodCode API images to this ECR repository URL."
  value       = aws_ecr_repository.api.repository_url
}
