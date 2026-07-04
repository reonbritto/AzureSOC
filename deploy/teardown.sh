#!/usr/bin/env bash
#
# teardown.sh
# Destroy the honeynet VMs + network and stop billing / close the exposure.
#
# `terraform destroy` removes the resource group and everything Terraform
# manages (VMs, NICs, public IPs, VNet/subnet, NSG). Any monitoring stack you
# created manually per NEXT-STEPS.md (Log Analytics workspace, Sentinel content,
# Defender plans) is NOT managed by Terraform — tear those down separately.
#
# Auth: uses the active `az login` session.
# Usage:
#   ./teardown.sh                # prompts for confirmation
#   ./teardown.sh --yes          # no prompt (CI)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

AUTO=""
[ "${1:-}" = "--yes" ] && AUTO="-auto-approve"

# admin_password is a required var even for destroy; a dummy satisfies the
# parser (no VM is created/changed during destroy).
export TF_VAR_admin_password="${TF_VAR_admin_password:-Teardown0nly!Dummy#2026}"

echo ">> This will DESTROY the honeynet VMs and network (resource group rg-soc-honeynet)."
echo ">> Subscription: $(az account show --query name -o tsv) ($(az account show --query id -o tsv))"
echo

terraform destroy ${AUTO}

echo
echo ">> Teardown complete. Verify with:  az group show -n rg-soc-honeynet   (expect NotFound)"
