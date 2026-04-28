#!/usr/bin/env bash
# =============================================================================
# destroy.sh — Clean destroy of Azure AI Foundry infrastructure
#
# FQDN outbound rules are child resources of the Hub. Azure processes their
# deletion sequentially (each triggers Azure Firewall reconfiguration), which
# takes 30+ minutes and often fails with 409 conflicts. Since Hub deletion
# cascade-deletes all child outbound rules automatically, we remove them from
# Terraform state before planning destroy.
#
# Usage:
#   ./scripts/destroy.sh          # Plan + apply destroy
#   ./scripts/destroy.sh --plan   # Plan only (review before applying)
# =============================================================================
set -euo pipefail

PLAN_ONLY=false
[[ "${1:-}" == "--plan" ]] && PLAN_ONLY=true

echo "=== Step 1: Remove FQDN rules from state (Hub cascade-deletes them) ==="
FQDN_RULES=$(terraform state list 2>/dev/null | grep 'azapi_resource.fqdn_' || true)
if [[ -n "$FQDN_RULES" ]]; then
  echo "$FQDN_RULES" | while read -r rule; do
    terraform state rm "$rule" 2>/dev/null && echo "  Removed: $rule" || echo "  Skip: $rule (not in state)"
  done
else
  echo "  No FQDN rules in state — nothing to remove."
fi

echo ""
echo "=== Step 2: Plan destroy ==="
terraform plan -destroy -out=main.destroy.tfplan

if [[ "$PLAN_ONLY" == "true" ]]; then
  echo ""
  echo "Plan saved to main.destroy.tfplan. Review and run:"
  echo "  terraform apply main.destroy.tfplan"
  exit 0
fi

echo ""
echo "=== Step 3: Apply destroy ==="
terraform apply main.destroy.tfplan

echo ""
echo "=== Destroy complete ==="
