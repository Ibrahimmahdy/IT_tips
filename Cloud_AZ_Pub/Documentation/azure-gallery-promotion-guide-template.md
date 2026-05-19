# Azure Compute Gallery: DEV to PROD Image Promotion Guide

## Overview

This document describes the end-to-end process for promoting VM images from a Development Azure Compute Gallery to a Production Azure Compute Gallery across separate Azure subscriptions, and how to make those images consumable by other PROD subscriptions.

### Environment Reference

| Environment | Gallery Name | Resource Group | Subscription | Subscription ID | Region |
|---|---|---|---|---|---|
| **Source (DEV)** | `<dev-gallery-name>` | `<dev-resource-group>` | `<dev-subscription-name>` | `<dev-subscription-id>` | `<region>` |
| **Target (PROD)** | `<prod-gallery-name>` | `<prod-resource-group>` | `<prod-subscription-name>` | `<prod-subscription-id>` | `<region>` |

### Architecture Pattern

```
┌─────────────────────────────────┐         ┌─────────────────────────────────┐
│   DEV Subscription              │         │   PROD Subscription             │
│                                 │         │                                 │
│   Gallery: <dev-gallery>        │ ──────▶ │   Gallery: <prod-gallery>       │
│   - Image Definition            │ Promote │   - Image Definition (matching) │
│     - Version: X.Y.Z            │         │     - Version: X.Y.Z            │
│                                 │         │       (replicated to N regions) │
└─────────────────────────────────┘         └─────────────────────────────────┘
                                                            │
                                                            │ RBAC: Reader
                                                            ▼
                                            ┌─────────────────────────────────┐
                                            │   Other PROD Subscriptions      │
                                            │   (VM/VMSS deployments consume) │
                                            └─────────────────────────────────┘
```

### Why This Approach

- **Environment isolation:** PROD has no dependency on DEV. If DEV breaks, PROD deployments continue working.
- **Traceability:** Same version number in both galleries makes audit trails clean.
- **Scalability:** New consumer subscriptions just need RBAC Reader on the PROD gallery — no per-subscription image copies.
- **Standard pattern:** This is the Azure-recommended approach for image lifecycle management.

---

## Prerequisites

### 1. Tools

- **Azure CLI** (version 2.40+ recommended). Azure Cloud Shell works perfectly.
- Bash shell (Linux, macOS, WSL, Git Bash, or Cloud Shell).

### 2. Permissions

The identity (user or service principal) running the promotion needs:

| Scope | Role | Purpose |
|---|---|---|
| Source image version in DEV gallery | `Reader` | Read source image data |
| Target PROD gallery | `Contributor` | Create image definitions and versions |
| PROD gallery (for assigning consumer access) | `User Access Administrator` or `Owner` | Grant RBAC to consumers |

### 3. Information to Collect Before Starting

- Source image definition name (e.g., `<image-definition-name>`)
- Source image version to promote (e.g., `<major.minor.patch>`)
- Source image security type (`Standard`, `TrustedLaunch`, `ConfidentialVM`, etc.)
- Source image Hyper-V generation (`V1` or `V2`)
- Source image `publisher`, `offer`, `sku` (must match in PROD)
- Target regions for PROD replication (typically more than DEV for HA/DR)
- Object IDs of consumer principals (service principals, managed identities, or Entra groups)

### 4. Login

```bash
az login
```

Verify access to both subscriptions:

```bash
az account list --query "[?id=='<dev-subscription-id>' || id=='<prod-subscription-id>'].{name:name, id:id}" -o table
```

---

## Step-by-Step Promotion Guide

### Step 0: Set Environment Variables

