# Playbook — Ban Attacker IP (manual response to a brute-force incident)

A Sentinel **playbook** (Azure Logic App) that you run **manually from a
brute-force incident**. It reads the attacker IP from the incident's entities and
adds it to a single managed **deny rule** on `nsg-soc-honeynet`, blocking that IP
across all three VMs. It then posts a comment back on the incident.

Files: [`../azure-soc-honeynet-main/playbook-ban-ip.json`](../azure-soc-honeynet-main/playbook-ban-ip.json) (the Logic App ARM template).

## How it works

```
Analyst clicks "Run playbook" on an incident
   → playbook receives the incident's IP entities
   → for each IP: read NSG → merge IP into DENY-BRUTEFORCE-IPS rule (priority 100)
   → NSG denies that source; comment added to the incident
```

The playbook maintains **one** deny rule (`DENY-BRUTEFORCE-IPS`, priority 100 —
beats the `ALLOW-RDP-SSH-MSSQL` rule at 110) and appends each banned IP to its
`sourceAddressPrefixes` list. This scales far better than one rule per IP.

---

## Prerequisite 1 — Map the attacker IP as an entity on the rules (REQUIRED)

**This is mandatory.** As imported, the 14 analytics rules have **zero entity
mappings**, so their incidents carry no IP for the playbook to act on. You must
add an IP entity mapping to each brute-force rule. Both brute-force queries expose
the attacker IP in a column named **`AttackerIP`**.

For each of these rules (Sentinel → **Analytics** → open rule → **Edit** → **Set
rule logic** tab → **Entity mapping**):
- **CUSTOM: Brute Force ATTEMPT - Windows**
- **CUSTOM: Brute Force ATTEMPT - Linux Syslog**
- **CUSTOM: Brute Force ATTEMPT - MS SQL Server** (uses `AttackerIP` too)
- (optionally the **SUCCESS** variants)

Add mapping:
- **Entity type**: `IP`
- **Identifier**: `Address`
- **Value**: `AttackerIP`

Save. New incidents from these rules will now include the IP as an entity.
(Existing incidents created before the mapping won't have it — trigger a fresh one.)

---

## Prerequisite 2 — Deploy the playbook

**Portal (custom template):** search **Deploy a custom template** → **Build your
own template in the editor** → **Load file** →
`azure-soc-honeynet-main/playbook-ban-ip.json` → set parameters (defaults already
target `nsg-soc-honeynet`) → **Review + Create**.

**CLI:**
```bash
az deployment group create \
  --resource-group rg-soc-honeynet \
  --name deploy-ban-ip-playbook \
  --template-file azure-soc-honeynet-main/playbook-ban-ip.json
```

The template creates the Logic App (with a system-assigned managed identity) plus
the Microsoft Sentinel API connection.

---

## Prerequisite 3 — Authorize the API connection + grant NSG permission

1. **Authorize the Sentinel connection** (one-time): Portal → the resource
   `azuresentinel-SOC-Ban-AttackerIP` (API Connection) → **Edit API connection**
   → **Authorize** → sign in → **Save**. (Managed-identity connections may skip
   this; if the playbook errors on the connection, authorize here.)

2. **Grant the playbook's managed identity rights on the NSG** so it can add the
   deny rule. The deployment output `playbookPrincipalId` is the identity's object
   ID:
   ```bash
   PID=$(az deployment group show -g rg-soc-honeynet -n deploy-ban-ip-playbook \
     --query properties.outputs.playbookPrincipalId.value -o tsv)

   NSG_ID=$(az network nsg show -g rg-soc-honeynet -n nsg-soc-honeynet --query id -o tsv)

   az role assignment create \
     --assignee-object-id "$PID" \
     --assignee-principal-type ServicePrincipal \
     --role "Network Contributor" \
     --scope "$NSG_ID"
   ```
   (Least privilege: scope the role to the NSG only, not the whole RG.)

---

## Run it manually on an incident

1. Sentinel → **Incidents** → open a brute-force incident (confirm it has an **IP**
   entity — see Prerequisite 1).
2. **Actions → Run playbook** (or the "Run playbook" button on the incident).
3. Pick **SOC-Ban-AttackerIP** → **Run**.
4. The playbook adds/updates `DENY-BRUTEFORCE-IPS` on the NSG and posts a comment
   on the incident naming the IP it banned.

Verify:
```bash
az network nsg rule show -g rg-soc-honeynet --nsg-name nsg-soc-honeynet \
  -n DENY-BRUTEFORCE-IPS --query "{prio:priority, access:access, ips:sourceAddressPrefixes}" -o json
```

## Notes / gotchas
- **Deny beats allow** because `DENY-BRUTEFORCE-IPS` is priority 100 vs the allow
  at 110 (lower number = evaluated first).
- **Existing incidents** created before the entity mapping have no IP entity —
  the playbook will find nothing to ban. Use an incident created *after* mapping.
- **Unban**: remove an IP from the rule's `sourceAddressPrefixes`, or delete the
  rule entirely (`az network nsg rule delete ... -n DENY-BRUTEFORCE-IPS`).
- **Teardown**: the playbook + connection live in `rg-soc-honeynet`, but
  `terraform destroy` only manages the VMs/network — it will NOT remove them.
  Delete the playbook and API connection manually (or `az resource delete`), or
  delete the whole resource group in the Portal to remove everything at once.
