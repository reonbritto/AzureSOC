variable "subscription_id" {
  type        = string
  description = "Target Azure subscription ID. Set it in terraform.tfvars, via -var, or the ARM_SUBSCRIPTION_ID env var. Must be a subscription whose policy allows the chosen region."
}

variable "location" {
  type        = string
  description = "Azure region for all resources."
  default     = "francecentral"
}

variable "prefix" {
  type        = string
  description = "Short name prefix for all resources (lowercase, no spaces)."
  default     = "soc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,8}$", var.prefix))
    error_message = "prefix must be 2-9 chars, lowercase letters/digits, starting with a letter."
  }
}

variable "vm_size" {
  type        = string
  description = "VM size for all three honeynet VMs."
  default     = "Standard_B2ats_v2"
}

variable "admin_username" {
  type        = string
  description = "Local admin username for all VMs. Windows rules: 1-20 chars, no @ / \\ [ ] : | < > + = ; , ? * or trailing period, and not a reserved name like 'admin'/'administrator'."
  default     = "socadmin"

  validation {
    condition     = can(regex("^[a-zA-Z0-9._-]{1,20}$", var.admin_username)) && var.admin_username != "admin" && var.admin_username != "administrator"
    error_message = "admin_username must be 1-20 chars (letters/digits/._-), contain no @ or other forbidden chars, and not be 'admin'/'administrator'. Windows rejects the VM otherwise."
  }
}

variable "admin_password" {
  type        = string
  description = "Local admin password for all VMs. Supply via TF_VAR_admin_password env var or -var; never commit it."
  sensitive   = true

  validation {
    # Azure VM password complexity: 12-123 chars, 3 of {lower, upper, digit, special}.
    condition     = length(var.admin_password) >= 12 && length(var.admin_password) <= 72
    error_message = "admin_password must be 12-72 characters and meet Azure complexity rules (upper, lower, digit, special)."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default = {
    project     = "azure-soc-honeynet"
    environment = "lab"
    purpose     = "honeynet"
  }
}