```bash
# Subscription IDs
DEV_SUB_ID="<dev-subscription-id>"
PROD_SUB_ID="<prod-subscription-id>"

# DEV (source)
DEV_RG="<dev-resource-group>"
DEV_GALLERY="<dev-gallery-name>"

# PROD (target)
PROD_RG="<prod-resource-group>"
PROD_GALLERY="<prod-gallery-name>"

# Image being promoted (adjust as needed)
DEV_IMAGE_DEF="<image-definition-name>"
DEV_IMAGE_VERSION="<major.minor.patch>"

# In PROD, keep the same name and version for traceability
PROD_IMAGE_DEF="$DEV_IMAGE_DEF"
PROD_IMAGE_VERSION="$DEV_IMAGE_VERSION"

LOCATION="<region>"
```

### Step 1: Discover and Inspect the DEV Image

Switch to DEV subscription and list available images:

```bash
az account set --subscription $DEV_SUB_ID

# List all image definitions in DEV
az sig image-definition list \
  --resource-group $DEV_RG \
  --gallery-name $DEV_GALLERY \
  --output table

# List versions of the target image
az sig image-version list \
  --resource-group $DEV_RG \
  --gallery-name $DEV_GALLERY \
  --gallery-image-definition $DEV_IMAGE_DEF \
  --output table
```

### Step 2: Get DEV Image Definition Metadata

You'll need these exact values to create a matching definition in PROD:

```bash
az sig image-definition show \
  --resource-group $DEV_RG \
  --gallery-name $DEV_GALLERY \
  --gallery-image-definition $DEV_IMAGE_DEF \
  --query "{publisher:identifier.publisher, offer:identifier.offer, sku:identifier.sku, osType:osType, osState:osState, hyperV:hyperVGeneration, securityType:features[?name=='SecurityType'].value | [0]}" \
  -o table
```

**Save this output.** Critical fields:
- `publisher`, `offer`, `sku` — must match exactly in PROD
- `hyperV` — usually `V2` (required for Trusted Launch)
- `securityType` — determines `--features` flag for the PROD definition
- `osType` — `Linux` or `Windows`
- `osState` — `Generalized` or `Specialized`

### Step 3: Verify the DEV Image Version Is Healthy

```bash
DEV_VERSION_ID="/subscriptions/$DEV_SUB_ID/resourceGroups/$DEV_RG/providers/Microsoft.Compute/galleries/$DEV_GALLERY/images/$DEV_IMAGE_DEF/versions/$DEV_IMAGE_VERSION"

az sig image-version show --ids $DEV_VERSION_ID \
  --expand ReplicationStatus \
  --query "{name:name, state:provisioningState, replication:replicationStatus.aggregatedState}" \
  -o table
```

Both `state` and `replication` should be `Succeeded`/`Completed`.

### Step 4: Create the Matching Image Definition in PROD

Switch to PROD subscription:

```bash
az account set --subscription $PROD_SUB_ID

# Check if the definition already exists (skip creation if it does)
az sig image-definition list \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  -o table
```

If the definition doesn't exist, create it using values from Step 2:

```bash
az sig image-definition create \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --publisher "<publisher-from-step-2>" \
  --offer "<offer-from-step-2>" \
  --sku "<sku-from-step-2>" \
  --os-type Linux \
  --os-state Generalized \
  --hyper-v-generation V2 \
  --features SecurityType=TrustedLaunch
```

**Important field notes:**
- `--features SecurityType=<value>` must match the source. Options: `TrustedLaunch`, `TrustedLaunchSupported`, `ConfidentialVM`, `ConfidentialVMSupported`, or omit for `Standard`.
- `--hyper-v-generation` must match the source.
- The image definition's security type **cannot be changed after creation**. If you get it wrong, you must delete and recreate.

### Step 5: Promote (Copy) the Image Version from DEV to PROD

This is the actual promotion step:

```bash
az sig image-version create \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --gallery-image-version $PROD_IMAGE_VERSION \
  --target-regions <primary-region> <dr-region> \
  --replica-count 2 \
  --managed-image $DEV_VERSION_ID
```

