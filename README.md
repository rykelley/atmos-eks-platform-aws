# atmos-eks-platform-aws

Production-grade Infrastructure-as-Code for running the
[`polar-bear-club-site`](https://github.com/rykelley/polar-bear-club-site)
Next.js app on AWS EKS — built with the [Atmos](https://atmos.tools)
framework on top of
[Cloud Posse's `terraform-aws-components`](https://github.com/cloudposse/terraform-aws-components).

The platform layer (VPC, EKS, IRSA, ALB Controller, cert-manager,
ExternalDNS, ExternalSecrets, RDS Postgres, S3) is the IaC translation
of the AWS Tip article
*["Real-world Kubernetes project on AWS EKS (2026)"](https://awstip.com/real-world-kubernetes-project-on-aws-eks-deploy-a-production-3-tier-app-with-https-2026-16dc13217dcf)*.
The app on top of it is your real Next.js site.

> **TL;DR**
>
> ```bash
> atmos vendor pull
> atmos workflow apply-all -f bootstrap -s plat-platform-usw2-dev
> # populate the integrations secret (see docs/secrets-bootstrap.md), then:
> kubectl rollout restart deployment polarbear-app -n polarbear-app
> ```
>
> …gives you a managed EKS cluster, RDS Postgres in private subnets, an
> S3 bucket for uploads, the AWS Load Balancer Controller, cert-manager,
> ExternalDNS, ExternalSecrets, and the polar-bear-club-site Next.js app
> reachable at `https://app.dev.thepolarbearclub3d.com` (dev) or
> `https://thepolarbearclub3d.com` (prod).

---

## Table of contents

1. [Architecture](#architecture)
2. [Prerequisites](#prerequisites)
3. [First-time customization](#first-time-customization-required)
4. [Repo layout](#repo-layout)
5. [Atmos concepts in 5 minutes](#atmos-concepts-in-5-minutes)
6. [Stack naming](#stack-naming)
7. [Quick start (deploy)](#quick-start-deploy)
8. [The polar-bear-club-site app](#the-polar-bear-club-site-app)
   - [How the image gets built](#how-the-image-gets-built)
   - [Env vars: ConfigMap vs Secret](#env-vars-configmap-vs-secret)
   - [DB schema initialization](#db-schema-initialization)
   - [Rolling a new image](#rolling-a-new-image)
9. [Customizing the platform](#customizing-the-platform)
   - [Change the domain](#change-the-domain)
   - [Add or remove a region](#add-or-remove-a-region)
   - [Add a new stage (e.g. sandbox)](#add-a-new-stage)
   - [Add a new account](#add-a-new-account)
   - [Resize EKS nodes](#resize-eks-nodes)
   - [Resize / harden RDS](#resize--harden-rds)
   - [Switch from Let's Encrypt staging → prod](#switch-from-lets-encrypt-staging--prod)
   - [Add a new EKS addon](#add-a-new-eks-addon)
   - [Add a brand-new component](#add-a-brand-new-component)
   - [Bump Cloud Posse component versions](#bump-cloud-posse-component-versions)
10. [Day-2 operations](#day-2-operations)
11. [CI/CD](#cicd)
12. [Mapping article → component](#mapping-article--component)
13. [Troubleshooting](#troubleshooting)
14. [FAQ](#faq)

---

## Architecture

```
   ghcr.io/rykelley/polar-bear-club-site:<tag>
                  │
                  │ (pulled by kubelet)
                  ▼
       Internet ─► ALB (HTTPS, ACM/Let's Encrypt)
                            │
                            ▼
                      Ingress (alb)
                            │
                            ▼
                ┌─────────────────────────┐
                │ Deployment polarbear-app│
                │ ┌─────────────────────┐ │
                │ │ initContainer (psql)│ │ → applies schema, then exits
                │ │   ↓                 │ │
                │ │ container (next.js) │ │ → port 3000, /api/healthcheck
                │ └─────────────────────┘ │
                └────────┬────────────────┘
                         │
        ┌────────────────┼─────────────────────────┐
        ▼                ▼                         ▼
   RDS Postgres     S3 bucket               AWS Secrets Manager
   (private        (private,                ┌──────────────────────┐
    subnets)        IAM-scoped)             │ /polarbear-app/aws   │ ← Terraform-managed
                         ▲                  │ /polarbear-app/      │   (S3 keys)
                         │                  │   integrations       │ ← user-populated
                    IAM user                └──────────────────────┘
                    (S3-only)                          │
                                                       │
                                              ExternalSecrets Operator
                                                       │
                                                       ▼
                                              K8s Secrets in cluster
                                              → envFrom on the Pod
```

See [`docs/architecture.md`](docs/architecture.md) for the dependency
graph and multi-account topology.

---

## Prerequisites

### Local tools

| Tool       | Version  | Install                                   |
|------------|----------|-------------------------------------------|
| atmos      | ≥ 1.100  | `brew install cloudposse/tap/atmos`       |
| terraform  | ≥ 1.5    | `brew install terraform`                  |
| awscli     | ≥ 2.15   | `brew install awscli`                     |
| kubectl    | ≥ 1.30   | `brew install kubectl`                    |
| helm       | ≥ 3.14   | `brew install helm`                       |
| gh (CI)    | ≥ 2.50   | `brew install gh` (only for CI bootstrap) |

### AWS

- An AWS account (or three — dev/staging/prod) with administrative access
- `aws configure sso` or `aws configure` set up locally
- A registered public domain name (this repo is preconfigured for
  `thepolarbearclub3d.com` — see [Change the domain](#change-the-domain))

### App-side

- The polar-bear-club-site repo set up to push to GHCR. See
  [How the image gets built](#how-the-image-gets-built) and the
  ready-to-copy workflow in [`docs/app-ci-example.yaml`](docs/app-ci-example.yaml).
- Values for any 3rd-party integrations you actually use
  (Resend, Stripe, OAuth). See [`docs/secrets-bootstrap.md`](docs/secrets-bootstrap.md).

---

## First-time customization (REQUIRED)

Before `atmos vendor pull`, do a find-and-replace pass. There are
**only 6 places** that need real values — everything else flows from them.

| File | What to change | Currently |
|---|---|---|
| `stacks/mixins/stage/dev.yaml`     | `account_id` | `"111111111111"` |
| `stacks/mixins/stage/staging.yaml` | `account_id` | `"222222222222"` |
| `stacks/mixins/stage/prod.yaml`    | `account_id` | `"333333333333"` |
| `stacks/catalog/dns-primary.yaml`  | `domain_names[0]` | `thepolarbearclub3d.com` |
| `stacks/catalog/eks/cert-manager.yaml` | Email in `cert_manager_issuer_support_email_template` | `[email protected]` |
| `stacks/catalog/polarbear-app.yaml` | `image` (GHCR repo path) | `ghcr.io/rykelley/polar-bear-club-site` |

If you only have one account for now, point all three stages at the same
ID — that's a perfectly valid starting topology.

Also: open `atmos.yaml` and edit the `integrations.github.gitops` section
if you want to use the included CI workflows; replace the `000000000000`
placeholder account ID with whichever account holds your `gitops-*` IAM
roles and your plan-storage S3 bucket.

---

## Repo layout

```
atmos-eks-platform-aws/
├── atmos.yaml              # Atmos CLI config (paths, GHA integration)
├── vendor.yaml             # Pulls Cloud Posse components (run `atmos vendor pull`)
│
├── components/
│   └── terraform/
│       ├── tfstate-backend/                     # vendored
│       ├── account-map/                         # vendored
│       ├── vpc/                                 # vendored (subnet tags pre-set)
│       ├── vpc-flow-logs-bucket/                # vendored
│       ├── dns-primary/                         # vendored
│       ├── dns-delegated/                       # vendored
│       ├── acm/                                 # vendored
│       ├── eks/cluster/                         # vendored (1.31, IRSA on)
│       ├── eks/karpenter/                       # vendored
│       ├── eks/karpenter-node-pool/             # vendored
│       ├── eks/aws-load-balancer-controller/    # vendored
│       ├── eks/cert-manager/                    # vendored
│       ├── eks/external-dns/                    # vendored
│       ├── eks/external-secrets-operator/       # vendored
│       ├── eks/metrics-server/                  # vendored
│       ├── rds/                                 # vendored
│       ├── s3-bucket/                           # vendored — app uploads
│       └── polarbear-app/                       # custom — the actual app
│
├── stacks/
│   ├── catalog/                                  # reusable component defaults
│   │   ├── polarbear-app.yaml                   # ← edit env_config / env_secrets here
│   │   └── ... (12 others)
│   ├── mixins/
│   │   ├── region/  { us-west-2, us-east-1, global }
│   │   └── stage/   { dev, staging, prod }
│   ├── workflows/                                # native atmos workflows
│   │   ├── bootstrap.yaml  { apply-all, apply-global, apply-foundation, apply-addons, apply-app }
│   │   ├── destroy.yaml    { destroy-all, destroy-app-only, destroy-app-and-data, destroy-cluster-only }
│   │   ├── plan.yaml       { plan-all, plan-foundation, plan-addons, plan-app }
│   │   └── lint.yaml       { validate, describe-dev, list }
│   └── orgs/plat/platform/
│       ├── dev/   { _defaults, global-region, us-west-2 }
│       └── prod/  { _defaults, global-region, us-west-2 }
│
├── .github/workflows/
│   ├── atmos-validate.yaml      # lint stacks on every PR
│   ├── atmos-plan.yaml          # plan affected components on PR
│   └── atmos-apply.yaml         # apply on merge to main
│
└── docs/
    ├── runbook.md               # Day-1 deploy walkthrough
    ├── architecture.md          # Inheritance + dependency diagrams
    ├── troubleshooting.md       # Article's gotchas, pre-solved
    ├── secrets-bootstrap.md     # How to populate the integrations secret
    └── app-ci-example.yaml      # Sample GHA workflow for the app repo
```

---

## Atmos concepts in 5 minutes

Atmos separates **components** (Terraform code) from **stacks** (the
configuration that says "deploy this component to this account/region/stage
with these vars").

```
┌─────────────────────┐                ┌──────────────────────┐
│  components/        │                │  stacks/             │
│  terraform/eks/     │   ─consumes─►  │  catalog/eks/        │
│  cluster/           │                │  cluster.yaml        │
│  (.tf files)        │                │  (defaults)          │
└─────────────────────┘                └──────────┬───────────┘
                                                  │ imported by
                                                  ▼
                                       ┌──────────────────────┐
                                       │  stacks/orgs/plat/   │
                                       │  platform/dev/       │
                                       │  us-west-2.yaml      │
                                       │  (overrides)         │
                                       └──────────────────────┘
```

Three things you should know:

1. **Catalog files** in `stacks/catalog/` declare component defaults as
   `metadata.type: abstract` — they're never used directly, only inherited.
2. **Mixin files** in `stacks/mixins/` hold cross-cutting overrides
   (per-stage, per-region) and are imported by top-level stacks.
3. **Top-level stacks** in `stacks/orgs/<org>/<tenant>/<stage>/<region>.yaml`
   are the only files Atmos discovers. They `import:` everything they need
   and produce a fully-merged config that `atmos terraform ...` acts on.

The merge order is **last-wins**, with deepest specialization winning.
So `stacks/orgs/plat/platform/dev/us-west-2.yaml` overrides
`stacks/mixins/stage/dev.yaml` overrides `stacks/catalog/polarbear-app.yaml`.

`atmos describe component polarbear-app -s plat-platform-usw2-dev` shows you
the final merged result for any component in any stack.

---

## Stack naming

`atmos.yaml` sets the stack name pattern to:

```
{namespace}-{tenant}-{environment}-{stage}
```

So with `namespace: plat`, `tenant: platform`, `environment: usw2`,
`stage: dev`, the stack is **`plat-platform-usw2-dev`**.

| Stack                          | Account | Region    | Purpose                       |
|--------------------------------|---------|-----------|-------------------------------|
| `plat-platform-gbl-dev`        | dev     | global    | Delegated subzone, IAM        |
| `plat-platform-usw2-dev`       | dev     | us-west-2 | Full app stack                |
| `plat-platform-gbl-prod`       | prod    | global    | Apex Route53 zone             |
| `plat-platform-usw2-prod`      | prod    | us-west-2 | Full app stack (prod-grade)   |

```bash
atmos list stacks
atmos list components -s plat-platform-usw2-dev
```

---

## Quick start (deploy)

```bash
# 1. Vendor Cloud Posse components into ./components/terraform/
atmos vendor pull

# 2. Validate everything parses
atmos workflow validate -f lint

# 3. Pre-flight: see what would be deployed
atmos describe stacks -s plat-platform-usw2-dev | less
atmos workflow plan-all -f plan -s plat-platform-usw2-dev

# 4. (Once per account) Bootstrap the apex / delegated DNS zone
atmos workflow apply-global -f bootstrap -s plat-platform-gbl-prod   # apex zone
atmos workflow apply-global -f bootstrap -s plat-platform-gbl-dev    # delegated dev subzone

# 5. Bootstrap the regional stack (foundation → cluster → addons → app)
atmos workflow apply-all -f bootstrap -s plat-platform-usw2-dev

# 6. Wire kubectl
aws eks update-kubeconfig \
  --region us-west-2 \
  --name "$(atmos terraform output eks/cluster -s plat-platform-usw2-dev -- eks_cluster_id)"

# 7. Populate the 3rd-party integrations secret (Resend, Stripe, OAuth, …)
#    See docs/secrets-bootstrap.md for the JSON structure
aws secretsmanager put-secret-value \
  --region us-west-2 \
  --secret-id plat/dev/polarbear-app/integrations \
  --secret-string file://./integrations.json

kubectl annotate externalsecret app-secrets-integrations \
  -n polarbear-app force-sync=$(date +%s) --overwrite
kubectl rollout restart deployment polarbear-app -n polarbear-app

# 8. Verify
kubectl get pods -n polarbear-app
kubectl get ingress -n polarbear-app
curl -I https://app.dev.thepolarbearclub3d.com
```

Detailed walkthrough: [`docs/runbook.md`](docs/runbook.md).
Stuck? See [`docs/troubleshooting.md`](docs/troubleshooting.md).

### Workflow cheat-sheet

| Command                                                              | What it does                                            |
|----------------------------------------------------------------------|---------------------------------------------------------|
| `atmos workflow apply-all -f bootstrap -s <stack>`                   | Full regional bootstrap                                 |
| `atmos workflow apply-global -f bootstrap -s <stack>`                | Just the global (DNS) stack                             |
| `atmos workflow apply-foundation -f bootstrap -s <stack>`            | VPC + cluster + RDS + S3 only                           |
| `atmos workflow apply-addons -f bootstrap -s <stack>`                | Just the EKS addons                                     |
| `atmos workflow apply-app -f bootstrap -s <stack>`                   | Just polarbear-app (assumes infra is up)                |
| `atmos workflow plan-all -f plan -s <stack>`                         | Dry-run for the full bootstrap                          |
| `atmos workflow plan-app -f plan -s <stack>`                         | Dry-run only the app                                    |
| `atmos workflow destroy-all -f destroy -s <stack>`                   | Tear everything down                                    |
| `atmos workflow destroy-app-only -f destroy -s <stack>`              | Reset the app (keep cluster + data)                     |
| `atmos workflow destroy-app-and-data -f destroy -s <stack>`          | App + RDS + S3                                          |
| `atmos workflow destroy-cluster-only -f destroy -s <stack>`          | Recreate cluster, keep data                             |
| `atmos workflow validate -f lint`                                    | Lint every stack file                                   |
| `atmos workflow list -f lint`                                        | List every stack and component                          |
| `atmos terraform apply <component> -s <stack>`                       | Surgical: apply one component                           |
| `atmos terraform plan <component> -s <stack>`                        | Surgical: plan one component                            |
| `atmos describe component <component> -s <stack>`                    | Show resolved vars for one component                    |

---

## The polar-bear-club-site app

### How the image gets built

This IaC repo does NOT build the app image. The app repo
(`polar-bear-club-site`) is responsible for:

1. Building the Docker image from its existing `Dockerfile`
2. Tagging with the commit SHA + `latest`
3. Pushing to **`ghcr.io/<owner>/polar-bear-club-site`**

A drop-in GitHub Actions workflow that does all three is provided at
[`docs/app-ci-example.yaml`](docs/app-ci-example.yaml). Copy it to
`.github/workflows/build-and-push.yaml` in the polar-bear-club-site repo
and you're done.

> **Private GHCR images:** If your image is private, create a
> `dockerconfigjson` Secret in the `polarbear-app` namespace and set
> `image_pull_secret_name` in `stacks/catalog/polarbear-app.yaml`.
> The Cloud Posse pattern is to manage this via ESO from a Secrets
> Manager entry — open an issue if you want a worked example.

### Env vars: ConfigMap vs Secret

The app reads ~30 env vars (see `polar-bear-club-site/.env.example`).
Each one falls into exactly one of three buckets:

| Source              | Where to set it                                       | Example                                  |
|---------------------|-------------------------------------------------------|------------------------------------------|
| `ConfigMap` `app-config` | `env_config:` in `stacks/catalog/polarbear-app.yaml` (or per-stage stack) | `NODE_ENV`, `NEXT_PUBLIC_SITE`, `EMAIL_PROVIDER` |
| `Secret` `app-secrets-aws`            | Auto-managed by Terraform (S3 IAM keys + bucket name) | `AWS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET_NAME`, `AWS_REGION_NAME` |
| `Secret` `app-secrets-integrations`   | `env_secrets:` in catalog + populate JSON in AWS Secrets Manager (see [`docs/secrets-bootstrap.md`](docs/secrets-bootstrap.md)) | `AUTH_SECRET`, `RESEND_API_KEY`, `STRIPE_SECRET_KEY` |
| `Secret` `db-secrets`                 | Auto-built from RDS-managed master password secret    | `POSTGRES_DIRECT_URL`, `POSTGRES_SESSION_POOLED_URL`, `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_PORT` |

All four are mounted into the Pod via `envFrom`, so any env var in any of
them is visible to the Next.js process exactly as if it were in `.env`.

The catalog's `env_config` and `env_secrets` are the **only** files you
edit by hand. Everything else is wired automatically.

### DB schema initialization

The Pod has an **init container** (`postgres:15-alpine`) that runs
`psql -f /schema/schema.sql` against RDS before the Next.js process
starts. The schema is mounted from a ConfigMap built from
`var.db_schema_sql` in the catalog.

Why an init container instead of `npm run db:setup`? The app's
production Dockerfile rms `node_modules`, so `tsx` isn't available at
runtime. Idempotency is fine because the schema uses `CREATE TABLE IF
NOT EXISTS` everywhere.

> Note: the upstream `schema.sql` uses MySQL-style backticks for the
> `storage.key` column, which Postgres rejects. The catalog ships a
> Postgres-compatible variant that uses double-quoted identifiers.

### Rolling a new image

Two flows:

**Manual** — edit the catalog (or per-stage stack) and apply:

```yaml
# stacks/orgs/plat/platform/dev/us-west-2.yaml
components:
  terraform:
    polarbear-app:
      vars:
        image_tag: "v1.4.2"     # bump
```

```bash
atmos terraform apply polarbear-app -s plat-platform-usw2-dev
```

**Automatic** — uncomment the `bump-iac` job at the bottom of
`docs/app-ci-example.yaml`. After every image push it'll open a PR in
this repo bumping `image_tag`. When you merge, the `atmos-apply.yaml`
GHA in this repo deploys it.

---

## Customizing the platform

### Change the domain

There's exactly one source of truth for the apex domain:

```yaml
# stacks/catalog/dns-primary.yaml
components:
  terraform:
    dns-primary:
      vars:
        domain_names:
          - thepolarbearclub3d.com   # ← change me
```

Then update references in `stacks/orgs/plat/platform/{dev,prod}/global-region.yaml`
and the apex `dns-primary` block in `stacks/orgs/plat/platform/prod/global-region.yaml`.
Also update the `hostname` in `stacks/catalog/polarbear-app.yaml` and
the per-stage overrides in `stacks/orgs/plat/platform/{dev,prod}/us-west-2.yaml`.

Quick global rewrite:

```bash
LC_ALL=C find stacks docs README.md -type f \( -name '*.yaml' -o -name '*.md' \) \
  -exec sed -i '' 's/thepolarbearclub3d\.com/yourdomain.com/g' {} +
```

After applying `dns-primary`, point your registrar at the four NS
records that Route53 generated (output: `dns-primary.name_servers`).

### Add or remove a region

Atmos region = a mixin file. To add `us-east-1`:

1. The mixin already exists at `stacks/mixins/region/us-east-1.yaml`.
2. Create a new top-level stack file:
   ```bash
   cp stacks/orgs/plat/platform/dev/us-west-2.yaml \
      stacks/orgs/plat/platform/dev/us-east-1.yaml
   ```
3. In the new file, change the import from `mixins/region/us-west-2` to
   `mixins/region/us-east-1` and bump the VPC CIDR (e.g. `10.11.0.0/16`).
4. `atmos workflow validate -f lint` to confirm the new stack is discovered.
5. `atmos workflow apply-all -f bootstrap -s plat-platform-use1-dev`.

### Add a new stage

E.g. you want a `sandbox` stage between dev and staging.

1. Create the stage mixin at `stacks/mixins/stage/sandbox.yaml`
   (copy `dev.yaml`, update `stage:` and `account_id:`).
2. Create the account folder:
   ```bash
   mkdir -p stacks/orgs/plat/platform/sandbox
   cp stacks/orgs/plat/platform/dev/_defaults.yaml \
      stacks/orgs/plat/platform/sandbox/_defaults.yaml
   # edit the import to point at mixins/stage/sandbox
   cp stacks/orgs/plat/platform/dev/us-west-2.yaml \
      stacks/orgs/plat/platform/sandbox/us-west-2.yaml
   # edit the _defaults import path inside it
   ```
3. `atmos describe stacks -s plat-platform-usw2-sandbox` to confirm.

### Add a new account

E.g. spinning up a second tenant `data` (separate from `platform`).

1. Create the tenant defaults:
   ```bash
   mkdir -p stacks/orgs/plat/data
   cp stacks/orgs/plat/platform/_defaults.yaml \
      stacks/orgs/plat/data/_defaults.yaml
   # edit `tenant: data`
   ```
2. Add per-stage account folders the same way as for `platform`.
3. CI auto-discovers via `included_paths` in `atmos.yaml` (no edit).

### Resize EKS nodes

**Per-stage (recommended):**
```yaml
# stacks/mixins/stage/dev.yaml
components:
  terraform:
    eks/cluster:
      vars:
        node_groups:
          standard-workers:
            instance_types:
              - t3.large
            min_size: 2
            desired_size: 3
            max_size: 8
```

For autoscaling, flip Karpenter on:
```yaml
# stacks/orgs/plat/platform/<stage>/us-west-2.yaml
components:
  terraform:
    eks/karpenter:
      vars:
        enabled: true
```

### Resize / harden RDS

```yaml
# stacks/mixins/stage/prod.yaml
components:
  terraform:
    rds:
      vars:
        instance_class: db.m6g.xlarge
        multi_az: true
        deletion_protection: true
        skip_final_snapshot: false
        backup_retention_period: 30
        engine_version: "16.3"
```

```bash
atmos terraform apply rds -s plat-platform-usw2-prod
```

### Switch from Let's Encrypt staging → prod

```yaml
# stacks/orgs/plat/platform/dev/us-west-2.yaml  (or wherever)
components:
  terraform:
    polarbear-app:
      vars:
        cluster_issuer: "letsencrypt-prod"     # ← was "letsencrypt-staging"
```

```bash
atmos terraform apply polarbear-app -s plat-platform-usw2-dev
kubectl describe certificate app-tls -n polarbear-app
```

### Add a new EKS addon

E.g. install `cluster-autoscaler`:

1. Add to `vendor.yaml`:
   ```yaml
   - component: "eks/cluster-autoscaler"
     source: "github.com/cloudposse/terraform-aws-components.git//modules/eks/cluster-autoscaler?ref={{.Version}}"
     version: "1.520.0"
     targets:
       - "components/terraform/eks/cluster-autoscaler"
     tags: [eks-addon]
   ```
   `atmos vendor pull`.
2. Catalog defaults at `stacks/catalog/eks/cluster-autoscaler.yaml`
   with `metadata.type: abstract`.
3. Wire into top-level stacks:
   ```yaml
   import:
     - catalog/eks/cluster-autoscaler

   components:
     terraform:
       eks/cluster-autoscaler:
         metadata:
           component: eks/cluster-autoscaler
           inherits: [eks/cluster-autoscaler]
         vars: { enabled: true }
   ```
4. Add a step to the appropriate workflow under `stacks/workflows/`.
5. Apply.

### Add a brand-new component

For something Cloud Posse doesn't ship, follow the pattern of
`components/terraform/polarbear-app/`:

```
components/terraform/<your-component>/
├── versions.tf       # provider/version requirements
├── providers.tf      # AWS + (if needed) k8s providers
├── variables.tf      # input vars
├── context.tf        # null-label module (Cloud Posse standard)
├── remote-state.tf   # only if reading other components' outputs
├── main.tf           # the actual resources
├── outputs.tf
└── README.md
```

Then add a catalog file under `stacks/catalog/` and import it from the
appropriate top-level stacks.

### Bump Cloud Posse component versions

```bash
sed -i '' 's/version: "1.520.0"/version: "1.521.0"/g' vendor.yaml
atmos vendor pull
git diff components/terraform | less
atmos terraform plan eks/cluster -s plat-platform-usw2-dev
```

---

## Day-2 operations

```bash
# Inspect the merged config for a stack
atmos describe stacks -s plat-platform-usw2-dev

# Just one component's resolved vars
atmos describe component polarbear-app -s plat-platform-usw2-dev

# Plan only what would change
atmos terraform plan polarbear-app -s plat-platform-usw2-dev

# Tear down (reverse dependency order)
atmos workflow destroy-all -f destroy -s plat-platform-usw2-dev

# Reset only the app (keep cluster + data)
atmos workflow destroy-app-only -f destroy -s plat-platform-usw2-dev
```

`tfstate-backend` is intentionally not destroyed by `destroy-all` — drop
it manually only when fully decommissioning the account.

### Scaling cheat-sheet

| Want to…                          | Edit                                              |
|-----------------------------------|---------------------------------------------------|
| More node capacity                | `eks/cluster.node_groups.*.{min,desired,max}_size` in stage mixin |
| Burst-only capacity               | Enable `eks/karpenter` + add a `karpenter-node-pool` config |
| More app pods                     | `polarbear-app.replicas` in catalog or stage mixin |
| Bigger app pods                   | `polarbear-app.resources.{requests,limits}` |
| Bigger DB                         | `rds.instance_class` and `allocated_storage` in stage mixin |
| Survive an AZ failure             | `rds.multi_az: true` and ≥ 2 EKS node-group AZs   |
| Tighter network                   | `eks/cluster.cluster_endpoint_public_access: false` (prod default) |

---

## CI/CD

Three workflows under `.github/workflows/`:

| Workflow | Trigger | What it does |
|---|---|---|
| `atmos-validate.yaml` | every PR + push to main | `atmos validate stacks` + smoke test |
| `atmos-plan.yaml`     | every PR | Plans only affected components, posts to PR |
| `atmos-apply.yaml`    | push to main | Applies the saved plan from the matching PR |

Both plan/apply use Cloud Posse's
[github-action-atmos-affected-stacks](https://github.com/cloudposse/github-action-atmos-affected-stacks)
to figure out what changed in the PR.

You'll need OIDC roles in each AWS account named `atmos-gitops-plan` and
`atmos-gitops-apply`. The `atmos.yaml` `integrations.github.gitops`
block has the placeholder ARNs you should update.

The polar-bear-club-site repo gets its own workflow for building +
pushing the image to GHCR — see [`docs/app-ci-example.yaml`](docs/app-ci-example.yaml).

---

## Mapping article → component

| Article step                                      | Component / Stack                       |
|---------------------------------------------------|-----------------------------------------|
| `eksctl create cluster ... --managed`             | `eks/cluster`                           |
| Manual VPC + subnet tags for ALB                  | `vpc` (tags pre-applied)                |
| `aws rds create-db-subnet-group` + RDS instance   | `rds`                                   |
| `aws iam create-policy` + `eksctl create iamserviceaccount` for AWS LBC | `eks/aws-load-balancer-controller` (IRSA built in) |
| `helm install aws-load-balancer-controller`       | `eks/aws-load-balancer-controller`      |
| `aws ec2 create-tags ... kubernetes.io/role/elb=1` | `vpc` catalog (`public_subnets_additional_tags`) |
| `aws route53 create-hosted-zone`                  | `dns-primary` + `dns-delegated`         |
| `aws route53 change-resource-record-sets`         | `eks/external-dns` (annotation-driven)  |
| Manual cert-manager Helm install + IRSA           | `eks/cert-manager`                      |
| Hand-encoded base64 Secret for DB creds           | `eks/external-secrets-operator` + RDS-managed secret |
| `kubectl apply -f namespace/configmap/.../ingress`| `polarbear-app` (custom component)      |
| `acm import-certificate` workflow                 | Not needed — ALB uses ACM cert directly |

---

## Troubleshooting

The four failure modes the article calls out (DB unreachable, Ingress
no ADDRESS, cert pending, ALB 503) are pre-solved in IaC, but
[`docs/troubleshooting.md`](docs/troubleshooting.md) tells you how to
debug each one if you hit it anyway. Plus three new ones specific to
the polarbear-app deployment (init container failures, ESO sync errors,
ImagePullBackOff on a private GHCR image).

Quick recipes:

```bash
# Why did Atmos pick that value for that var?
atmos describe component polarbear-app -s plat-platform-usw2-dev --format json | jq .vars

# What stacks would a change to this catalog file affect?
git diff stacks/catalog/polarbear-app.yaml
atmos describe affected --ref HEAD~1 --format json | jq

# Did the init container actually run?
kubectl logs -n polarbear-app -l app=polarbear-app -c db-schema-init

# Force ESO to re-sync after editing the integrations secret
kubectl annotate externalsecret app-secrets-integrations \
  -n polarbear-app force-sync=$(date +%s) --overwrite
```

---

## FAQ

**Q: Can I use this with a single AWS account?**
Yes. Point all three stage mixins at the same `account_id`. You'll get
distinct stacks (`-dev`, `-staging`, `-prod`) all landing in one account.
Make sure VPC CIDRs in `stacks/orgs/plat/platform/<stage>/us-west-2.yaml`
don't overlap.

**Q: My image is private — how do I let the cluster pull from GHCR?**
Create a `dockerconfigjson` Secret in the `polarbear-app` namespace
(typed as `kubernetes.io/dockerconfigjson`) and set
`image_pull_secret_name` in `stacks/catalog/polarbear-app.yaml` to its
name. For a fully-IaC version, store the dockerconfigjson value in
Secrets Manager and add an ExternalSecret to materialize it.

**Q: Where does the app's `/api/healthcheck` come from?**
Next.js doesn't ship one out of the box — you'll want to add a tiny
`app/api/healthcheck/route.ts` in the polar-bear-club-site repo that
returns `200 OK`. Until it exists, set
`alb.ingress.kubernetes.io/healthcheck-path: "/"` in the catalog and
the readiness/liveness probes to `/`.

**Q: Can I add WAF / Shield to the ALB?**
Yes — `alb.ingress.kubernetes.io/wafv2-acl-arn: <arn>` annotation in
`stacks/catalog/polarbear-app.yaml::ingress_annotations`. Provision the
ACL via a new vendored component (Cloud Posse ships `waf`).

**Q: What about GitOps with Argo / Flux?**
This repo uses Terraform for the app to keep the example self-contained.
For real GitOps, swap the `polarbear-app` component for an
`argocd-application` component (vendor from
`cloudposse/terraform-aws-components/modules/eks/argocd-apps`) and let
Argo own the app manifests in the polar-bear-club-site repo.

**Q: How much will this cost in AWS?**
Rough monthly estimate for `plat-platform-usw2-dev` idle (us-west-2,
on-demand):
- EKS control plane: $73
- 2× t3.medium nodes: ~$60
- RDS db.t3.small + 20GB gp3: ~$30
- ALB: ~$20 + traffic
- NAT Gateway: ~$33 + traffic
- S3 (incl. requests + minimal storage): ~$1–5
- Route53 zones: ~$1
- Secrets Manager (3 secrets): ~$1.20
- Misc (CloudWatch, KMS): ~$5
- **Total: ~$225/mo idle** for the dev stack

**Q: Can I deploy a different app with this same platform?**
Absolutely — the platform layer (everything except `polarbear-app`)
is fully app-agnostic. Either swap out `polarbear-app` for a different
custom component, or vendor in
[`cloudposse/terraform-aws-components/modules/eks/argocd-apps`](https://github.com/cloudposse/terraform-aws-components/tree/main/modules/eks/argocd-apps)
and let Argo manage anything from a separate repo.

---

## License

MIT — do whatever you want with this. Cloud Posse's components retain
their own (Apache 2.0) license; check each vendored component's LICENSE
file after `atmos vendor pull`.
