output "plan_role_arn" { value = aws_iam_role.plan.arn }
output "image_push_role_arn" { value = aws_iam_role.image_push.arn }
output "apply_role_arn" { value = aws_iam_role.apply.arn }