**Parameter guidance:**
- `--target-regions`: For PROD, include both your primary region and at least one DR region.
- `--replica-count`: 2–3 is reasonable for PROD; more replicas = faster parallel deployments.
- `--managed-image`: Despite the name, this accepts the resource ID of a gallery image version.
- The copy takes **20–60 minutes** depending on image size.

**Optional flags worth considering:**
- `--end-of-life-date "<YYYY-MM-DD>"` — sets retention/expiry date
- `--block-deletion-before-end-of-life true` — compliance protection (locks deletion until EOL)
- `--no-wait` — returns immediately; check progress separately

### Step 6: Verify Replication Completed

```bash
az sig image-version show \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --gallery-image-version $PROD_IMAGE_VERSION \
  --expand ReplicationStatus \
  --query "replicationStatus.summary[].{Region:region, State:state, Progress:progress}" \
  -o table
```

**Note:** You must include `--expand ReplicationStatus` — without it, the `replicationStatus` field returns null even when replication is complete.

Wait for all regions to show `Completed` at 100%.

Capture the PROD image resource ID for consumers:

```bash
PROD_VERSION_ID="/subscriptions/$PROD_SUB_ID/resourceGroups/$PROD_RG/providers/Microsoft.Compute/galleries/$PROD_GALLERY/images/$PROD_IMAGE_DEF/versions/$PROD_IMAGE_VERSION"

echo $PROD_VERSION_ID
```

### Step 7: Grant Consumer Access via RBAC

**Recommended pattern: use an Entra security group.**

One-time setup:

```bash
# Create the consumer group
az ad group create \
  --display-name "<gallery-consumers-group-name>" \
  --mail-nickname "<gallery-consumers-group-name>"

GROUP_OBJECT_ID=$(az ad group show --group "<gallery-consumers-group-name>" --query id -o tsv)

# Grant the group Reader on the PROD gallery
az role assignment create \
  --assignee $GROUP_OBJECT_ID \
  --role "Reader" \
  --scope "/subscriptions/$PROD_SUB_ID/resourceGroups/$PROD_RG/providers/Microsoft.Compute/galleries/$PROD_GALLERY"
```

For each consumer (deployment service principal, managed identity, or user), add them to the group:

```bash
az ad group member add \
  --group $GROUP_OBJECT_ID \
  --member-id <consumer-object-id>
```

**Alternative: direct RBAC assignment per consumer:**

```bash
az role assignment create \
  --assignee <consumer-object-id> \
  --role "Reader" \
  --scope "/subscriptions/$PROD_SUB_ID/resourceGroups/$PROD_RG/providers/Microsoft.Compute/galleries/$PROD_GALLERY"
```

To find a service principal's object ID:
```bash
az ad sp list --display-name "<sp-name>" --query "[].id" -o tsv
```

To find a managed identity's object ID:
```bash
az identity show --name "<mi-name>" --resource-group "<rg>" --query principalId -o tsv
```

---

## Testing the Solution

### Test 1: Verify PROD Image Is Accessible

From the PROD subscription:

```bash
az account set --subscription $PROD_SUB_ID

az sig image-version show \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --gallery-image-version $PROD_IMAGE_VERSION \
  --expand ReplicationStatus \
  -o table
```

Expected: `provisioningState: Succeeded`, all regions `Completed`.

### Test 2: Deploy a Test VM from a Consumer Subscription

From a consumer PROD subscription:

```bash
az account set --subscription <consumer-prod-sub-id>

az vm create \
  --resource-group <consumer-rg> \
  --name <test-vm-name> \
  --image "$PROD_VERSION_ID" \
  --admin-username <admin-username> \
  --generate-ssh-keys \
  --size <vm-size> \
  --location <region> \
  --security-type TrustedLaunch \
  --enable-secure-boot true \
  --enable-vtpm true
```

