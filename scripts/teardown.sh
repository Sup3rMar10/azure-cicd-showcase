#!/usr/bin/env bash
# Delete everything the project created, to stop all spend after an interview.
set -euo pipefail
APP_RG="${APP_RG:-rg-invoice-prod}"
STATE_RG="${STATE_RG:-rg-tfstate}"
read -r -p "Delete resource groups '$APP_RG' and '$STATE_RG'? [y/N] " ans
[[ "$ans" == "y" ]] || exit 1
az group delete -n "$APP_RG" --yes --no-wait
az group delete -n "$STATE_RG" --yes --no-wait
echo "Deletion started. Also delete the Entra app registration 'sp-github-*' if you no longer need it."
