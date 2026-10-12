# Azure Setup Walkthrough

Step-by-step guide to take this repo from "code on GitHub" to "live URL deployed by the pipeline".
Expect about 30 minutes the first time. Commands assume **Git Bash** (installed with Git for Windows).
Run them from the repo root unless stated otherwise.

```
Azure account → install az CLI → az login → bootstrap.sh → GitHub environment → push → verify
```

---

## 0. Decide which Azure account to use

Use a **personal** Azure account, not an employer's tenant.

- Employer tenants usually block creating app registrations or resource groups.
- Mixing a personal showcase with a company subscription is a bad idea, and you may not be allowed to keep it.

Create a free account at https://azure.microsoft.com/free. It needs a phone number and a credit card for identity checks. You get a credit for the first 30 days, and this project costs roughly a few dollars a month at idle.

You also need a **subscription**. The free account creates one for you.

## 1. Install the tools

```bash
winget install Microsoft.AzureCLI     # then close and reopen Git Bash
az version                            # confirm it works
gh auth status                        # already logged in as Sup3rMar10
```

You do **not** need Terraform locally. The pipeline runs it. Install it later (`winget install Hashicorp.Terraform`) only if you want to run `terraform plan` yourself.

## 2. Log in to Azure

```bash
az login                              # opens a browser
az account list -o table              # check you see your personal subscription
az account set --subscription "<name or id>"   # only if you have more than one
az account show --query "{name:name, id:id, tenant:tenantId}" -o table
```

Make sure the subscription shown is the one you want to be billed.

You need **Owner** (or Contributor + User Access Administrator) on it. On a fresh free account you have this automatically.

## 3. Run the bootstrap script (one time)

```bash
./scripts/bootstrap.sh Sup3rMar10/azure-cicd-showcase
```

What it does, in order:

| Step | Creates | Why |
|---|---|---|
| Register providers | `Microsoft.App`, `ContainerRegistry`, `OperationalInsights`, `Insights`, `Storage` | New subscriptions often have these off, which causes `MissingSubscriptionRegistration` errors later. This takes 1-3 minutes. |
| Resource groups | `rg-invoice-prod` (the app) and `rg-tfstate` (state) | Terraform deploys into the app group, so CI never needs subscription-wide rights. |
| State storage | Storage account `sttfstate<hash>` with a `tfstate` container | Terraform remote state, with shared keys disabled (Entra auth only). |
| App registration | Entra app `sp-github-Sup3rMar10-azure-cicd-showcase` | The identity GitHub Actions uses. |
| Federated credentials | Trust for `environment:prod` and `pull_request` on your repo | This is the "no secrets" part. Azure only accepts tokens from your repo's jobs. |
| Role assignments | Contributor + User Access Administrator on `rg-invoice-prod`; Blob Data Contributor on the state account | Least privilege. |
| GitHub variables | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `TF_STATE_RG`, `TF_STATE_SA`, `APP_RG` | Set through `gh`. None are secrets, since OIDC needs no client secret. |

The script is safe to re-run.

Change the region if needed: `LOCATION=westus2 ./scripts/bootstrap.sh Sup3rMar10/azure-cicd-showcase`

Verify:

```bash
gh variable list                                        # should list 6 variables
az group list --query "[].name" -o tsv                  # rg-invoice-prod, rg-tfstate
```

## 4. Create the `prod` GitHub environment

The deploy job references `environment: prod`, and the Azure trust is tied to that name. If the environment doesn't exist, GitHub creates it automatically on first use, but create it now so you can configure it:

```bash
gh api -X PUT repos/Sup3rMar10/azure-cicd-showcase/environments/prod
```

Optional but impressive in an interview, a **manual approval gate**: in GitHub go to *Settings → Environments → prod → Required reviewers* and add yourself.

> Required reviewers on a **private** repo need a paid GitHub plan. On the free plan, make the repo public to use them (`gh repo edit --visibility public --accept-visibility-change-consequences`). That's also what you want for sharing it with interviewers.

