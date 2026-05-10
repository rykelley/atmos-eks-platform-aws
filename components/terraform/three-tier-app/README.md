# Component: `three-tier-app`

Custom (non-vendored) Atmos / Terraform component that deploys the React +
Flask + Postgres reference app from the AWS Tip article, but driven entirely
by IaC instead of `kubectl apply`.

## What it creates

| Order | Resource                       | Replaces in the article         |
|-------|--------------------------------|---------------------------------|
| 1     | Namespace `3-tier-app-eks`     | `kubectl apply -f namespace.yaml` |
| 2     | `Service` (ExternalName) → RDS | Hand-edited `database-service.yaml` |
| 3     | `ConfigMap` (DB host / port)   | `configmap.yaml`                |
| 4     | `SecretStore` + `ExternalSecret` (AWS Secrets Manager → K8s Secret) | base64-encoded `secrets.yaml` |
| 5     | DB migration `Job`             | `migration_job.yaml`            |
| 6     | Backend `Deployment` + `Service` | `backend.yaml`                |
| 7     | Frontend `Deployment` + `Service` | `frontend.yaml`              |
| 8     | cert-manager `Certificate`     | Steps 6–8 of the HTTPS section  |
| 9     | `Ingress` (ALB + HTTPS)        | `ingress.yaml` / `ingress-with-tls.yaml` |

## Inputs (most-edited)

| Variable               | What for                                         |
|------------------------|--------------------------------------------------|
| `hostname_template`    | Public hostname; usually `app.<stage>.<domain>`  |
| `cluster_issuer`       | `letsencrypt-staging` while iterating, `prod` once stable |
| `backend_tag` / `frontend_tag` | Roll the app forward by changing the tag |
| `run_db_migration_job` | Set false to skip migrations on a no-op apply     |

## Remote-state dependencies

This component reads the outputs of two sibling components via Cloud Posse's
`stack-config/yaml/remote-state` module:

- `eks/cluster` — for the cluster endpoint and CA cert (used by the
  Kubernetes/Helm providers)
- `rds` — for the DB endpoint, db name, username, and the ARN of the master
  password Secret in AWS Secrets Manager

Make sure both are applied before this component.