**Trusted Launch flags are mandatory** when the image definition has `SecurityType=TrustedLaunch`:
- `--security-type TrustedLaunch`
- `--enable-secure-boot true`
- `--enable-vtpm true`

Omitting them will result in deployment failure.

### Test 3: Verify VM Is Running

```bash
az vm show \
  --resource-group <consumer-rg> \
  --name <test-vm-name> \
  --query "{name:name, state:powerState, securityType:securityProfile.securityType}" \
  -d -o table
```

Expected: `powerState: VM running`, `securityType: TrustedLaunch`.

### Test 4: Clean Up Test Resources

```bash
az vm delete --resource-group <consumer-rg> --name <test-vm-name> --yes

# Clean up associated network resources if test was in a dedicated RG
az group delete --name <consumer-rg> --yes --no-wait
```

---

## Troubleshooting: Common Issues and Resolutions

### Issue 1: Security Type Mismatch (Conflict Error)

**Error message:**
```
(Conflict) The source '...<gallery>/images/<image-def>/versions/<version>'
contains TrustedLaunch or ConfidentialVM security data that cannot be used in
image with 'TrustedLaunchSupported' security type. Please use either TrustedLaunch
or ConfidentialVM security type.
```

**Cause:**
The PROD image definition was created with `TrustedLaunchSupported` (or `Standard`) security type, but the source DEV image is `TrustedLaunch`. These security types must match exactly between source and target.

**Resolution:**
1. Delete any failed image versions in the PROD definition.
2. Delete the incorrectly configured PROD image definition.
3. Recreate the definition with `--features SecurityType=TrustedLaunch`.
4. Retry the image version creation.

```bash
# Step 1: Delete failed version
az sig image-version delete \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --gallery-image-version $PROD_IMAGE_VERSION

# Step 2: Delete definition
az sig image-definition delete \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF

# Step 3: Recreate with correct security type
az sig image-definition create \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --publisher "<correct-publisher>" \
  --offer "<correct-offer>" \
  --sku "<correct-sku>" \
  --os-type Linux \
  --os-state Generalized \
  --hyper-v-generation V2 \
  --features SecurityType=TrustedLaunch

# Step 4: Retry promotion
az sig image-version create \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --gallery-image-version $PROD_IMAGE_VERSION \
  --target-regions <primary-region> <dr-region> \
  --replica-count 2 \
  --managed-image $DEV_VERSION_ID
```

**Prevention:** Always run Step 2 of the guide (inspect DEV image definition metadata) and copy the `securityType` value exactly into the PROD definition.

---

### Issue 2: Cannot Delete Image Definition (Nested Resources Exist)

**Error message:**
```
(CannotDeleteResource) Cannot delete resource while nested resources exist.
Some existing nested resource IDs include:
'Microsoft.Compute/galleries/<gallery>/images/<image-def>/versions/<version>'.
Please delete all nested resources before deleting this resource.
```

**Cause:**
Azure Compute Gallery has a parent-child hierarchy: `Gallery` → `Image Definition` → `Image Version`. You cannot delete a definition while any versions (even failed ones) still exist under it.

**Resolution:**
Delete all child versions first, then the definition.

```bash
# List all versions under the definition
az sig image-version list \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  -o table

# Delete each version
az sig image-version delete \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --gallery-image-version <version>

# Now the definition can be deleted
az sig image-definition delete \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF
```

---

### Issue 3: `replicationStatus` Returns Null Despite Successful Provisioning

**Symptom:**
```bash
az sig image-version show \
  --query "replicationStatus" \
  -o json
# Returns: null or empty
```

But `provisioningState` shows `Succeeded`.

**Cause:**
The `replicationStatus` field is part of the instance view of the resource, which Azure does not include in the default response. You must explicitly request it.

**Resolution:**
Add the `--expand ReplicationStatus` flag.

