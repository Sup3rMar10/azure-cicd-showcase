variable "resource_group_name" {
  description = "Pre-created resource group (by scripts/bootstrap.sh) that this stack deploys into."
  type        = string
}

variable "app_name" {
  description = "Short application name used as a prefix for resources."
  type        = string
  default     = "invoice"
}

variable "environment" {
  description = "Environment name (dev, prod...)."
  type        = string
  default     = "prod"
}

variable "image_tag" {
  description = "Container image tag to run (the pipeline passes the git SHA)."
  type        = string
}

variable "max_replicas" {
  description = "Upper bound for HTTP autoscaling."
  type        = number
  default     = 3
}

variable "alert_email" {
  description = "Email for 5xx alerts. Empty disables the alert."
  type        = string
  default     = ""
}
