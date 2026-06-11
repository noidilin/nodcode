variable "environment" { type = string }
variable "project" { type = string }
variable "owner" { type = string }
variable "repository_name" { type = string }
variable "max_image_count" {
  type    = number
  default = 50
}
