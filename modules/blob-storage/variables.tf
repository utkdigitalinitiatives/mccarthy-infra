variable "project_name" {
  description = "Project identifier used as the resource name prefix (e.g. mccarthy)"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, poc, staging)"
  type        = string
}

variable "storage_prefix" {
  description = <<-EOT
    Short lowercase token used to build the auto-generated storage account name.
    Kept separate from project_name because storage account names are capped at
    24 characters: prefix + abbreviated environment + an 8-char random suffix.
    Keep this to 3-5 characters.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.storage_prefix))
    error_message = "storage_prefix must be 2-6 lowercase alphanumeric characters."
  }
}

variable "environment_abbreviations" {
  description = "Maps environment names to the short form used in storage account names"
  type        = map(string)
  default = {
    production = "prod"
    devtest    = "devtest"
    dev        = "dev"
  }
}

variable "disable_defender_for_storage" {
  description = "Set true to opt this storage account out of Defender for Storage (overrides subscription default)"
  type        = bool
  default     = false
}

variable "resource_group_name" {
  description = "Name of the resource group"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
}

variable "storage_account_name" {
  description = "Storage account name (3-24 chars, lowercase alphanumeric). If null, auto-generated"
  type        = string
  default     = null

  validation {
    condition     = var.storage_account_name == null || can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account name must be 3-24 lowercase alphanumeric characters."
  }
}

variable "container_name" {
  description = "Name of the blob container for Drupal media"
  type        = string
  default     = "drupal-media"
}

variable "account_tier" {
  description = "Storage account tier (Standard or Premium)"
  type        = string
  default     = "Standard"

  validation {
    condition     = contains(["Standard", "Premium"], var.account_tier)
    error_message = "account_tier must be 'Standard' or 'Premium'."
  }
}

variable "replication_type" {
  description = "Storage replication type (LRS, GRS, RAGRS, ZRS, GZRS, RAGZRS)"
  type        = string
  default     = "LRS"

  validation {
    condition     = contains(["LRS", "GRS", "RAGRS", "ZRS", "GZRS", "RAGZRS"], var.replication_type)
    error_message = "replication_type must be one of: LRS, GRS, RAGRS, ZRS, GZRS, RAGZRS."
  }
}

variable "shared_access_key_enabled" {
  description = "Enable shared access keys (disable for managed identity only access)"
  type        = bool
  default     = true
}

# Blob protection
variable "enable_versioning" {
  description = "Enable blob versioning"
  type        = bool
  default     = false
}

variable "soft_delete_retention_days" {
  description = "Soft delete retention for blobs in days (0 to disable)"
  type        = number
  default     = 7
}

variable "container_soft_delete_retention_days" {
  description = "Soft delete retention for containers in days (0 to disable)"
  type        = number
  default     = 7
}

# Network rules
variable "enable_network_rules" {
  description = "Enable network rules to restrict access"
  type        = bool
  default     = false
}

variable "allowed_ip_addresses" {
  description = "List of public IP addresses allowed to access storage (when network rules enabled)"
  type        = list(string)
  default     = []
}

variable "allowed_subnet_ids" {
  description = "List of subnet IDs allowed to access storage (when network rules enabled)"
  type        = list(string)
  default     = []
}

# Managed identity access
variable "enable_vmss_blob_access" {
  description = "Enable blob access for VMSS managed identity (must be known at plan time)"
  type        = bool
  default     = false
}

variable "vmss_principal_id" {
  description = "Principal ID of the VMSS managed identity to grant blob access"
  type        = string
  default     = null
}

variable "additional_principal_ids" {
  description = "Additional principal IDs to grant blob access"
  type = map(object({
    principal_id = string
    role         = string
  }))
  default = {}
}

variable "developer_identities" {
  description = "Map of developer username -> Azure AD object ID. Each gets an isolated drupal-media-<username> container plus Storage Blob Data Contributor on the storage account for azcopy sync. Devtest only."
  type        = map(string)
  default     = {}
}

# Private endpoint (production)
variable "private_endpoint_subnet_id" {
  description = "Subnet ID for private endpoint (null for public access)"
  type        = string
  default     = null
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for private endpoint"
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
