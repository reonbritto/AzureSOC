# SOC Walkthrough — Detecting & Responding to Attacks with Defender + Sentinel

This is the operational runbook for the honeynet: how a SOC analyst detects,
triages, investigates, and remediates the live attack traffic the lab attracts,
and how that produces the "before vs. after hardening" metrics.

It assumes the infrastructure is deployed (`deploy/` Terraform applied), the
Sentinel content is imported (`deploy/import-sentinel-content.sh`), Microsoft
Defender for Cloud (Servers Plan 2) is enabled, and the NSG has been opened to
the Internet to begin the "insecure" measurement window.

---

## 0. The detection pipeline (how data flows)

```
Attacker (Internet)
   │  RDP / SSH / MSSQL brute force
   ▼
Honeynet VMs ──AMA + DCR──► Log Analytics ──► tables: SecurityEvent, Syslog
   │                                              │
   │  (Defender for Servers / MDE)                ├─► Sentinel analytics rules ─► SecurityAlert ─► SecurityIncident
   ▼                                              │
Defender for Cloud ── Security alerts ────────────┘     └─► Attack-map workbook (GeoIP join via "geoip" watchlist)
```

Two complementary alert sources:
- **Microsoft Defender for Cloud** raises behavioral alerts (brute-force detected,
  suspicious process, etc.) → surfaced in **Defender → Security alerts** and the
  `SecurityAlert` table.
- **Microsoft Sentinel analytics rules** (the 13 imported scheduled rules) match
  raw log patterns (e.g. `SecurityEvent` EventID `4625`, Syslog `Failed password
  for`, `Event` EventID `18456`) → `SecurityAlert` → grouped into `SecurityIncident`.

Both land in the same workspace, so the analyst works a single incident queue.

---

## 1. Where alerts land

1. **Defender for Cloud → Security alerts** — start-of-shift triage. Filter by
   severity; brute-force and reconnaissance alerts dominate a honeynet.
2. **Microsoft Sentinel → Incidents** — the analytics rules group related alerts
   into incidents with severity, status, owner, and an entity list.
3. **Defender for Cloud → Recommendations / Secure Score** — the standing posture
   view; the remediation backlog for Phase C hardening.

---

## 2. Triage an incident

Open a brute-force incident in **Sentinel → Incidents** (e.g. one raised by the
RDP `4625`, SSH `Failed password`, or MSSQL `18456` rules):

1. Read the **summary**: which rule fired, how many alerts grouped, severity.
2. Read the **entities**: attacker source IP, target VM/host, the account names
   being sprayed (e.g. `administrator`, `admin`, `sa`, `root`).
3. Pivot to the **Attack-map workbook** ("SOC Honeynet - Attack Maps") — the
   GeoIP `ipv4_lookup` join against the `geoip` watchlist plots the source
   country/city. Expect a global spread of opportunistic scanners.
4. Decide **true positive vs. false positive**. On a honeynet, inbound auth
   failures from random Internet IPs are true-positive attack traffic by design.

---

## 3. Investigate (scope the activity)

Use Defender's **investigation graph** (from a Defender alert) and KQL hunting in
**Logs**. The same queries that power the maps are the hunting queries — examples:

Top attacking source IPs against the Linux VM:
```kql
Syslog
| where Facility == "auth" and SyslogMessage startswith "Failed password for"
| extend SourceIP = extract(@"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", 0, SyslogMessage)
| summarize Attempts = count() by SourceIP
| top 20 by Attempts desc
```

RDP failed-logon volume against the Windows VMs:
```kql
SecurityEvent
| where EventID == 4625
| summarize Attempts = count() by IpAddress, Account, Computer
| top 20 by Attempts desc
```

Resolve a source IP to geography (same watchlist join the maps use):
```kql
let GeoIPDB_FULL = _GetWatchlist("geoip");
SecurityEvent
| where EventID == 4625
| evaluate ipv4_lookup(GeoIPDB_FULL, IpAddress, network)
| project TimeGenerated, IpAddress, Account, Computer, cityname, countryname
```

Scope: which VMs are targeted, which accounts, what time window, and whether any
attempt *succeeded* (a `4624` after a burst of `4625`, or an `Accepted password`
in Syslog) — that would escalate from brute-force-attempt to compromise.

---

## 4. Respond / remediate (the hardening that drives the reduction)

This is the "after hardening" half of the metrics. Apply controls and record the
new 24-hour counts.

1. **Just-in-Time (JIT) VM access** (Defender for Servers Plan 2): close RDP/SSH
   by default; open only on approved, time-boxed, source-restricted request. This
   is the single biggest driver of the incident reduction — the management ports
   stop being Internet-reachable.
   - Defender for Cloud → **Workload protections → Just-in-time VM access** → enable
     for the three VMs.
2. **NSG lockdown**: revert the inbound allow rules to the default-deny state
   (`network.tf` ships locked down); allow management ports only from your admin
   IP if needed.
3. **Work the Defender recommendations / Secure Score**: management-port lockdown,
   disk encryption, MFA, endpoint protection — each closed item raises the score.
4. **Windows tamper detection**: collect the `Xpath.txt` events (Defender malware
   `1116/1117`, Firewall tampering `2003`) so defensive-control tampering is
   itself alertable.
5. **Close the incident** in Sentinel as **True Positive** with a classification
   note; assign yourself as owner for the audit trail.

---

## 5. Measure (before vs. after)

Run the README count queries over each 24-hour window and fill the table. Example
("last 24h" forms — anchor to your real start/stop times for the report):

```kql
SecurityEvent | where TimeGenerated >= ago(24h) | count
Syslog         | where TimeGenerated >= ago(24h) | count
SecurityAlert  | where DisplayName !startswith "CUSTOM" and DisplayName !startswith "TEST" | where TimeGenerated >= ago(24h) | count
SecurityIncident | where TimeGenerated >= ago(24h) | count
AzureNetworkAnalytics_CL | where FlowType_s == "MaliciousFlow" and AllowedInFlows_d > 0 | where TimeGenerated >= ago(24h) | count
```

| Metric                   | Before (insecure) | After (hardened) |
| ------------------------ | ----------------- | ---------------- |
| SecurityEvent            | _fill_            | _fill_           |
| Syslog                   | _fill_            | _fill_           |
| SecurityAlert            | _fill_            | _fill_           |
| SecurityIncident         | _fill_            | _fill_           |
| AzureNetworkAnalytics_CL | _fill_ (note*)    | _fill_ (note*)   |

\* `AzureNetworkAnalytics_CL` depends on Traffic Analytics over NSG Flow Logs,
which Azure is retiring (migrating to VNet Flow Logs). If the table is empty,
note it as a known limitation rather than a measurement of zero attacks — the
other four metrics tell the story.

The expected result mirrors the original lab: a large drop in events, and alerts
/ incidents / malicious flows falling to near zero once JIT + NSG lockdown remove
the Internet-facing attack surface.

---

## 6. Capture for the portfolio

- Screenshot the **incident queue** (populated, before) and the **attack maps**
  (pins worldwide, before) vs. **no results** (after).
- Screenshot the **Secure Score** before and after working the recommendations.
- Paste your real before/after table into the project `README.md`.

> Reminder: tear the environment down when finished — `deploy/teardown.sh` — to
> stop billing and close the exposure.
