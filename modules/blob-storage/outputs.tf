output "storage_account_id" {
  description = "ID of the storage account"
  value       = azurerm_storage_account.drupal.id
}

output "storage_account_name" {
  description = "Name of the storage account"
  value       = azurerm_storage_account.drupal.name
}

output "primary_blob_endpoint" {
  description = "Primary blob service endpoint"
  value       = azurerm_storage_account.drupal.primary_blob_endpoint
}

output "container_name" {
  description = "Name of the Drupal media container"
  value       = azurerm_storage_container.media.name
}

output "container_url" {
  description = "URL to the Drupal media container"
  value       = "${azurerm_storage_account.drupal.primary_blob_endpoint}${azurerm_storage_container.media.name}"
}

output "dev_container_urls" {
  description = "Map of developer username to per-dev container URL (devtest only)"
  value = {
    for name, c in azurerm_storage_container.dev_media :
    name => "${azurerm_storage_account.drupal.primary_blob_endpoint}${c.name}"
  }
}

output "primary_access_key" {
  description = "Primary access key for the storage account"
  value       = azurerm_storage_account.drupal.primary_access_key
  sensitive   = true
}

output "primary_connection_string" {
  description = "Primary connection string for the storage account"
  value       = azurerm_storage_account.drupal.primary_connection_string
  sensitive   = true
}

output "private_endpoint_ip" {
  description = "Private IP address of the blob private endpoint (if enabled)"
  value       = var.private_endpoint_subnet_id != null ? azurerm_private_endpoint.blob[0].private_service_connection[0].private_ip_address : null
}
