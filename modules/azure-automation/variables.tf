variable "project_name" {
  description = "Project identifier used as the resource name prefix (e.g. mccarthy)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., devtest)"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "target_tag_key" {
  description = "Tag key to filter PostgreSQL servers for auto-stop"
  type        = string
  default     = "AutoStop"
}

variable "target_tag_value" {
  description = "Tag value to filter PostgreSQL servers for auto-stop"
  type        = string
  default     = "true"
}

variable "schedule_timezone" {
  description = "Timezone for the automation schedule"
  type        = string
  default     = "America/New_York"
}

variable "schedule_week_days" {
  description = "Days of the week to run the schedule"
  type        = list(string)
  default     = ["Friday"]
}

variable "schedule_start_time" {
  description = "Start time for the schedule (RFC3339 format, date portion ignored for recurring)"
  type        = string
  default     = "2026-02-13T22:00:00-05:00"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
