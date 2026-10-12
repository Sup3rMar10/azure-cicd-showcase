#!/usr/bin/env bash
# One-time bootstrap: everything Terraform and GitHub Actions need *before* the pipeline can run.
#   - resource group for the app (Terraform deploys INTO it, so CI never needs subscription-wide rights)
#   - storage account + container for remote Terraform state
#   - Entra app registration with GitHub OIDC federated credentials (no client secrets)
#   - least-privilege role assignments scoped to the app RG / state account
#
# Usage:  az login && ./scripts/bootstrap.sh <github-owner/repo>
set -euo pipefail

GH_REPO="${1:?usage: bootstrap.sh <github-owner/repo>}"
LOCATION="${LOCATION:-eastus}"
APP_RG="${APP_RG:-rg-invoice-prod}"
STATE_RG="${STATE_RG:-rg-tfstate}"
ENVIRONMENT="${ENVIRONMENT:-prod}"

SUB_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
# Storage names are global; derive a stable suffix from the subscription id.
SUFFIX="$(echo -n "$SUB_ID" | sha1sum | cut -c1-6)"
STATE_SA="sttfstate${SUFFIX}"

echo ">> Registering resource providers (no-op if already registered)"
for ns in Microsoft.App Microsoft.ContainerRegistry Microsoft.OperationalInsights Microsoft.Insights Microsoft.Storage; do
  az provider register --namespace "$ns" --wait -o none
done

echo ">> Resource groups"
az group create -n "$APP_RG" -l "$LOCATION" -o none
az group create -n "$STATE_RG" -l "$LOCATION" -o none

echo ">> Terraform state storage ($STATE_SA)"
az storage account create -n "$STATE_SA" -g "$STATE_RG" -l "$LOCATION" \
  --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false \
  --allow-shared-key-access false -o none
# Management-plane call: works without data-plane blob rights (shared keys are disabled on this account).
az storage container-rm create --storage-account "$STATE_SA" -g "$STATE_RG" -n tfstate -o none
STATE_SA_ID="$(az storage account show -n "$STATE_SA" -g "$STATE_RG" --query id -o tsv)"

echo ">> Entra app registration for GitHub OIDC"
APP_NAME="sp-github-${GH_REPO//\//-}"
CLIENT_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [[ -z "$CLIENT_ID" ]]; then
  CLIENT_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
  az ad sp create --id "$CLIENT_ID" -o none
fi

add_cred() { # name subject
  az ad app federated-credential create --id "$CLIENT_ID" --parameters "{
    \"name\": \"$1\", \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"$2\", \"audiences\": [\"api://AzureADTokenExchange\"]}" -o none 2>/dev/null \
    || echo "   (credential $1 already exists)"
}
add_cred "gh-env-${ENVIRONMENT}" "repo:${GH_REPO}:environment:${ENVIRONMENT}"
add_cred "gh-pull-request"       "repo:${GH_REPO}:pull_request"

echo ">> Role assignments (scoped, not subscription-wide)"
APP_RG_ID="$(az group show -n "$APP_RG" --query id -o tsv)"
for role in "Contributor" "User Access Administrator"; do   # UAA lets Terraform create the AcrPull assignment
  az role assignment create --assignee "$CLIENT_ID" --role "$role" --scope "$APP_RG_ID" -o none || true
done
az role assignment create --assignee "$CLIENT_ID" --role "Storage Blob Data Contributor" \
  --scope "$STATE_SA_ID" -o none || true

echo ">> Configuring GitHub repo variables"
if command -v gh >/dev/null; then
  gh variable set AZURE_CLIENT_ID       -b "$CLIENT_ID"       -R "$GH_REPO"
  gh variable set AZURE_TENANT_ID       -b "$TENANT_ID"       -R "$GH_REPO"
  gh variable set AZURE_SUBSCRIPTION_ID -b "$SUB_ID"          -R "$GH_REPO"
  gh variable set TF_STATE_RG           -b "$STATE_RG"        -R "$GH_REPO"
  gh variable set TF_STATE_SA           -b "$STATE_SA"        -R "$GH_REPO"
  gh variable set APP_RG                -b "$APP_RG"          -R "$GH_REPO"
  echo "   set via gh CLI"
else
  cat <<EOF
   gh CLI not found. Add these as *repository variables* (Settings > Secrets and variables > Actions):
     AZURE_CLIENT_ID=$CLIENT_ID
     AZURE_TENANT_ID=$TENANT_ID
     AZURE_SUBSCRIPTION_ID=$SUB_ID
     TF_STATE_RG=$STATE_RG
     TF_STATE_SA=$STATE_SA
     APP_RG=$APP_RG
EOF
fi

echo
echo "Done. Next: create a GitHub Environment named '${ENVIRONMENT}' (add required reviewers for a manual approval gate), then push to main."
