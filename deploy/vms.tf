# ---------------------------------------------------------------------------
# Public IPs — one per VM. Inbound is still blocked by the NSG until the
# operator opens it; the public IP just gives each VM a routable address so
# attackers can reach it once exposure is opened (Phase C).
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "win" {
  count               = 2
  name                = "pip-${var.prefix}-win-${count.index + 1}"
  location            = azurerm_resource_group.soc.location
  resource_group_name = azurerm_resource_group.soc.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_public_ip" "linux" {
  name                = "pip-${var.prefix}-linux"
  location            = azurerm_resource_group.soc.location
  resource_group_name = azurerm_resource_group.soc.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# NICs
# ---------------------------------------------------------------------------
resource "azurerm_network_interface" "win" {
  count               = 2
  name                = "nic-${var.prefix}-win-${count.index + 1}"
  location            = azurerm_resource_group.soc.location
  resource_group_name = azurerm_resource_group.soc.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.soc.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.win[count.index].id
  }
}

resource "azurerm_network_interface" "linux" {
  name                = "nic-${var.prefix}-linux"
  location            = azurerm_resource_group.soc.location
  resource_group_name = azurerm_resource_group.soc.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.soc.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.linux.id
  }
}

# ---------------------------------------------------------------------------
# Windows VMs (2) — Windows Server 2022. VM #1 is the candidate for installing
# SQL Server (MSSQL brute-force map, EventID 18456) as a manual step.
# ---------------------------------------------------------------------------
resource "azurerm_windows_virtual_machine" "win" {
  count                 = 2
  name                  = "vm-${var.prefix}-win-${count.index + 1}"
  computer_name         = "WIN-${count.index + 1}"
  location              = azurerm_resource_group.soc.location
  resource_group_name   = azurerm_resource_group.soc.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.win[count.index].id]
  tags                  = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
}

# ---------------------------------------------------------------------------
# Linux VM (1) — Ubuntu 22.04 LTS. Password auth enabled so SSH brute-force
# attempts produce "Failed password for" syslog the Linux attack map reads.
# ---------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "linux" {
  name                            = "vm-${var.prefix}-linux"
  computer_name                   = "linux-1"
  location                        = azurerm_resource_group.soc.location
  resource_group_name             = azurerm_resource_group.soc.name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.linux.id]
  tags                            = var.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

# NOTE: The Azure Monitor Agent, Log Analytics workspace, Data Collection
# Rules, Sentinel, and Defender are intentionally NOT provisioned here. They
# are the "next steps" set up after the VMs exist — see docs/NEXT-STEPS.md.
