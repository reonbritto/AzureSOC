# Next Steps — Building the SOC on top of the Terraform VMs

Terraform (in [`../deploy`](../deploy)) provisions **only the VMs and their
network**. This guide walks through everything after that to turn them into a
working SOC + honeynet: telemetry pipeline → Microsoft Sentinel → attack maps →
run the lab → (later) Defender + hardening.

Every step gives **two ways** to do it — pick whichever you prefer, per step:
- **Option A — Portal**: click-through in the Azure Portal ([portal.azure.com](https://portal.azure.com)). Best for learning and for the parts that are fiddly on the CLI.
- **Option B — Azure CLI**: copy-pasteable `az` commands (Git Bash or PowerShell). Best for speed and reproducibility.

You can mix and match freely — e.g. create the workspace in the Portal, then run the import script from the CLI.

**Assumed names** (from the Terraform defaults; change if you changed `prefix`):

| Thing               | Name                     |
| ------------------- | ------------------------ |
| Subscription        | Azure for Students       |
| Resource group      | `rg-soc-honeynet`        |
| Region              | France Central           |
| VNet / subnet       | `vnet-soc-honeynet` / `snet-soc-honeynet` |
| NSG                 | `nsg-soc-honeynet`       |
| Windows VMs         | `vm-soc-win-1`, `vm-soc-win-2` |
| Linux VM            | `vm-soc-linux`           |
| Workspace (created below) | `law-soc-honeynet` |

```bash
# CLI users: set these once for the session (Git Bash).
# PowerShell:  $env:RG="rg-soc-honeynet"  etc.
export RG="rg-soc-honeynet"
export LOCATION="francecentral"
export WS="law-soc-honeynet"
```

> **Portal users:** make sure the correct subscription is selected. Top-right
> **Settings (gear) → Directories + subscriptions**, or use the **Subscription**
> filter on each blade, and pick **Azure for Students**.

---

## Step 0 — Deploy the VMs (if not done)

**Option B — Azure CLI / Terraform** (this step is Terraform-only):
```bash
cd deploy
export TF_VAR_admin_password='<your complex 12+ char password>'   # never commit this
terraform init
terraform apply           # 15 resources
terraform output          # note the VM public IPs
```

> There is no Portal option here — the VMs are defined in Terraform. You *can*
> confirm them in the Portal afterward: **Resource groups → `rg-soc-honeynet`**
> should list 2 Windows + 1 Linux VM and their network resources.

---

## Step 1 — Create the Log Analytics workspace

The workspace is the log store everything feeds into and the home for Sentinel.

**Option A — Portal:**
1. Portal search bar → **Log Analytics workspaces** → **+ Create**.
2. **Basics** tab:
   - **Subscription**: Azure for Students
   - **Resource group**: `rg-soc-honeynet`
   - **Name**: `law-soc-honeynet`
   - **Region**: France Central
3. **Review + Create** → **Create**. (Retention defaults to 30 days on the
   pay-as-you-go tier, which is fine.)

**Option B — Azure CLI:**
```bash
az monitor log-analytics workspace create \
  --resource-group "$RG" \
  --workspace-name "$WS" \
  --location "$LOCATION" \
  --retention-time 30
```

---

## Step 2 — Enable Microsoft Sentinel on the workspace

**Option A — Portal:**
1. Portal search bar → **Microsoft Sentinel** → **+ Create**.
2. Select the workspace **`law-soc-honeynet`** from the list → **Add**.
3. Sentinel opens on that workspace. (First-time enablement can take a minute.)

**Option B — Azure CLI:**
```bash
# The az sentinel extension installs on first use — approve the prompt.
az sentinel onboarding-state create \
  --resource-group "$RG" \
  --workspace-name "$WS" \
  --name "default"
```

---

## Step 3 — Install Azure Monitor Agent (AMA) + Data Collection Rules

This is what makes `SecurityEvent` (Windows) and `Syslog` (Linux) flow. AMA is
driven by **Data Collection Rules (DCRs)** — a DCR says *what* to collect, and
associating it with a VM installs/points the agent automatically.

### Option A — Portal

> **Important — Windows must go through the Sentinel connector, not a plain DCR.**
> The generic Monitor → Data Collection Rules editor only offers a **"Windows
> Event Logs"** data source, which sends events on the `Microsoft-Event` stream —
> they land in the generic **`Event`** table, NOT `SecurityEvent`. The RDP attack
> map and the analytics rules query `SecurityEvent`, so they'd see nothing. Use
> the Sentinel **Windows Security Events via AMA** connector, which builds a DCR
> that targets the `SecurityEvent` table.

**Windows → SecurityEvent (via the Sentinel connector):**
1. **Microsoft Sentinel** (workspace `law-soc-honeynet`) → **Content management →
   Content hub** → search **Windows Security Events** → **Install**.
2. **Configuration → Data connectors** → **Windows Security Events via AMA** →
   **Open connector page**.
3. **+ Create data collection rule**:
   - Name: `dcr-soc-securityevents`
   - **Resources**: add `vm-soc-win-1` and `vm-soc-win-2` (this installs AMA on them)
   - **Collect**: **All Security Events** (or "Common" to trim volume — All
     guarantees `4625` failed logons and `18456` MSSQL failures)
   - Create.

**Linux → Syslog (plain DCR editor is fine here):**
1. Portal search bar → **Monitor** → **Data Collection Rules** → **+ Create**.
2. **Basics**: Name `dcr-soc-linux`, Subscription Azure for Students, RG
   `rg-soc-honeynet`, Region France Central, Platform Type **Linux**.
3. **Resources** → **+ Add resources** → tick `vm-soc-linux` (installs AMA).
4. **Collect and deliver** → **+ Add data source** → type **Linux Syslog** → set
   facilities **auth** and **authpriv** to at least **LOG_INFO** (so
   `Failed password for` lines are captured) → **Destination**: **Azure Monitor
   Logs** → workspace `law-soc-honeynet`.
5. **Review + Create** → **Create**.

### Option B — Azure CLI

First create the two rule files.

`dcr-windows.json` — collect all Windows Security events (gets `4625` RDP fails, `18456` MSSQL fails):
```json
{
  "location": "francecentral",
  "properties": {
    "dataSources": {
      "windowsEventLogs": [
        {
          "name": "securityEvents",
          "streams": ["Microsoft-SecurityEvent"],
          "xPathQueries": ["Security!*"]
        }
      ]
    },
    "destinations": {
      "logAnalytics": [
        { "name": "law-dest", "workspaceResourceId": "<WORKSPACE_RESOURCE_ID>" }
      ]
    },
    "dataFlows": [
      { "streams": ["Microsoft-SecurityEvent"], "destinations": ["law-dest"] }
    ]
  }
}
```

`dcr-linux.json` — collect auth syslog (gets "Failed password for" SSH fails):
```json
{
  "location": "francecentral",
  "properties": {
    "dataSources": {
      "syslog": [
        {
          "name": "authLogs",
          "streams": ["Microsoft-Syslog"],
          "facilityNames": ["auth", "authpriv"],
          "logLevels": ["Debug","Info","Notice","Warning","Error","Critical","Alert","Emergency"]
        }
      ]
    },
    "destinations": {
      "logAnalytics": [
        { "name": "law-dest", "workspaceResourceId": "<WORKSPACE_RESOURCE_ID>" }
      ]
    },
    "dataFlows": [
      { "streams": ["Microsoft-Syslog"], "destinations": ["law-dest"] }
    ]
  }
}
```

Then create the DCRs and associate them (this triggers AMA install + collection):
```bash
WORKSPACE_RESOURCE_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --query id -o tsv)

sed -i "s#<WORKSPACE_RESOURCE_ID>#${WORKSPACE_RESOURCE_ID}#g" dcr-windows.json dcr-linux.json

az monitor data-collection rule create -g "$RG" -n "dcr-soc-windows" --location "$LOCATION" --rule-file dcr-windows.json
az monitor data-collection rule create -g "$RG" -n "dcr-soc-linux"   --location "$LOCATION" --rule-file dcr-linux.json

WIN_DCR=$(az monitor data-collection rule show -g "$RG" -n "dcr-soc-windows" --query id -o tsv)
LIN_DCR=$(az monitor data-collection rule show -g "$RG" -n "dcr-soc-linux"   --query id -o tsv)

for vm in vm-soc-win-1 vm-soc-win-2; do
  VM_ID=$(az vm show -g "$RG" -n "$vm" --query id -o tsv)
  az monitor data-collection rule association create \
    --name "dcra-$vm" --rule-id "$WIN_DCR" --resource "$VM_ID"
done

VM_ID=$(az vm show -g "$RG" -n "vm-soc-linux" --query id -o tsv)
az monitor data-collection rule association create \
  --name "dcra-vm-soc-linux" --rule-id "$LIN_DCR" --resource "$VM_ID"
```

### Verify (either option)

Give it 10–30 min, then confirm data lands.

- **Portal**: workspace / Sentinel → **Logs** → run `SecurityEvent | take 5` and
  `Syslog | take 5`.
- **CLI**:
  ```bash
  az monitor log-analytics query -w "$WS" --analytics-query "SecurityEvent | take 5"
  az monitor log-analytics query -w "$WS" --analytics-query "Syslog | take 5"
  ```

---

## Step 4 — Import the Sentinel content (watchlist + rules + workbook)

Three pieces: the **`geoip` watchlist** (54,803-row GeoIP CSV the maps join on),
the **13 scheduled analytics rules**, and the **attack-map workbook**.

Do all three in the Portal:

1. **Watchlist**: Sentinel → **Configuration → Watchlists → + Add new**.
   - Name/Alias: **`geoip`** (the alias must be exactly `geoip` — the map queries
     call `_GetWatchlist("geoip")`).
   - Upload `azure-soc-honeynet-main/geoip-summarized.csv`.
   - **SearchKey**: `network`. Create. (The large CSV takes a few minutes.)
2. **Analytics rules**: the 13 rules ship as an ARM template. Search **Deploy a
   custom template** → **Build your own template in the editor** → **Load file** →
   `azure-soc-honeynet-main/Sentinel-Analytics-Rules(KQL Alert Queries).json` →
   set the **workspace** parameter to `law-soc-honeynet` → **Review + Create**.
3. **Workbook**: the four attack maps are already merged into one workbook at
   `azure-soc-honeynet-main/attack-maps-workbook.json`. Sentinel → **Threat
   management → Workbooks → + Add workbook** → **Edit** → **</> Advanced Editor**
   → replace the contents with that file's `serializedData` (or paste the whole
   workbook body) → **Apply** → **Save**.

   > CLI alternative for the rules: `az deployment group create -g rg-soc-honeynet -f "azure-soc-honeynet-main/Sentinel-Analytics-Rules(KQL Alert Queries).json" -p workspace=law-soc-honeynet`

### Verify (either option)

Sentinel → **Watchlists** shows `geoip`; **Analytics** shows 13 rules;
**Workbooks** shows "SOC Honeynet - Attack Maps".

---

## Step 5 — (Optional) SQL Server for the MSSQL attack map

The MSSQL map queries `Event | where EventLog == "Application" | where EventID == 18456`
— a **SQL Server login failure**. That event only exists if **all** of these are
true: SQL Server is installed, it's in **mixed authentication mode** (so SQL
logins *can* fail), and the **Application** event log is being shipped to the
workspace. Miss any one and the map stays empty. Skip this whole step if you
don't need the MSSQL map — SSH and RDP work without it.