```bash
az sig image-version show \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --gallery-image-version $PROD_IMAGE_VERSION \
  --expand ReplicationStatus \
  --query "replicationStatus.summary[].{Region:region, State:state, Progress:progress}" \
  -o table
```

---

### Issue 4: CLI Deprecation Warnings

**Warning message:**
```
The default value of '--end-of-life-date' will be changed to '6 months from publish date' from 'None' in a future release.
The default value of '--block-deletion-before-end-of-life' will be changed to 'True' from 'None' in a future release.
```

**Cause:**
Informational only — Azure is signaling upcoming default behavior changes.

**Resolution (optional, recommended for PROD):**
Explicitly set these values to avoid surprises in future CLI versions:

```bash
az sig image-version create \
  ... \
  --end-of-life-date "<YYYY-MM-DD>" \
  --block-deletion-before-end-of-life false
```

For PROD compliance, set `--block-deletion-before-end-of-life true` once your process is stable.

---

### Issue 5: Consumer VM Deployment Fails on Trusted Launch Image

**Symptom:**
VM creation from the PROD image fails with errors about security profile or vTPM.

**Cause:**
Trusted Launch images require explicit security flags during VM creation. The image enforces these requirements.

**Resolution:**
Always include all three flags:

```bash
az vm create \
  --image "$PROD_VERSION_ID" \
  ... \
  --security-type TrustedLaunch \
  --enable-secure-boot true \
  --enable-vtpm true
```

For ARM/Bicep/Terraform templates, ensure the `securityProfile` block is configured:

```json
"securityProfile": {
  "securityType": "TrustedLaunch",
  "uefiSettings": {
    "secureBootEnabled": true,
    "vTpmEnabled": true
  }
}
```

---

## Future Promotions

Once the PROD gallery and consumer RBAC are set up, promoting new versions is a single command:

```bash
# Update variables for the new version
DEV_IMAGE_VERSION="<new-version>"
PROD_IMAGE_VERSION="<new-version>"
DEV_VERSION_ID="/subscriptions/$DEV_SUB_ID/resourceGroups/$DEV_RG/providers/Microsoft.Compute/galleries/$DEV_GALLERY/images/$DEV_IMAGE_DEF/versions/$DEV_IMAGE_VERSION"

# Promote
az account set --subscription $PROD_SUB_ID

az sig image-version create \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --gallery-image-version $PROD_IMAGE_VERSION \
  --target-regions <primary-region> <dr-region> \
  --replica-count 2 \
  --managed-image $DEV_VERSION_ID
```

No need to recreate the definition or re-grant RBAC — consumers will automatically have access to the new version.

---

## Recommendations

### Operational

- **Pin versions in production deployments.** Reference specific versions instead of `latest` for deterministic, rollback-friendly deploys.
- **Use a security group for consumer RBAC.** Adding/removing consumers becomes group membership management rather than RBAC role-assignment churn.
- **Automate the promotion in a pipeline.** Once manual promotion works, move it to Azure DevOps or GitHub Actions with a manual approval gate after DEV testing.
- **Set retention policies.** Use `--end-of-life-date` to enforce image lifecycle and clean up stale versions.

### Architecture

- **Keep version numbers identical** between DEV and PROD for the same image content. This makes audit and traceability much easier.
- **Replicate to at least two regions in PROD** for HA/DR, even if all consumers are in one region today.
- **Consider a hub-and-spoke model at scale.** One central PROD gallery shared via RBAC to many consumer subscriptions is cleaner than multiple per-subscription galleries.

### Security

- **Never grant consumer subscriptions write access to the PROD gallery.** `Reader` is sufficient for deployment.
- **Match security types strictly.** If you use Trusted Launch in DEV, use it in PROD too — don't downgrade to `Standard` or `TrustedLaunchSupported`.
- **Plan for customer-managed keys (CMK).** If you encrypt with CMK, the promotion identity needs access to the source DEK and you'll likely want to re-encrypt with a PROD-specific DEK on the target side.

