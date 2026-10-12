data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

locals {
  # Deterministic suffix so the globally-unique ACR name is stable across runs.
  suffix = substr(sha1(data.azurerm_resource_group.rg.id), 0, 6)
  name   = "${var.app_name}-${var.environment}"
  tags = {
    app         = var.app_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

# ---------- Container registry ----------
resource "azurerm_container_registry" "acr" {
  name                = "acr${var.app_name}${var.environment}${local.suffix}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false # identities only, no shared admin password
  tags                = local.tags
}

# ---------- Observability ----------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "law-${local.name}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

# ---------- Runtime platform ----------
resource "azurerm_container_app_environment" "env" {
  name                       = "cae-${local.name}"
  resource_group_name        = data.azurerm_resource_group.rg.name
  location                   = data.azurerm_resource_group.rg.location
  log_analytics_workspace_id = azurerm_log_analytics_workspace.law.id
  tags                       = local.tags
}

# The app pulls images with a managed identity that only has AcrPull on this one registry.
resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${local.name}"
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.acr.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

resource "azurerm_container_app" "api" {
  name                         = "ca-${local.name}"
  resource_group_name          = data.azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.env.id
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  registry {
    server   = azurerm_container_registry.acr.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  ingress {
    external_enabled = true
    target_port      = 8000
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0 # scale to zero: ~free when idle
    max_replicas = var.max_replicas

    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = "50"
    }

    container {
      name   = "api"
      image  = "${azurerm_container_registry.acr.login_server}/${var.app_name}:${var.image_tag}"
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "APP_VERSION"
        value = var.image_tag
      }

      liveness_probe {
        transport = "HTTP"
        path      = "/health"
        port      = 8000
      }

      readiness_probe {
        transport = "HTTP"
        path      = "/health"
        port      = 8000
      }
    }
  }

  depends_on = [azurerm_role_assignment.acr_pull]
}

# ---------- Alerting ----------
resource "azurerm_monitor_action_group" "ops" {
  count               = var.alert_email == "" ? 0 : 1
  name                = "ag-${local.name}"
  resource_group_name = data.azurerm_resource_group.rg.name
  short_name          = "ops"

  email_receiver {
    name          = "oncall"
    email_address = var.alert_email
  }
}

resource "azurerm_monitor_metric_alert" "http_5xx" {
  count               = var.alert_email == "" ? 0 : 1
  name                = "alert-${local.name}-5xx"
  resource_group_name = data.azurerm_resource_group.rg.name
  scopes              = [azurerm_container_app.api.id]
  description         = "More than 5 server errors in 5 minutes"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "microsoft.app/containerapps"
    metric_name      = "Requests"
    aggregation      = "Total"
    operator         = "GreaterThan"
    threshold        = 5

    dimension {
      name     = "statusCodeCategory"
      operator = "Include"
      values   = ["5xx"]
    }
  }

  action {
    action_group_id = azurerm_monitor_action_group.ops[0].id
  }

  tags = local.tags
}
