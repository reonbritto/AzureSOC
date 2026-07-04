#!/usr/bin/env bash
#
# import-sentinel-content.sh
# Post-`terraform apply` step: load the repo's Sentinel content into the
# deployed workspace.
#   1. GeoIP watchlist  (alias "geoip", searchKey "network") from the bulk CSV
#   2. 13 scheduled analytics rules (the repo's ARM template)
#   3. Attack-map workbook (assembled from the four query-item JSONs)
#
# Auth: uses the active `az login` session.
# Deps: az CLI + python3 (no jq required).
#
# The Log Analytics workspace + Sentinel are created manually in NEXT-STEPS.md
# (they are no longer part of Terraform). Pass their names via env vars:
# Usage:
#   RG=rg-soc-honeynet WS=<your-workspace-name> ./import-sentinel-content.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC_DIR="${REPO_ROOT}/azure-soc-honeynet-main"

PY="$(command -v python3 || command -v python)"
[ -n "${PY}" ] || { echo "ERROR: python3/python not found"; exit 1; }

RG="${RG:-rg-soc-honeynet}"
WS="${WS:?ERROR: set WS=<Log Analytics workspace name> (created in NEXT-STEPS.md) before running}"
SUB="$(az account show --query id -o tsv)"
LOCATION="$(az group show -n "${RG}" --query location -o tsv)"

API_WATCHLIST="2023-02-01"
API_WORKBOOK="2023-06-01"
WS_BASE="https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.OperationalInsights/workspaces/${WS}/providers/Microsoft.SecurityInsights"
WS_RESOURCE_ID="/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.OperationalInsights/workspaces/${WS}"

echo ">> Subscription : ${SUB}"
echo ">> Resource grp : ${RG}"
echo ">> Workspace    : ${WS}"
echo

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# 1. GeoIP watchlist — bulk CSV embedded in a single PUT via rawContent.
# ---------------------------------------------------------------------------
echo ">> [1/3] Creating 'geoip' watchlist from geoip-summarized.csv ..."
CSV_FILE="${SRC_DIR}/geoip-summarized.csv"
[ -f "${CSV_FILE}" ] || { echo "ERROR: ${CSV_FILE} not found"; exit 1; }

WL_BODY="${TMP_DIR}/watchlist.json"
"${PY}" - "${CSV_FILE}" "${WL_BODY}" <<'PY'
import json, sys
csv_path, out_path = sys.argv[1], sys.argv[2]
with open(csv_path, "r", encoding="utf-8") as f:
    raw = f.read()
body = {
    "properties": {
        "displayName": "geoip",
        "source": "geoip-summarized.csv",
        "provider": "azure-soc-honeynet",
        "itemsSearchKey": "network",
        "contentType": "text/csv",
        "numberOfLinesToSkip": 0,
        "rawContent": raw,
    }
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(body, f)
PY

az rest --method put \
  --url "${WS_BASE}/watchlists/geoip?api-version=${API_WATCHLIST}" \
  --headers "Content-Type=application/json" \
  --body "@${WL_BODY}" \
  --output none
echo "   watchlist 'geoip' submitted (large CSV ingests asynchronously; allow a few minutes)."
echo

# ---------------------------------------------------------------------------
# 2. Analytics rules — deploy the repo's ARM template (13 scheduled rules).
# ---------------------------------------------------------------------------
echo ">> [2/3] Deploying 13 Sentinel analytics rules ..."
RULES_FILE="${SRC_DIR}/Sentinel-Analytics-Rules(KQL Alert Queries).json"
[ -f "${RULES_FILE}" ] || { echo "ERROR: rules template not found"; exit 1; }

az deployment group create \
  --resource-group "${RG}" \
  --name "soc-sentinel-rules" \
  --template-file "${RULES_FILE}" \
  --parameters workspace="${WS}" \
  --output none
echo "   13 analytics rules deployed."
echo

# ---------------------------------------------------------------------------
# 3. Attack-map workbook — assemble the four query-item JSONs into one
#    Sentinel workbook and create it under Microsoft.Insights/workbooks.
# ---------------------------------------------------------------------------
echo ">> [3/3] Creating the attack-map workbook ..."
WB_BODY="${TMP_DIR}/workbook.json"
WB_NAME="$("${PY}" -c 'import uuid;print(uuid.uuid4())')"

"${PY}" - "${SRC_DIR}" "${LOCATION}" "${WS_RESOURCE_ID}" "${WB_BODY}" <<'PY'
import json, sys
src, location, ws_id, out_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def load(name):
    with open(f"{src}/{name}", "r", encoding="utf-8") as f:
        return json.load(f)

linux = load("linux-ssh-auth-fail.json")
rdp   = load("windows-rdp-auth-fail.json")
mssql = load("mssql-auth-fail.json")
nsg   = load("nsg-malicious-allowed-in.json")

def named(item, name):
    item = dict(item)
    item["name"] = name
    return item

workbook = {
    "version": "Notebook/1.0",
    "items": [
        {"type": 1, "content": {"json": "# SOC Honeynet - Attack Maps\nGeoIP-resolved attack origins across SSH, RDP, MSSQL, and malicious NSG flows."}, "name": "title"},
        {"type": 1, "content": {"json": "## Linux SSH - Failed Password"}, "name": "h-linux"},
        named(linux, "map-linux"),
        {"type": 1, "content": {"json": "## Windows RDP - Failed Logon (4625)"}, "name": "h-rdp"},
        named(rdp, "map-rdp"),
        {"type": 1, "content": {"json": "## MSSQL - Brute Force (18456)"}, "name": "h-mssql"},
        named(mssql, "map-mssql"),
        {"type": 1, "content": {"json": "## NSG - Malicious Inbound Flows Allowed"}, "name": "h-nsg"},
        named(nsg, "map-nsg"),
    ],
    "$schema": "https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json",
}

body = {
    "location": location,
    "kind": "shared",
    "properties": {
        "displayName": "SOC Honeynet - Attack Maps",
        "serializedData": json.dumps(workbook),
        "category": "sentinel",
        "sourceId": ws_id,
        "version": "Notebook/1.0",
    },
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(body, f)
PY

az rest --method put \
  --url "https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/providers/Microsoft.Insights/workbooks/${WB_NAME}?api-version=${API_WORKBOOK}" \
  --headers "Content-Type=application/json" \
  --body "@${WB_BODY}" \
  --output none
echo "   workbook 'SOC Honeynet - Attack Maps' created."
echo
echo ">> Done. Open Microsoft Sentinel -> Watchlists / Analytics / Workbooks to verify."
echo "   Maps render once the 'geoip' watchlist finishes ingesting and telemetry arrives."
