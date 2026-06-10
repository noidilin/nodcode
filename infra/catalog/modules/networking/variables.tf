variable "environment" { type = string }
variable "project" { type = string }
variable "owner" { type = string }
variable "name_prefix" { type = string }
variable "vpc_cidr" { type = string }
variable "az_count" {
  type = number
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}
variable "allowed_http_cidr_blocks" { type = list(string) }
variable "enable_http_to_https_redirect" { type = bool }
variable "enable_nat_gateway" { type = bool }
variable "api_container_port" { type = number }
