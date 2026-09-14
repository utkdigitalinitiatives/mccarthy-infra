variable "project_name" {
  description = "Project identifier used as the resource name prefix"
  type        = string
  default     = "mccarthy"
}

variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region for the Key Vault"
  type        = string
  default     = "eastus2"
}

variable "cost_center" {
  description = "CostCenter tag applied to every resource in this stack"
  type        = string
}

variable "gh_actions_sp_object_id" {
  description = <<-EOT
    Object ID (not Application/Client ID) of the <project>-github-actions service
    principal. Fetch with: az ad sp show --id <appId> --query id -o tsv
  EOT
  type        = string
}

variable "operator_object_ids" {
  description = "AAD object IDs of human operators that should have read/write access to all Key Vault secrets."
  type        = list(string)
  default     = []
}

variable "asimov_eso_principal_id" {
  description = <<-EOT
    Object ID (principalId, NOT clientId) of the Asimov AKS cluster's External
    Secrets Operator managed identity. Given Key Vault Secrets User on the
    shared vault so ESO can mirror this site's Solr connector passwords into
    the cluster, where a CronJob creates the matching Solr logins.

    Lives in this manually-applied stack on purpose: the production stack is
    applied by CI on every main merge, and a required variable there that no
    workflow passes fails the deploy (lib-main-infra PR #15, reverted the same
    day). Look it up with:
      az identity show --resource-group rg-asimov --name id-asimov-eso \
        --query principalId -o tsv
    Set null to withhold the role.
  EOT
  type        = string
  default     = "1c62fb68-bdf4-428e-875c-f1abd77a172e"
}