### 5a. RDP into the Windows VM
- Portal → `vm-soc-win-1` → **Connect → RDP → Download RDP File** → open it, log
  in as `socadmin` + your VM password. (Needs port 3389, which is open after
  Step 6.)

### 5b. Install SQL Server Express + SSMS
Inside the VM (use its Edge browser):
- Download **SQL Server 2022 Express** from Microsoft's SQL downloads → run →
  **Basic** install.
- Download + install **SSMS** (SQL Server Management Studio).

### 5c. Enable Mixed Mode auth (this is what enables 18456)
1. Open **SSMS**, connect to `localhost\SQLEXPRESS`.
2. Right-click the server (top of Object Explorer) → **Properties → Security**.
3. Under **Server authentication**, pick **SQL Server and Windows Authentication
   mode** → **OK**.
4. Restart the instance: right-click server → **Restart** (or Services → **SQL
   Server (SQLEXPRESS)** → Restart). Failed-login auditing is on by default in
   mixed mode — SQL writes `18456` to the Application log automatically.

### 5d. Ship the Application log to the workspace (easy to miss)
The Sentinel "Windows Security Events via AMA" connector from Step 3 collects the
**Security** channel only — **not** the **Application** channel where `18456`
lands. Add an Application-log data source:
- Portal → **Monitor → Data Collection Rules** → `dcr-soc` (or create
  `dcr-soc-appevents`) → **Data sources → + Add** → type **Windows Event Logs** →
  tick the **Application** log (Information/Warning/Error) → destination workspace
  `law-soc-honeynet`.