---

## Reference: Useful Commands

### List all galleries in a subscription
```bash
az sig list --query "[].{name:name, rg:resourceGroup, location:location}" -o table
```

### List image definitions in a gallery
```bash
az sig image-definition list --resource-group $PROD_RG --gallery-name $PROD_GALLERY -o table
```

### List all versions of an image definition
```bash
az sig image-version list \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  -o table
```

### Check who has access to the gallery
```bash
az role assignment list \
  --scope "/subscriptions/$PROD_SUB_ID/resourceGroups/$PROD_RG/providers/Microsoft.Compute/galleries/$PROD_GALLERY" \
  -o table
```

### Monitor replication progress (polling)
```bash
watch -n 30 "az sig image-version show \
  --resource-group $PROD_RG \
  --gallery-name $PROD_GALLERY \
  --gallery-image-definition $PROD_IMAGE_DEF \
  --gallery-image-version $PROD_IMAGE_VERSION \
  --expand ReplicationStatus \
  --query 'replicationStatus.summary[].{Region:region, State:state, Progress:progress}' \
  -o table"
```

---

## Placeholder Reference

Replace these placeholders with your actual environment values when using this guide:

| Placeholder | Description | Example |
|---|---|---|
| `<dev-subscription-id>` | Azure subscription ID for DEV | `00000000-0000-0000-0000-000000000000` |
| `<prod-subscription-id>` | Azure subscription ID for PROD | `11111111-1111-1111-1111-111111111111` |
| `<dev-subscription-name>` | DEV subscription display name | `MyOrg_ImageBuilder_Dev` |
| `<prod-subscription-name>` | PROD subscription display name | `MyOrg_SharedServices_Prod` |
| `<dev-resource-group>` | DEV resource group name | `rg-imagebuilder-dev` |
| `<prod-resource-group>` | PROD resource group name | `rg-sharedservices-prod` |
| `<dev-gallery-name>` | DEV Compute Gallery name | `acg_dev` |
| `<prod-gallery-name>` | PROD Compute Gallery name | `acg_prod` |
| `<image-definition-name>` | Name of the image definition | `linux-baseline-v2` |
| `<major.minor.patch>` | Semantic image version | `1.0.0`, `9.7.1` |
| `<region>` | Azure region | `westeurope`, `eastus` |
| `<primary-region>` | Primary deployment region | `westeurope` |
| `<dr-region>` | Disaster recovery region | `northeurope` |
| `<gallery-consumers-group-name>` | Entra group for consumers | `sg-acg-consumers` |
| `<consumer-prod-sub-id>` | Consuming PROD subscription ID | `22222222-2222-2222-2222-222222222222` |
| `<consumer-rg>` | Consumer resource group | `rg-app-prod` |
| `<consumer-object-id>` | Object ID of consumer principal | `33333333-3333-3333-3333-333333333333` |
| `<test-vm-name>` | Test VM name | `test-image-promo` |
| `<admin-username>` | VM admin username | `azureuser` |
| `<vm-size>` | Azure VM size SKU | `Standard_D2s_v5` |
| `<sp-name>` | Service principal display name | `sp-image-deployer` |
| `<mi-name>` | Managed identity name | `mi-vm-deployer` |
| `<correct-publisher>` | Image publisher value | `MyCompany` |
| `<correct-offer>` | Image offer value | `RHEL` |
| `<correct-sku>` | Image SKU value | `9-hardened` |
| `<new-version>` | Version for next promotion | `1.0.1`, `9.7.2` |
| `<YYYY-MM-DD>` | Date in ISO format | `2027-12-31` |

---

## Document Metadata

| Field | Value |
|---|---|
| **Document Title** | Azure Compute Gallery: DEV to PROD Image Promotion Guide |
| **Scope** | Cross-subscription image promotion and consumer enablement |
| **Type** | Generic template (replace placeholders with environment-specific values) |
