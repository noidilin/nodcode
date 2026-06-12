variable "environment" { type = string }
variable "project" { type = string }
variable "owner" { type = string }
variable "name_prefix" { type = string }
variable "private_db_subnet_ids" { type = list(string) }
variable "db_security_group_id" { type = string }
variable "db_name" { type = string }
variable "db_username" { type = string }
variable "db_instance_class" { type = string }
variable "db_allocated_storage_gb" { type = number }
variable "db_engine_version" { type = string }
variable "db_multi_az" { type = bool }
variable "db_deletion_protection" { type = bool }
variable "db_skip_final_snapshot" {
  description = "Whether to skip final DB snapshot on destroy. Stage may set true; prod should normally set false."
  type        = bool
  default     = false
}
