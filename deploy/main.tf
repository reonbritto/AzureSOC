# A short random suffix keeps globally-unique names (storage, key vault)
# collision-free across re-deploys.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix  = random_string.suffix.result
  rg_name = "rg-${var.prefix}-honeynet"
}

resource "azurerm_resource_group" "soc" {
  name     = local.rg_name
  location = var.location
  tags     = var.tags
}
