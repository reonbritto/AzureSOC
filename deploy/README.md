# SOC + Honeynet — VM Deployment (Terraform)

This Terraform provisions **only the honeynet VMs and the network they need**.
The monitoring/SOC stack (Log Analytics, Sentinel, agents, watchlist, analytics
rules, workbooks, Defender, hardening) is set up afterward — see the
step-by-step guide in [docs/NEXT-STEPS.md](../docs/NEXT-STEPS.md).

## What Terraform deploys (15 resources)

| Area    | Resources |
| ------- | --------- |
| Network | Resource group, VNet, subnet, NSG (**default-deny inbound**), subnet assoc. |
| Compute | 2× Windows Server 2022 + 1× Ubuntu 22.04 (`Standard_B2ats_v2`, France Central), 3 NICs, 3 public IPs |

> The NSG ships **locked down** — VMs are deployed but not reachable from the
> Internet until you deliberately add allow rules (Step 6 in the guide).

## Prerequisites

- Azure CLI (`az login` already done) and Terraform ≥ 1.5.
- Providers registered: Network, Compute (confirmed on the target subscription).

## Deploy

```bash
cd deploy

# 1. VM admin password — never committed. Set it in the environment.
export TF_VAR_admin_password='<a complex 12+ char password>'   # Git Bash
#  $env:TF_VAR_admin_password='<...>'                          # PowerShell

# 2. Deploy
terraform init
terraform plan -out tf.plan      # expect: 15 to add
terraform apply tf.plan

# 3. See the VM IPs
terraform output
```

Then follow [docs/NEXT-STEPS.md](../docs/NEXT-STEPS.md) to build the SOC on top.

## Tear down (stops VM billing, closes exposure)

```bash
cd deploy
./teardown.sh            # prompts; or ./teardown.sh --yes
```

`terraform destroy` removes the VMs and network. Any monitoring you set up
manually per the guide is not managed here — remove it separately.

## Cost & safety notes

- 3× `B2ats_v2` VMs accrue compute cost while running. Tear down when done.
- A honeynet is a *deliberate* live-attack exposure once you open the NSG. Never
  put real data or credentials on these VMs.
- `terraform.tfstate*` may contain the VM password — keep it out of version control.
