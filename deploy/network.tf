resource "azurerm_virtual_network" "soc" {
  name                = "vnet-${var.prefix}-honeynet"
  location            = azurerm_resource_group.soc.location
  resource_group_name = azurerm_resource_group.soc.name
  address_space       = ["10.0.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "soc" {
  name                 = "snet-${var.prefix}-honeynet"
  resource_group_name  = azurerm_resource_group.soc.name
  virtual_network_name = azurerm_virtual_network.soc.name
  address_prefixes     = ["10.0.0.0/24"]
}

# NSG starts LOCKED DOWN: a single high-priority deny on all inbound from the
# Internet. No RDP/SSH/MSSQL allow rules — the honeynet is NOT exposed until
# the operator deliberately adds allow rules (Phase C). Azure's default rules
# still permit intra-VNet and Azure LB traffic at lower priority.
resource "azurerm_network_security_group" "soc" {
  name                = "nsg-${var.prefix}-honeynet"
  location            = azurerm_resource_group.soc.location
  resource_group_name = azurerm_resource_group.soc.name
  tags                = var.tags

  security_rule {
    name                       = "DENY-ALL-INBOUND"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
    description                = "Honeynet locked down. Add allow rules (RDP 3389 / SSH 22 / MSSQL 1433) to expose."
  }
}

resource "azurerm_subnet_network_security_group_association" "soc" {
  subnet_id                 = azurerm_subnet.soc.id
  network_security_group_id = azurerm_network_security_group.soc.id
}
