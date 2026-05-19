#!/bin/bash
#
# promote-image.sh
# ─────────────────────────────────────────────────────────────────────────────
# Promotes an Azure Compute Gallery image version from a DEV gallery
# to a PROD gallery across separate Azure subscriptions.
#
# Usage:
#   ./promote-image.sh <version> [image-definition]
#
# Examples:
#   ./promote-image.sh 1.0.0
#   ./promote-image.sh 1.0.0 my-image-definition
#   ./promote-image.sh 2.3.1 linux-baseline-hardened
#
# Prerequisites:
#   - Azure CLI logged in (az login)
#   - Reader on DEV gallery
#   - Contributor on PROD gallery
#   - The image definition must already exist in PROD with matching
#     publisher / offer / sku / securityType / hyperVGeneration
#
# Configuration:
#   Set the values in the CONFIGURATION section below for your environment.
#   Alternatively, override any value via environment variable at runtime:
#
#     DEV_SUB_ID=xxx PROD_SUB_ID=yyy ./promote-image.sh 1.0.0
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ════════════════════════════════════════════════════════════════════════════
# Auto-load config file if one exists (in order of preference)
# ════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for CONFIG_PATH in \
    "${PROMOTE_IMAGE_CONFIG:-}" \
    "${SCRIPT_DIR}/promote-image.conf" \
    "${HOME}/.config/promote-image.conf"; do
    if [[ -n "$CONFIG_PATH" && -f "$CONFIG_PATH" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_PATH"
        CONFIG_LOADED="$CONFIG_PATH"
        break
    fi
done

# ════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — edit these once for your environment
# (values from config file or environment variables will take precedence)
# ════════════════════════════════════════════════════════════════════════════

# Subscription IDs (UUIDs)
DEV_SUB_ID="${DEV_SUB_ID:-<dev-subscription-id>}"
PROD_SUB_ID="${PROD_SUB_ID:-<prod-subscription-id>}"

# DEV (source) gallery
DEV_RG="${DEV_RG:-<dev-resource-group>}"
DEV_GALLERY="${DEV_GALLERY:-<dev-gallery-name>}"

# PROD (target) gallery
PROD_RG="${PROD_RG:-<prod-resource-group>}"
PROD_GALLERY="${PROD_GALLERY:-<prod-gallery-name>}"

# Default image definition (override via CLI arg)
DEFAULT_IMAGE_DEF="${DEFAULT_IMAGE_DEF:-<default-image-definition-name>}"

# Target regions and replica count in PROD
# Space-separated list, e.g. "westeurope northeurope"
TARGET_REGIONS="${TARGET_REGIONS:-<primary-region> <dr-region>}"
REPLICA_COUNT="${REPLICA_COUNT:-2}"

# Optional: set retention policy (uncomment to use)
# END_OF_LIFE_DATE="$(date -d '+1 year' +%Y-%m-%d)"
# BLOCK_DELETION="false"

# Audit log location
LOG_DIR="${LOG_DIR:-${HOME}/.azure-gallery-promotions}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/promotions-$(date +%Y%m).log"

# ════════════════════════════════════════════════════════════════════════════
# Helper functions
# ════════════════════════════════════════════════════════════════════════════

log()  { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
fail() { echo "❌ ERROR: $*" >&2; log "FAILED: $*"; exit 1; }
ok()   { echo "✅ $*"; log "OK: $*"; }
info() { echo "ℹ️  $*"; }

confirm() {
    read -r -p "$1 [y/N] " response
    [[ "$response" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ════════════════════════════════════════════════════════════════════════════
# Configuration validation
# ════════════════════════════════════════════════════════════════════════════

# Detect unconfigured placeholder values
validate_config() {
    local errors=0

    if [[ "$DEV_SUB_ID" == *"<"*">"* ]] || [[ -z "$DEV_SUB_ID" ]]; then
        echo "❌ DEV_SUB_ID is not configured (currently: '$DEV_SUB_ID')" >&2
        errors=$((errors + 1))
    fi
    if [[ "$PROD_SUB_ID" == *"<"*">"* ]] || [[ -z "$PROD_SUB_ID" ]]; then
        echo "❌ PROD_SUB_ID is not configured (currently: '$PROD_SUB_ID')" >&2
        errors=$((errors + 1))
    fi
    if [[ "$DEV_RG" == *"<"*">"* ]] || [[ -z "$DEV_RG" ]]; then
        echo "❌ DEV_RG is not configured (currently: '$DEV_RG')" >&2
        errors=$((errors + 1))
    fi
    if [[ "$PROD_RG" == *"<"*">"* ]] || [[ -z "$PROD_RG" ]]; then
        echo "❌ PROD_RG is not configured (currently: '$PROD_RG')" >&2
        errors=$((errors + 1))
    fi
    if [[ "$DEV_GALLERY" == *"<"*">"* ]] || [[ -z "$DEV_GALLERY" ]]; then
        echo "❌ DEV_GALLERY is not configured (currently: '$DEV_GALLERY')" >&2
        errors=$((errors + 1))
    fi
    if [[ "$PROD_GALLERY" == *"<"*">"* ]] || [[ -z "$PROD_GALLERY" ]]; then
        echo "❌ PROD_GALLERY is not configured (currently: '$PROD_GALLERY')" >&2
        errors=$((errors + 1))
    fi
    if [[ "$TARGET_REGIONS" == *"<"*">"* ]] || [[ -z "$TARGET_REGIONS" ]]; then
        echo "❌ TARGET_REGIONS is not configured (currently: '$TARGET_REGIONS')" >&2
        errors=$((errors + 1))
    fi

    if [[ $errors -gt 0 ]]; then
        echo "" >&2
        echo "Please edit the CONFIGURATION section at the top of this script" >&2
        echo "or set the corresponding environment variables before running." >&2
        exit 1
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# Argument parsing
# ════════════════════════════════════════════════════════════════════════════

if [[ $# -lt 1 ]]; then
    cat <<EOF
Usage: $0 <version> [image-definition]

Arguments:
  version            Image version to promote (e.g., 1.0.0)
  image-definition   Optional: image definition name
                     (defaults to $DEFAULT_IMAGE_DEF)

Examples:
  $0 1.0.0
  $0 1.0.0 my-image-definition

Environment variable overrides:
  DEV_SUB_ID, PROD_SUB_ID, DEV_RG, PROD_RG, DEV_GALLERY, PROD_GALLERY,
  DEFAULT_IMAGE_DEF, TARGET_REGIONS, REPLICA_COUNT
EOF
    exit 1
fi

VERSION="$1"
IMAGE_DEF="${2:-$DEFAULT_IMAGE_DEF}"

# Validate version format (basic semver check)
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "Version must be in semver format (e.g., 1.0.0), got: $VERSION"
fi

# Validate config is filled in
validate_config

# Validate image definition is set
if [[ "$IMAGE_DEF" == *"<"*">"* ]] || [[ -z "$IMAGE_DEF" ]]; then
    fail "Image definition is not configured. Pass it as argument or set DEFAULT_IMAGE_DEF."
fi

DEV_VERSION_ID="/subscriptions/$DEV_SUB_ID/resourceGroups/$DEV_RG/providers/Microsoft.Compute/galleries/$DEV_GALLERY/images/$IMAGE_DEF/versions/$VERSION"
PROD_VERSION_ID="/subscriptions/$PROD_SUB_ID/resourceGroups/$PROD_RG/providers/Microsoft.Compute/galleries/$PROD_GALLERY/images/$IMAGE_DEF/versions/$VERSION"

# ════════════════════════════════════════════════════════════════════════════
# Start
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Azure Compute Gallery — Image Promotion"
echo "════════════════════════════════════════════════════════════════════"
if [[ -n "${CONFIG_LOADED:-}" ]]; then
    echo "  Config file      : $CONFIG_LOADED"
fi
echo "  Image definition : $IMAGE_DEF"
echo "  Version          : $VERSION"
echo "  Source           : $DEV_GALLERY (DEV)"
echo "  Target           : $PROD_GALLERY (PROD)"
echo "  Target regions   : $TARGET_REGIONS"
echo "  Replica count    : $REPLICA_COUNT"
echo "════════════════════════════════════════════════════════════════════"
echo ""

log "Starting promotion: $IMAGE_DEF v$VERSION"

# ─── Check 1: Verify Azure CLI is logged in ──────────────────────────────────

info "Checking Azure CLI authentication..."
if ! az account show >/dev/null 2>&1; then
    fail "Not logged in. Run: az login"
fi
CURRENT_USER=$(az account show --query user.name -o tsv)
ok "Authenticated as: $CURRENT_USER"

# ─── Check 2: Verify DEV image version exists and is healthy ─────────────────

info "Verifying source image in DEV..."
az account set --subscription "$DEV_SUB_ID"

DEV_STATE=$(az sig image-version show --ids "$DEV_VERSION_ID" \
    --query "provisioningState" -o tsv 2>/dev/null || echo "NotFound")

if [[ "$DEV_STATE" == "NotFound" ]]; then
    fail "Source image version not found in DEV: $IMAGE_DEF v$VERSION"
fi

if [[ "$DEV_STATE" != "Succeeded" ]]; then
    fail "Source image is in state '$DEV_STATE' — must be 'Succeeded' to promote"
fi
ok "Source image found and healthy"

# ─── Check 3: Verify PROD image definition exists ────────────────────────────

info "Verifying target image definition in PROD..."
az account set --subscription "$PROD_SUB_ID"

if ! az sig image-definition show \
    --resource-group "$PROD_RG" \
    --gallery-name "$PROD_GALLERY" \
    --gallery-image-definition "$IMAGE_DEF" >/dev/null 2>&1; then
    fail "Image definition '$IMAGE_DEF' does not exist in PROD gallery. Create it first."
fi
ok "Target image definition exists"

# ─── Check 4: Verify security type alignment between DEV and PROD ────────────

info "Verifying security type compatibility..."
az account set --subscription "$DEV_SUB_ID"
DEV_SEC=$(az sig image-definition show \
    --resource-group "$DEV_RG" \
    --gallery-name "$DEV_GALLERY" \
    --gallery-image-definition "$IMAGE_DEF" \
    --query "features[?name=='SecurityType'].value | [0]" -o tsv 2>/dev/null || echo "Standard")
DEV_SEC="${DEV_SEC:-Standard}"

az account set --subscription "$PROD_SUB_ID"
PROD_SEC=$(az sig image-definition show \
    --resource-group "$PROD_RG" \
    --gallery-name "$PROD_GALLERY" \
    --gallery-image-definition "$IMAGE_DEF" \
    --query "features[?name=='SecurityType'].value | [0]" -o tsv 2>/dev/null || echo "Standard")
PROD_SEC="${PROD_SEC:-Standard}"

if [[ "$DEV_SEC" != "$PROD_SEC" ]]; then
    fail "Security type mismatch — DEV: '$DEV_SEC', PROD: '$PROD_SEC'. They must match."
fi
ok "Security type matches: $DEV_SEC"

# ─── Check 5: Check if the version already exists in PROD ────────────────────

info "Checking if version already exists in PROD..."
if az sig image-version show --ids "$PROD_VERSION_ID" >/dev/null 2>&1; then
    EXISTING_STATE=$(az sig image-version show --ids "$PROD_VERSION_ID" \
        --query "provisioningState" -o tsv)
    echo ""
    echo "⚠️  Version $VERSION already exists in PROD with state: $EXISTING_STATE"
    if [[ "$EXISTING_STATE" == "Succeeded" ]]; then
        echo "Nothing to do — version is already promoted."
        exit 0
    fi
    confirm "Delete the existing $EXISTING_STATE version and recreate?"

    info "Deleting existing version..."
    az sig image-version delete \
        --resource-group "$PROD_RG" \
        --gallery-name "$PROD_GALLERY" \
        --gallery-image-definition "$IMAGE_DEF" \
        --gallery-image-version "$VERSION"
    ok "Existing version deleted"
fi

# ─── Confirmation before kicking off the long-running promotion ──────────────

echo ""
echo "Ready to promote. This typically takes 20-60 minutes."
confirm "Proceed with promotion?"

# ─── Step 1: Create the image version in PROD ────────────────────────────────

log "Creating image version $VERSION in PROD gallery..."
info "Starting promotion (this will take a while)..."

PROMOTE_CMD=(
    az sig image-version create
    --resource-group "$PROD_RG"
    --gallery-name "$PROD_GALLERY"
    --gallery-image-definition "$IMAGE_DEF"
    --gallery-image-version "$VERSION"
    --target-regions $TARGET_REGIONS
    --replica-count "$REPLICA_COUNT"
    --managed-image "$DEV_VERSION_ID"
)

# Optional retention flags
if [[ -n "${END_OF_LIFE_DATE:-}" ]]; then
    PROMOTE_CMD+=(--end-of-life-date "$END_OF_LIFE_DATE")
fi
if [[ -n "${BLOCK_DELETION:-}" ]]; then
    PROMOTE_CMD+=(--block-deletion-before-end-of-life "$BLOCK_DELETION")
fi

if ! "${PROMOTE_CMD[@]}"; then
    fail "Promotion failed during 'az sig image-version create'"
fi

ok "Image version created in PROD"

# ─── Step 2: Verify replication ──────────────────────────────────────────────

info "Verifying replication status..."
REPLICATION=$(az sig image-version show \
    --resource-group "$PROD_RG" \
    --gallery-name "$PROD_GALLERY" \
    --gallery-image-definition "$IMAGE_DEF" \
    --gallery-image-version "$VERSION" \
    --expand ReplicationStatus \
    --query "replicationStatus.aggregatedState" -o tsv)

if [[ "$REPLICATION" != "Completed" ]]; then
    echo ""
    echo "⚠️  Replication is still in progress (state: $REPLICATION)"
    echo "    The image version exists but isn't yet available in all regions."
    echo "    Check progress with:"
    echo ""
    echo "    az sig image-version show \\"
    echo "      --resource-group $PROD_RG \\"
    echo "      --gallery-name $PROD_GALLERY \\"
    echo "      --gallery-image-definition $IMAGE_DEF \\"
    echo "      --gallery-image-version $VERSION \\"
    echo "      --expand ReplicationStatus \\"
    echo "      --query 'replicationStatus.summary[].{Region:region, State:state, Progress:progress}' \\"
    echo "      -o table"
    echo ""
else
    ok "Replication completed in all regions"
fi

# ─── Done ───────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  ✅ Promotion successful"
echo "════════════════════════════════════════════════════════════════════"
echo "  Source : $DEV_VERSION_ID"
echo "  Target : $PROD_VERSION_ID"
echo "  Log    : $LOG_FILE"
echo "════════════════════════════════════════════════════════════════════"
echo ""

log "Promotion complete: $IMAGE_DEF v$VERSION → PROD"

echo "Consumers can now reference this image as:"
echo "  $PROD_VERSION_ID"
echo ""