- Application events land in the **`Event`** table (not `SecurityEvent`) — which
  is exactly where the MSSQL map query looks. So "Windows Event Logs" is the
  *correct* source type here (unlike for Security events).

### 5e. Generate a failure and verify
1. In SSMS, disconnect → reconnect using **SQL Server Authentication** with a
   bogus username/password → it fails (that's the point).
2. Wait 5–15 min, then in **Logs**: `Event | where EventID == 18456 | take 20`.
3. Once rows appear, the MSSQL map tile plots pins. Real attackers probing the
   open port 1433 will generate `18456` on their own too.

---

## Step 6 — Open the honeynet (start the "insecure" window)

Up to now the NSG denies all inbound. Opening it is the honeynet going live —
**this exposes the VMs to live attack traffic**. Record the start time.

**Option A — Portal:**
1. **Resource groups → `rg-soc-honeynet` → `nsg-soc-honeynet`**.
2. **Settings → Inbound security rules → + Add**.
3. Source **Any** (or `Internet`), Destination **Any**, Service **Custom**,
   Destination port ranges `3389,22,1433`, Protocol **TCP**, Action **Allow**,
   Priority `110`, Name `ALLOW-RDP-SSH-MSSQL` → **Add**.

**Option B — Azure CLI:**
```bash
az network nsg rule create -g "$RG" --nsg-name "nsg-soc-honeynet" \
  -n "ALLOW-RDP-SSH-MSSQL" --priority 110 --direction Inbound --access Allow \
  --protocol Tcp --source-address-prefixes Internet \
  --destination-port-ranges 3389 22 1433
```

Let it run ~24 hours. Attackers find open ports within minutes to hours.

---

## Step 7 — Measure the "before" metrics

**Option A — Portal:** Sentinel (or the workspace) → **Logs**, run each query and
note the count. Open the **Attack Maps** workbook to see pins worldwide as the
GeoIP join resolves attacker IPs.

**Option B — Azure CLI:**
```bash
for q in \
  "SecurityEvent | where TimeGenerated >= ago(24h) | count" \
  "Syslog | where TimeGenerated >= ago(24h) | count" \
  "SecurityAlert | where TimeGenerated >= ago(24h) | count" \
  "SecurityIncident | where TimeGenerated >= ago(24h) | count" ; do
  echo "== $q"; az monitor log-analytics query -w "$WS" --analytics-query "$q" -o table
done
```

Screenshot the incident queue and maps for the portfolio.

---

## Step 8 — (LATER) Enable Microsoft Defender for Cloud

> Deferred for now. When ready, this adds behavioral attack alerts
> (`SecurityAlert`), Just-in-Time VM access, and the Secure Score that drives
> hardening. **Defender for Servers Plan 2 is billed per server-hour.**

**Option A — Portal:**
1. Portal search → **Microsoft Defender for Cloud** → **Environment settings**.
2. Select the subscription → toggle **Servers** **On** → **Change plan** →
   **Plan 2** → **Save**.
3. **Environment settings → Email notifications**: add your email, enable alert
   notifications.

**Option B — Azure CLI:**
```bash
az security pricing create -n VirtualMachines --tier Standard --subplan P2
az security contact create -n default --email "you@example.com" \
  --alert-notifications On --alerts-to-admins On
```

---

## Step 9 — Harden, then measure "after"

The hardening is what drives the 90%+ incident reduction:

1. **Just-in-Time VM access** (needs Defender, Step 8) — Portal: **Defender for
   Cloud → Workload protections → Just-in-time VM access** → enable for the 3 VMs.
   Ports are then closed by default and opened only on time-boxed request.
2. **Lock the NSG back down** — delete the allow rule from Step 6:
   - **Portal**: `nsg-soc-honeynet` → Inbound rules → delete `ALLOW-RDP-SSH-MSSQL`.
   - **CLI**:
     ```bash
     az network nsg rule delete -g "$RG" --nsg-name "nsg-soc-honeynet" -n "ALLOW-RDP-SSH-MSSQL"
     ```
3. Work the **Defender recommendations / Secure Score** (management-port lockdown,
   disk encryption, MFA).
4. Collect metrics for another ~24h and fill the before/after table in the
   project README.

The detailed analyst triage workflow (investigate an incident, pivot to the
maps, respond) is in [SOC-WALKTHROUGH.md](SOC-WALKTHROUGH.md).

---

## Step 10 — Tear down (stop billing, close exposure)

**Option B — Terraform** (removes exactly what Terraform made — VMs + network):
```bash
cd deploy
export TF_VAR_admin_password='<any value — required by the parser>'
terraform destroy

# If you enabled Defender (Step 8), revert it separately:
az security pricing create -n VirtualMachines --tier Free
```

**Option A — Portal** (deletes everything in one shot): **Resource groups →
`rg-soc-honeynet` → Delete resource group**. This also removes the Log Analytics
workspace and its Sentinel content, since they live in the same RG.

> Note: if you delete via the Portal, your Terraform state will still think the
> resources exist. Run `terraform state rm` / `terraform apply` to reconcile, or
> just prefer `terraform destroy`.
