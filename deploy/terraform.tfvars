# Non-sensitive deployment settings. The VM admin password is NOT here —
# supply it at apply time:  export TF_VAR_admin_password='<complex-password>'
# (Git Bash)  or  $env:TF_VAR_admin_password='<complex-password>'  (PowerShell)

# Set your own subscription ID (or use the ARM_SUBSCRIPTION_ID env var).
# The chosen region must be permitted by that subscription's Azure Policy.
subscription_id = "<your-azure-subscription-id>"

location       = "francecentral"
prefix         = "soc"
vm_size        = "Standard_B2ats_v2"
admin_username = "socadmin"
