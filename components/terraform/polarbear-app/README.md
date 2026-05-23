# Component: `polarbear-app`

Deploys [polar-bear-club-site](https://github.com/rykelley/polar-bear-club-site)
(Next.js 15 standalone) onto EKS.

## What it creates

| # | Resource | Notes |
|---|---|---|
| 1 | `aws_iam_user` + `aws_iam_access_key` + `aws_iam_user_policy` | Scoped to the `s3-bucket` component's bucket only |
| 2 | `aws_secretsmanager_secret` `<ns>/<stage>/polarbear-app/aws` | Managed by Terraform — holds the IAM user keys + bucket name + region |
| 3 | `aws_secretsmanager_secret` `<ns>/<stage>/polarbear-app/integrations` | Created empty — populate values via console / CLI (see `docs/secrets-bootstrap.md`) |
| 4 | `Namespace` `polarbear-app` | |
| 5 | `ConfigMap` `app-config` | All non-secret env vars from `var.env_config` |
| 6 | `ConfigMap` `db-init-schema` | Postgres schema DDL mounted into init container |
| 7 | `SecretStore` `aws-secrets-manager` | Uses ESO's IRSA SA in `external-secrets` namespace |
| 8 | `ExternalSecret` `app-secrets-aws` | Pulls TF-managed AWS keys |
| 9 | `ExternalSecret` `app-secrets-integrations` | Pulls user-populated 3rd-party keys |
| 10 | `ExternalSecret` `db-secrets` | Pulls RDS-managed DB password + builds Postgres URLs |
| 11 | `Deployment` `polarbear-app` | initContainer runs `psql -f /schema/schema.sql`; app container runs Next.js |
| 12 | `Service` `polarbear-app` (ClusterIP :3000) | |
| 13 | cert-manager `Certificate` `app-tls` | DNS-01 → Let's Encrypt |
| 14 | `Ingress` `polarbear-app` (alb) | HTTPS + HTTP→HTTPS redirect |

## Inputs (most-edited)

| Variable | Default | Notes |
|---|---|---|
| `image` | `ghcr.io/rykelley/polar-bear-club-site` | GHCR repo |
| `image_tag` | `latest` | Bump to roll a new release |
| `image_pull_secret_name` | `""` | Set to a pre-created dockerconfigjson Secret if GHCR repo is private |
| `hostname` | `app.dev.thepolarbearclub3d.com` | Apex `thepolarbearclub3d.com` in prod |
| `cluster_issuer` | `letsencrypt-prod` | Use `letsencrypt-staging` while iterating |
| `replicas` | `2` | |
| `env_config` | (see catalog) | Non-secret env → ConfigMap |
| `env_secrets` | (see catalog) | Maps K8s env-var name → JSON property in the `integrations` secret |
| `db_schema_sql` | (see catalog) | Postgres-compatible schema applied by init container |
| `run_db_schema_init` | `true` | Set false to skip the init container |

## Remote-state dependencies

This component reads outputs from three sibling components:

- `eks/cluster` — kubeconfig for the K8s/Helm providers
- `rds` — Postgres endpoint, credentials, and the ARN of the master password secret
- `s3-bucket` — bucket name + ARN, scoped IAM policy attachment

Apply order (encoded in `stacks/workflows/bootstrap.yaml`):
`eks/cluster` → `rds` → `s3-bucket` → `polarbear-app`.
