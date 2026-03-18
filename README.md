# adf-release-mgmt-template

> **Reusable GitHub Actions Workflows & Scripts** for Azure Data Factory CI/CD
> ARM Template Export · Dev → UAT → Prod · Self-Hosted Runners · Managed Identity

This is the **template repository** for the ADF CI/CD framework. It contains the shared,
reusable deployment logic that all ADF working repositories call via `workflow_call`.
Working repositories own their environment config (`.env/`) and calling workflows —
this repo owns the **how** of deployment.

---

## Table of Contents

1. [Repository Structure](#repository-structure)
2. [How It Fits Together](#how-it-fits-together)
3. [Reusable Workflows](#reusable-workflows)
   - [template.yml — Deployment](#templateyml--deployment)
   - [validation.yml — PR Validation](#validationyml--pr-validation)
4. [Scripts](#scripts)
   - [update.ps1 — Parameter Merge](#updateps1--parameter-merge)
   - [updateIR.ps1 — IR Name Replacement](#updateirps1--ir-name-replacement)
5. [End-to-End Pipeline Walkthrough](#end-to-end-pipeline-walkthrough)
6. [Prerequisites & Setup](#prerequisites--setup)
7. [GitHub Secrets Reference](#github-secrets-reference)
8. [Workflow Inputs Reference](#workflow-inputs-reference)
9. [Environment Parameter Files (.env/)](#environment-parameter-files-env)
10. [Integration Runtime Mapping](#integration-runtime-mapping)
11. [Pre/Post Deployment Script](#prepost-deployment-script)
12. [Deployment Modes & Incremental Safety](#deployment-modes--incremental-safety)
13. [Troubleshooting](#troubleshooting)
14. [Rollback Procedure](#rollback-procedure)
15. [Adding a New Working Repository](#adding-a-new-working-repository)
16. [Framework Repository Map](#framework-repository-map)

---

## Repository Structure

```
adf-release-mgmt-template/
│
├── .github/
│   └── workflows/
│       ├── template.yml       ← Reusable deployment workflow (called by working repos)
│       └── validation.yml     ← Reusable PR validation workflow (called by working repos)
│
├── update.ps1                 ← Merges .env/<ENV>.txt overrides into ARM parameter JSON
├── updateIR.ps1               ← Standalone Integration Runtime name replacement script
│
├── docs/
│   └── README.md              ← Additional architecture notes
│
└── README.md                  ← This file
```

---

## How It Fits Together

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     WORKING REPO (per ADF project)                      │
│                   e.g. adf-release-mgmt-working                         │
│                                                                         │
│  .env/Dev.txt   .env/UAT.txt   .env/Prod.txt   ← env-specific params   │
│                                                                         │
│  .github/workflows/                                                     │
│    validation.yml  ──── calls ──►  THIS REPO / validation.yml           │
│    uat_deploy.yml  ──── calls ──►  THIS REPO / template.yml             │
│    prod_deploy.yml ──── calls ──►  THIS REPO / template.yml             │
└─────────────────────────────────────────────────────────────────────────┘
                                         │
                    ┌────────────────────┘
                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                  TEMPLATE REPO (this repo)                              │
│                adf-release-mgmt-template                                │
│                                                                         │
│  template.yml      ← runs all 12 deployment steps                      │
│  validation.yml    ← validates ADF JSON on every PR                    │
│  update.ps1        ← checked out at runtime by template.yml            │
│  updateIR.ps1      ← available for standalone/local use                │
└─────────────────────────────────────────────────────────────────────────┘
```

The working repo contains **what** to deploy (the ADF project config).
This template repo contains **how** to deploy it (the shared pipeline logic).

This separation means:
- Bug fixes to deployment logic are made once here and inherited by all projects.
- Each working repo stays lean — only project-specific config lives there.
- New ADF projects onboard by creating a working repo and pointing at this template.

---

## Reusable Workflows

### `template.yml` — Deployment

**Called by:** `uat_deploy.yml` and `prod_deploy.yml` in working repos.
**Trigger:** `workflow_call` only — never runs directly.

#### Step-by-step execution

| Step | Action | Detail |
|------|--------|--------|
| 1 | **Checkout working repo** | Checks out the calling repo (ARM templates + `.env/` files) |
| 2 | **Mint GitHub App token** | Creates a short-lived token so the runner can pull this private template repo |
| 3 | **Checkout template repo** | Pulls `update.ps1` and other scripts into `./template-repo/` at runtime |
| 4 | **Azure Login (OIDC)** | Authenticates via Managed Identity — no stored credentials |
| 5 | **Install NPM** | Installs `@microsoft/azure-data-factory-utilities` from `package.json` |
| 6 | **Validate ADF** | `npm run build validate` — checks all ADF JSON against the DEV factory schema |
| 7 | **Generate ARM Template** | `npm run build export` — exports ARM templates from DEV ADF into `./ArmTemplate/` |
| 8 | **Update IR Names** | PowerShell: replaces `SourceIRName` with `TargetIRName` in all `ArmTemplate*.json` files |
| 9 | **Merge env parameters** | `update.ps1` reads `.env/<ENV>.txt` and produces `parameters.updated.json` |
| 10 | **Pre-Deployment** | `PrePostDeploymentScript.ps1 -predeployment $true` — **stops all ADF triggers** |
| 11 | **ARM Deploy** | `azure/arm-deploy` — Incremental deployment to target resource group |
| 12 | **Post-Deployment** | `PrePostDeploymentScript.ps1 -predeployment $false -deleteDeployment $true` — restarts triggers, removes deleted resources |

#### Key design decisions

**Why export ARM templates at runtime (Step 7) instead of committing them?**
Exporting at runtime means the ARM template always reflects the exact state of the
DEV factory at the moment of promotion. This prevents stale templates from being deployed.
The DEV factory is the single source of truth.

**Why check out the template repo at runtime (Step 3)?**
`workflow_call` only gives access to files in the *calling* working repo.
The `update.ps1` script lives in *this* template repo, so it must be explicitly
checked out into the runner workspace during the job using a GitHub App token.

**Why Managed Identity / OIDC (Step 4)?**
No secrets are stored. The runner's Azure Managed Identity is granted the necessary
RBAC roles on the target resource group. This is the recommended auth pattern for
self-hosted runners in Azure.

---

### `validation.yml` — PR Validation

**Called by:** `validation.yml` in working repos (on pull requests).
**Trigger:** `workflow_call` only — never runs directly.

#### Step-by-step execution

| Step | Action | Detail |
|------|--------|--------|
| 1 | **Checkout working repo** | Checks out the PR branch |
| 2 | **Azure Login (OIDC)** | Authenticates against Non-Prod subscription |
| 3 | **Install NPM** | Installs ADF build utilities |
| 4 | **Validate ADF** | `npm run build validate` — schema validation against DEV factory |
| 5 | **Generate ARM Template** | `npm run build export` — dry-run export (not deployed) |
| 6 | **Print outputs** | Logs parameter file and master template for PR review |
| 7 | **Cleanup** | Deletes generated `./ArmTemplate/` — nothing persists |

**Nothing is deployed.** This workflow is purely a gate to catch ADF JSON errors
(broken references, missing datasets, invalid trigger configs) before they reach UAT.

---

## Scripts

### `update.ps1` — Parameter Merge

**Purpose:** Reads key=value pairs from `.env/<ENV>.txt` and applies them as
overrides to the ARM parameter JSON file, producing `parameters.updated.json`.

**Called by:** `template.yml` Step 9.

```powershell
# Signature:
./update.ps1 `
    -parameterFile "ArmTemplate/linkedTemplates/ArmTemplateParameters_master.json" `
    -variablesFile ".env/UAT.txt" `
    -outputFile    "parameters.updated.json"   # optional, this is the default
```

#### How value types are handled

| Pattern in `.env` file | Parsed as | Example |
|---|---|---|
| `key="value"` or `key='value'` | String (verbatim, no re-escaping) | SAS tokens, URLs |
| `key={ ... }` | JSON object (multi-line supported) | Complex linked service configs |
| `key=[ ... ]` | JSON array (multi-line supported) | Lists |
| `key=true` / `key=false` | Boolean | Feature flags |
| `key=42` | Integer | Port numbers |
| `key=plaintext` | String | Simple names |
| `# comment` or blank line | Skipped | Comments in `.env` files |

**Why quoted strings are special:**
SAS tokens and URLs contain characters like `%`, `+`, `=`, `&` that
`ConvertTo-Json` would double-escape. The script tracks which keys were
quoted and re-injects their raw values into the final JSON to prevent this.

**Keys not in the ARM parameter file are silently skipped.** This allows
`.env/Prod.txt` to carry extra keys (Logic App URLs, OFS API config) that
only exist in certain factory configurations without breaking others.

---

### `updateIR.ps1` — IR Name Replacement

**Purpose:** Standalone script to replace Integration Runtime names in
ARM template files. Equivalent logic is also embedded inline in `template.yml`.

**Use this script for:** local testing, debugging IR replacement, or calling
from custom pipelines outside the standard workflow.

```powershell
# Replace IR name (same name in both envs):
./updateIR.ps1 `
    -SourceIRName  "DADASAPP004" `
    -TargetIRName  "DADASAPP004" `
    -SourceDirectory "./ArmTemplate" `
    -FilePattern   ".json"

# Replace IR name (different name in Prod):
./updateIR.ps1 `
    -SourceIRName  "DADASAPP004" `
    -TargetIRName  "PADASAPP002" `
    -SourceDirectory "./ArmTemplate" `
    -FilePattern   ".json"
```

**What it scans:** All files in `SourceDirectory` (recursively) whose names
start with `armtemplate` (case-insensitive) and match `FilePattern`.
This covers both the root template and all linked template shards.

---

## End-to-End Pipeline Walkthrough

### Scenario: Developer changes an ADF pipeline and promotes to UAT

```
1. Developer edits pipeline in ADF Studio (Dev factory)
   └─ Makes changes to a pipeline, dataset, or linked service

2. Developer clicks Publish in ADF Studio
   └─ ADF Studio validates JSON and pushes to the collaboration branch (main)
   └─ No ARM template is committed — the DEV factory is the source of truth

3. Developer raises a Pull Request → main branch in working repo
   └─ validation.yml triggers automatically (workflow_call → this repo)
   └─ Runner: npm run build validate → checks ADF JSON against DEV factory
   └─ If validation fails: PR is blocked, developer fixes ADF JSON errors
   └─ If validation passes: PR can be merged

4. PR merged to main

5. Release manager triggers uat_deploy.yml manually (workflow_dispatch)
   └─ Calls template.yml in this repo with UAT inputs
   └─ Step 6-7: Validates + exports ARM templates from DEV factory at runtime
   └─ Step 8:   Replaces DADASAPP004 (DEV IR) → DADASAPP004 (UAT IR) in ARM files
   └─ Step 9:   Reads .env/UAT.txt → produces parameters.updated.json
                (factoryName → DF-<Project>-Tst-DA, SQL server → UAT server, etc.)
   └─ Step 10:  Stops all UAT ADF triggers (PrePostDeploymentScript)
   └─ Step 11:  Deploys ARM template incrementally to UAT resource group
   └─ Step 12:  Restarts UAT triggers, removes any deleted resources

6. UAT sign-off by business / QA team

7. Release manager triggers prod_deploy.yml manually (workflow_dispatch)
   └─ GitHub Environment "Prod" requires manual approval → approver reviews and approves
   └─ Same steps as UAT but with Prod inputs:
       - TRG_ADF_NAME: DF-<Project>-Prod-DA
       - .env/Prod.txt applied (Prod SQL server, KV, Databricks clusters, etc.)
       - TargetIRName: PADASAPP002 (if Prod uses a different IR)
       - Runner_Group: Prod
```

---

## Prerequisites & Setup

### 1. Self-hosted runners

Two runner groups must be configured in your GitHub organisation:

| Runner Group | Used by | Azure network |
|---|---|---|
| `Non-Prod` | Validation, UAT deploy | Non-Prod VNet / subnet |
| `Prod` | Prod deploy | Prod VNet / subnet |

Runners must have:
- PowerShell 7+ (`pwsh`)
- Node.js 18+ (for `npm`)
- Azure CLI (for `az` commands in PrePostDeploymentScript.ps1)
- Network line-of-sight to Azure Resource Manager endpoints
- Managed Identity assigned with appropriate Azure RBAC roles

### 2. Azure RBAC roles for Managed Identity

Each runner's Managed Identity needs the following roles on the **target** resource group:

| Role | Reason |
|---|---|
| `Data Factory Contributor` | Deploy ADF ARM templates, start/stop triggers |
| `Reader` | Read existing resource state during Incremental deployment |

For the **source** (DEV) resource group, the identity needs:
| Role | Reason |
|---|---|
| `Data Factory Contributor` | Export ARM templates via `npm run build export` |

### 3. GitHub App (for cross-repo checkout)

The `template.yml` workflow checks out this private template repo using a GitHub App token.
Set up a GitHub App at the organisation level with:
- **Repository access:** `adf-release-mgmt-template`
- **Permissions:** `Contents: Read`

Store the App credentials in the working repo (or org-level) as:

| Secret | Value |
|---|---|
| `APP_ID` | GitHub App ID (numeric) |
| `PRIVATE_KEY` | GitHub App private key (PEM format) |

### 4. GitHub Environments

Configure GitHub Environments in each **working repo**:

| Environment name | Protection rules |
|---|---|
| `UAT` | Optional: required reviewers |
| `Prod` | **Required: at least 1 reviewer approval** |

The `environment:` input in `template.yml` must exactly match the GitHub Environment name.

### 5. `package.json` in working repo root

The `npm install` step installs `@microsoft/azure-data-factory-utilities`.
Your working repo must have a `package.json` at root:

```json
{
  "scripts": {
    "build": "node node_modules/@microsoft/azure-data-factory-utilities/lib/index"
  },
  "dependencies": {
    "@microsoft/azure-data-factory-utilities": "^1.0.0"
  }
}
```

---

## GitHub Secrets Reference

Configure these at the **organisation** or **working repository** level.

| Secret | Required | Description |
|---|---|---|
| `APP_ID` | Yes | GitHub App ID — used to mint token for template repo checkout |
| `PRIVATE_KEY` | Yes | GitHub App private key (PEM) |

> All Azure auth is handled via **Managed Identity (OIDC)** on the self-hosted runner.
> No Azure credentials are stored as GitHub secrets.

---

## Workflow Inputs Reference

These inputs are passed from the working repo's calling workflow to `template.yml`.

| Input | Required | Description | Example |
|---|---|---|---|
| `ParameterFileName` | Yes | Path to master ARM parameter file | `ArmTemplate/linkedTemplates/ArmTemplateParameters_master.json` |
| `environment` | Yes | Environment label — must match GitHub Environment name and `.env/<ENV>.txt` filename | `UAT` / `Prod` |
| `SRC_ADF_NAME` | Yes | Source (DEV) ADF factory name | `DF-Utilities-Dev-DA` |
| `SRC_RG` | Yes | Source ADF resource group | `RG-Analytics-Utilities-NonProd` |
| `SRC_SUBS_ID` | Yes | Source ADF subscription ID | `072dc47c-...` |
| `TENANT_ID` | Yes | Azure AD Tenant ID | `f1e31150-...` |
| `TRG_ADF_NAME` | Yes | Target ADF factory name | `DF-Utilities-Tst-DA` |
| `TRG_RG` | Yes | Target ADF resource group | `RG-Analytics-Utilities-NonProd` |
| `TRG_SUBS_ID` | Yes | Target ADF subscription ID | `072dc47c-...` |
| `SourceIRName` | Yes | IR name in DEV ADF ARM template | `DADASAPP004` |
| `TargetIRName` | Yes | IR name to substitute in target | `DADASAPP004` / `PADASAPP002` |
| `Runner_Group` | Yes | Self-hosted runner group label | `Non-Prod` / `Prod` |
| `STORAGE_ACCOUNT` | No | Blob storage account for linked template staging | `stpublicananonprod` |

For `validation.yml`:

| Input | Required | Description |
|---|---|---|
| `ADF_NAME` | Yes | DEV ADF factory name to validate against |
| `RG` | Yes | DEV ADF resource group |
| `SUBS_ID` | Yes | DEV ADF subscription ID |
| `TENANT_ID` | Yes | Azure AD Tenant ID |

---

## Environment Parameter Files (`.env/`)

These files live in the **working repo**, not here.

Each file contains `key=value` pairs that override the default (DEV) values
in the ARM master parameter file at deployment time.

### Keys commonly overridden per environment

| Parameter key | What it controls |
|---|---|
| `factoryName` | ADF factory name in target env |
| `ls_azure_databricks_*_workspaceResourceId` | Databricks workspace (main / APS / CMM) |
| `ls_azure_databricks_*_domain` | Databricks workspace URL |
| `ls_azure_databricks_*_existingClusterId` | Cluster ID per workload type |
| `ls_azure_sql_db_*_server` | SQL Server FQDN |
| `ls_azure_sql_db_*_database` | SQL Database name |
| `ls_azure_key_vault_*_baseUrl` | Key Vault base URL |
| `containerUri` | Blob storage URI for ARM template staging |
| `containerSasToken` | SAS token for blob storage access |
| `default_properties_*` | ADF global parameters (Logic App URLs, API base URLs, etc.) |

### SAS token expiry warning

`containerSasToken` values in `.env/` files have a fixed expiry.
**Ensure the SAS token in `.env/Prod.txt` is valid at the time of Prod deployment.**
Rotate SAS tokens and update `.env/` files before they expire.
Consider replacing SAS tokens with a Managed Identity assignment on the storage account.

---

## Integration Runtime Mapping

The IR replacement step (Step 8 in `template.yml`) performs a simple string
replacement across all `ArmTemplate*.json` files.

| Scenario | SourceIRName | TargetIRName |
|---|---|---|
| DEV → UAT (same IR) | `DADASAPP004` | `DADASAPP004` |
| DEV → Prod (different IR) | `DADASAPP004` | `PADASAPP002` |
| Cross-factory shared IR | set to shared IR resource ID | same resource ID |

If your factory uses a **shared Integration Runtime** from another ADF factory,
the IR reference is stored as a full resource ID in the ARM template.
Update `PADASAPP002_properties_typeProperties_linkedInfo_resourceId` in `.env/Prod.txt`
to point to the correct shared IR resource in the Prod subscription.

---

## Pre/Post Deployment Script

`PrePostDeploymentScript.ps1` is the standard Microsoft-provided ADF deployment helper
script. It is generated alongside the ARM template when you export from ADF Studio and
lives at `./ArmTemplate/PrePostDeploymentScript.ps1` after the export step.

### Pre-deployment (`-predeployment $true`)

- Reads all triggers from the ARM template
- Stops any currently **running** triggers in the target ADF
- Prevents trigger conflicts during deployment (e.g. a trigger firing mid-deploy)

### Post-deployment (`-predeployment $false -deleteDeployment $true`)

- Restarts all triggers that were active before deployment
- Removes resources that exist in the target ADF but are **absent** from the new ARM template
  (i.e. pipelines, datasets, linked services that were deleted in DEV)
- The `-deleteDeployment $true` flag is what enables cleanup of deleted resources —
  this is the key difference from a plain Incremental ARM deploy which never deletes

---

## Deployment Modes & Incremental Safety

The ARM deployment uses `deploymentMode: Incremental`.

**What Incremental means:**
- Resources present in the template → created or updated
- Resources absent from the template → **left untouched by ARM**
- Resources deleted from the template → **removed by `PrePostDeploymentScript.ps1`** (not by ARM)

**Why not Complete mode?**
Complete mode would delete any ADF resource not in the template,
including resources managed outside this pipeline (shared IRs, global parameters
set via portal, etc.). Incremental + the post-deployment script gives equivalent
cleanup with more control.

---

## Troubleshooting

### `npm run build validate` fails

| Symptom | Likely cause | Fix |
|---|---|---|
| `Reference not found` | A pipeline references a deleted dataset or linked service | Restore the resource in DEV ADF or remove the reference |
| `Factory not found` | Wrong `SRC_ADF_NAME`, `SRC_RG`, or `SRC_SUBS_ID` input | Verify inputs in the calling workflow |
| `Authentication failed` | Runner Managed Identity lacks Reader on DEV RG | Grant `Data Factory Contributor` on DEV RG |

### `update.ps1` — parameter not applied

| Symptom | Likely cause | Fix |
|---|---|---|
| Value unchanged in `parameters.updated.json` | Key in `.env` file not present in `ArmTemplateParameters_master.json` | Check that the ARM parameter file includes that key; re-publish from DEV ADF |
| SAS token is double-escaped | Value not quoted in `.env` file | Wrap SAS token in double quotes: `containerSasToken="?sp=r&..."` |

### IR replacement did not occur

| Symptom | Likely cause | Fix |
|---|---|---|
| DEV IR name still present in deployed factory | `SourceIRName` input typo | Check exact IR name in DEV ADF → Manage → Integration Runtimes |
| Only some files updated | IR name only appears in certain linked template shards | This is expected — `updateIR.ps1` only replaces where the string exists |

### Pre-deployment script fails

| Symptom | Likely cause | Fix |
|---|---|---|
| `DataFactoryName not found` | `TRG_ADF_NAME` or `TRG_RG` input is wrong | Verify target factory exists in the correct RG |
| `Az module not found` | `enable-AzPSSession: true` not set on login step | Ensure `enable-AzPSSession: true` is in the Azure Login step |
| Trigger stop timeout | A trigger has a very long running pipeline | Increase timeout or manually stop the trigger before deploying |

### ARM deploy fails

| Symptom | Likely cause | Fix |
|---|---|---|
| `LinkedTemplateNotFound` | Linked template shards not accessible from `containerUri` | Verify `containerUri` and `containerSasToken` in `.env` file; check SAS expiry |
| `Conflict` on resource | A resource is locked or being modified | Wait and retry; check for active pipeline runs |
| `AuthorizationFailed` | Runner MI lacks `Data Factory Contributor` on target RG | Grant role in Azure Portal → IAM |

---

## Rollback Procedure

ADF does not have a native one-click rollback. Use this procedure:

### Option A — Redeploy previous commit (recommended)

```bash
# In the working repo:
git log --oneline                        # find the last good commit SHA
git checkout <previous-sha> -- .        # restore files from that commit
git commit -m "revert: rollback ADF to <previous-sha>"
git push
# Then manually trigger uat_deploy.yml or prod_deploy.yml
```

This re-runs the full pipeline with the previous ADF state as source.

### Option B — Revert in ADF Studio

1. Open ADF Studio → DEV factory
2. Use **Source Control → View Commits** to find the last good state
3. Revert the relevant pipeline/dataset to its previous version
4. Publish from ADF Studio
5. Re-run the deploy workflow

### Option C — ARM template re-deploy from portal

If the pipeline itself is broken, you can re-deploy a saved ARM template
directly from the Azure Portal → Resource Group → Deployments →
find the last successful deployment → Redeploy.

---

## Adding a New Working Repository

To onboard a new ADF project onto this framework:

**1. Create the working repo** using the naming convention:
```
<project-name>-release-mgmt-working
```

**2. Add `package.json`** at repo root (see Prerequisites section).

**3. Create `.env/` files** for each environment:
```
.env/Dev.txt
.env/UAT.txt
.env/Prod.txt
```

**4. Create calling workflows** in `.github/workflows/`:
```
validation.yml   → calls <YOUR_ORG>/adf-release-mgmt-template/.github/workflows/validation.yml@main
uat_deploy.yml   → calls <YOUR_ORG>/adf-release-mgmt-template/.github/workflows/template.yml@main
prod_deploy.yml  → calls <YOUR_ORG>/adf-release-mgmt-template/.github/workflows/template.yml@main
```

**5. Configure GitHub secrets** (`APP_ID`, `PRIVATE_KEY`) at repo or org level.

**6. Configure GitHub Environments** (`UAT`, `Prod`) with protection rules.

**7. Grant Managed Identity RBAC** on source and target resource groups.

**8. Test** by raising a dummy PR → confirm validation passes → trigger UAT deploy.

---

## Framework Repository Map

This template repo is one component of a broader enterprise CI/CD framework.
The same `-working` / `-template` pattern is used across all Azure resources.

| Resource | Working Repo | Template Repo |
|---|---|---|
| **Azure Data Factory** | `adf-release-mgmt-working` | `adf-release-mgmt-template` ← this repo |
| **Databricks** | `dbx-release-mgmt-working` | `dbx-release-mgmt-template` |
| **SQL** | `sql-release-mgmt-working` | `sql-release-mgmt-template` |
| **Logic Apps** | `logicapps-release-mgmt-working` | `logicapps-release-mgmt-template` |
| **Power BI** | `powerbi-release-mgmt-working` | `powerbi-release-mgmt-template` |
| **Power Apps** | `powerapps-release-mgmt-working` | `powerapps-release-mgmt-template` |

---

## References

- [Azure Data Factory CI/CD - Microsoft Docs](https://docs.microsoft.com/en-us/azure/data-factory/continuous-integration-delivery)
- [ADF Automated Publishing](https://docs.microsoft.com/en-us/azure/data-factory/continuous-integration-delivery-improvements)
- [PrePostDeploymentScript.ps1 - Microsoft Sample](https://docs.microsoft.com/en-us/azure/data-factory/continuous-integration-delivery-improvements#script)
- [GitHub Actions - Reusable Workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows)
- [GitHub Actions - create-github-app-token](https://github.com/actions/create-github-app-token)
- [azure/arm-deploy Action](https://github.com/Azure/arm-deploy)
- [Azure Login with Managed Identity](https://github.com/Azure/login#login-with-a-managed-identity)
