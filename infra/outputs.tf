output "acr_name" {
  value = azurerm_container_registry.acr.name
}

output "acr_login_server" {
  value = azurerm_container_registry.acr.login_server
}

output "app_url" {
  value = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}