Optional: get an email on 5xx errors.

```bash
gh variable set ALERT_EMAIL -b "you@example.com"
```

## 5. Run the pipeline

```bash
git push origin main                  # or: gh workflow run Deploy
gh run watch                          # live progress in the terminal
```

What happens:

1. **CI** runs lint, tests, an image build, Trivy scans, and `terraform validate`.
2. The **deploy** job waits for your approval if you set reviewers.
3. It creates the registry, pushes the image tagged with the commit SHA, applies the full Terraform stack, then smoke-tests `/health`.

The first run takes about 8-12 minutes, mostly creating the Container Apps environment. Later runs take 3-4 minutes.

## 6. Verify it works

The URL is in the run's job summary, or:

```bash
az extension add --name containerapp --upgrade -y
URL=$(az containerapp show -n ca-invoice-prod -g rg-invoice-prod --query properties.configuration.ingress.fqdn -o tsv)

curl https://$URL/health
curl -X POST https://$URL/invoices -H "Content-Type: application/json" -d '{"customer":"Acme","amount_cents":12500}'
curl -X POST https://$URL/invoices/1/pay
curl https://$URL/docs               # interactive Swagger UI, good for demos
```

The first request after idle takes a few seconds, because the app scales to zero.

Things to show an interviewer in the Azure portal (`rg-invoice-prod`):

- **Container App → Revisions**: one per deploy, named after the commit.
- **Log Analytics → Logs**: query `ContainerAppConsoleLogs_CL | take 20`.
- **Container Registry → Repositories**: images tagged with git SHAs.
- **Access control (IAM)** on the registry: the app's managed identity has only `AcrPull`.

## 7. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `AADSTS70021: No matching federated identity record` | The token's subject doesn't match. Check the repo name/case passed to bootstrap, and that the job uses `environment: prod`. |
| `AuthorizationFailed ... roleAssignments/write` | User Access Administrator wasn't assigned. Re-run `bootstrap.sh`, then wait about 2 minutes for propagation. |
| `MissingSubscriptionRegistration` | Run `az provider register --namespace Microsoft.App --wait` (same for the other providers). |
| `Error acquiring the state lock` | A cancelled run left the lock. Confirm nothing is running, then `terraform force-unlock <id>` from `infra/`. |
| Image pull `unauthorized` on first deploy | The AcrPull role was still propagating. Re-run the workflow. |
| Environment creation fails with a quota or region error | Free subscriptions have regional limits. Re-bootstrap with `LOCATION=eastus2` or `westus2`, and update the `APP_RG` variable. |
| Smoke test times out | `az containerapp logs show -n ca-invoice-prod -g rg-invoice-prod --follow` to see why the container isn't starting. |
| `terraform fmt -check` fails in CI | Run `terraform fmt -recursive` in `infra/` and commit. |
| Workflow can't find `vars.*` | Variables are set per repo. Run `gh variable list` to check. |

## 8. Cost and teardown

Idle cost is mostly the Basic container registry (about $5/month) plus a little Log Analytics. Container Apps scales to zero.

When you're done interviewing, or want to pause spending:

```bash
./scripts/teardown.sh                              # deletes both resource groups
az ad app list --display-name sp-github --query "[].appId" -o tsv   # then:
az ad app delete --id <appId>                      # removes the OIDC identity
```

Re-running `bootstrap.sh` and the pipeline recreates everything from scratch, which is a nice repeatability demo.

---

## Interview checklist

- [ ] One green run of the **Deploy** workflow, with the Actions page ready to show
- [ ] Repo is **public** and the README renders the architecture diagram
- [ ] You can explain the OIDC trust, least-privilege roles, the registry bootstrap trade-off, and what you'd improve next (see README)
- [ ] A PR open with a visible `terraform plan` in its summary, to show the review flow
- [ ] Teardown tested, so you can show it's reproducible and not leaving resources running
