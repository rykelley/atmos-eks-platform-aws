# Runbook — atmos-eks-platform-aws

Step-by-step walk-through to take this repo from a fresh clone to a
working HTTPS endpoint serving the polar-bear-club-site app at
`https://app.dev.thepolarbearclub3d.com`.

Everything here uses **native Atmos commands**. There's no Make wrapper —
all workflows are defined in `stacks/workflows/` and invoked with
`atmos workflow <name> -f <file> -s <stack>`.

---

## 0. Prerequisites

```bash
brew install cloudposse/tap/atmos
brew install terraform awscli kubectl helm
atmos version            # ≥ 1.100
terraform version        # ≥ 1.5
```

You'll need:

- AWS access for the target account (`AWS_PROFILE` or `aws sso login`)
- Domain `thepolarbearclub3d.com` — registrar configured to point at the
  apex zone created in `plat-platform-gbl-prod`
- The polar-bear-club-site repo wired to push images to GHCR
  (see [`docs/app-ci-example.yaml`](app-ci-example.yaml))

---

## 1. First-time bootstrap (per account)

The state backend is a chicken/egg: we need an S3 bucket + DynamoDB
table *before* Terraform can write state to it. Apply `tfstate-backend`
first with local state, then re-init to migrate state into the new bucket.

```bash
# Vendor the components into the working tree
atmos vendor pull

# Apply tfstate-backend with local state (no other components yet)
atmos terraform apply tfstate-backend -s plat-platform-usw2-dev

# Re-init pointing at the new S3 backend (migrates the local state up)
atmos terraform init tfstate-backend -s plat-platform-usw2-dev -- -migrate-state
```

`bootstrap.yaml` workflow assumes this migration has happened on first
run — re-applying `tfstate-backend` later is a no-op.

---

## 2. Apply order

The full dependency chain is encoded in `stacks/workflows/bootstrap.yaml`.

### One-shot regional bootstrap

```bash
STACK=plat-platform-usw2-dev

# Apply the global stack first if this is a fresh account
atmos workflow apply-global -f bootstrap -s plat-platform-gbl-prod   # apex (one-time)
atmos workflow apply-global -f bootstrap -s plat-platform-gbl-dev    # delegated subzone

# Then the full regional bootstrap
atmos workflow apply-all -f bootstrap -s $STACK
```

### Or step-by-step (handy for first-time understanding)

```bash
STACK=plat-platform-usw2-dev

atmos terraform apply tfstate-backend                   -s $STACK
atmos terraform apply vpc                               -s $STACK
atmos terraform apply dns-primary                       -s plat-platform-gbl-prod   # one-time
atmos terraform apply dns-delegated                     -s plat-platform-gbl-dev
atmos terraform apply acm                               -s $STACK
atmos terraform apply eks/cluster                       -s $STACK

# Wire kubectl to the new cluster
aws eks update-kubeconfig --region us-west-2 \
  --name "$(atmos terraform output eks/cluster -s $STACK -- eks_cluster_id)"

atmos terraform apply eks/aws-load-balancer-controller  -s $STACK
atmos terraform apply eks/external-dns                  -s $STACK
atmos terraform apply eks/cert-manager                  -s $STACK
atmos terraform apply eks/external-secrets-operator     -s $STACK
atmos terraform apply eks/metrics-server                -s $STACK
atmos terraform apply rds                               -s $STACK
atmos terraform apply s3-bucket                         -s $STACK
atmos terraform apply polarbear-app                     -s $STACK
```

---

## 3. Populate the integrations secret (once per stage)

After the first `polarbear-app` apply, an empty Secrets Manager secret
exists at `plat/dev/polarbear-app/integrations`. Populate it with your
real API keys:

```bash
cat > integrations.json <<EOF
{
  "AUTH_SECRET":         "$(openssl rand -base64 32)",
  "PRIVATE_ACCESS_KEY":  "$(openssl rand -base64 32)",
  "BASIC_AUTH_USERNAME": "admin",
  "BASIC_AUTH_PASSWORD": "$(openssl rand -base64 16)",
  "RESEND_API_KEY":      "re_...",
  "STRIPE_SECRET_KEY":   "sk_live_...",
  "STRIPE_WEBHOOK_SIG":  "whsec_..."
}
EOF

aws secretsmanager put-secret-value \
  --region us-west-2 \
  --secret-id plat/dev/polarbear-app/integrations \
  --secret-string file://./integrations.json

rm integrations.json   # don't leave it lying around

# Force ESO to re-sync (otherwise it polls hourly)
kubectl annotate externalsecret app-secrets-integrations \
  -n polarbear-app force-sync=$(date +%s) --overwrite

# Roll the Pods to pick up the new env
kubectl rollout restart deployment polarbear-app -n polarbear-app
```

Full guide: [`docs/secrets-bootstrap.md`](secrets-bootstrap.md).

---

## 4. Verify

```bash
kubectl get nodes
kubectl get pods -A | grep -E 'aws-load-balancer|cert-manager|external-dns|external-secrets'
kubectl get pods -n polarbear-app
kubectl get ingress -n polarbear-app
kubectl get certificate -n polarbear-app      # READY=True within ~2 min
```

DNS propagation:

```bash
dig +short app.dev.thepolarbearclub3d.com
```

Should resolve to the ALB hostname. Then:

```bash
curl -I https://app.dev.thepolarbearclub3d.com
```

`HTTP/2 200` → done.

---

## 5. Day-2 ops

### Roll the app forward

Edit `image_tag` in the catalog (or per-stage stack):

```yaml
# stacks/orgs/plat/platform/dev/us-west-2.yaml
components:
  terraform:
    polarbear-app:
      vars:
        image_tag: "v1.4.2"
```

```bash
atmos terraform apply polarbear-app -s plat-platform-usw2-dev
```

Or use the `bump-iac` job in `docs/app-ci-example.yaml` for fully
automated PR-based rollouts.

### Add a new env var

For a non-secret value:

```yaml
# stacks/catalog/polarbear-app.yaml (or per-stage)
components:
  terraform:
    polarbear-app:
      vars:
        env_config:
          NEW_FEATURE_FLAG: "true"
```

For a secret value:

1. Add the key to `env_secrets` in the catalog
2. Add the value to the Secrets Manager `integrations` secret
3. `atmos terraform apply polarbear-app -s plat-platform-usw2-dev`
4. `kubectl rollout restart deployment polarbear-app -n polarbear-app`

### Bump a Cloud Posse component

```bash
sed -i '' 's/version: "1.520.0"/version: "1.521.0"/g' vendor.yaml
atmos vendor pull
git diff components/terraform   # review the upgrade
atmos terraform plan eks/cluster -s plat-platform-usw2-dev
```

### Switch from Let's Encrypt staging → prod

```yaml
# stacks/orgs/plat/platform/dev/us-west-2.yaml
components:
  terraform:
    polarbear-app:
      vars:
        cluster_issuer: "letsencrypt-prod"   # was "letsencrypt-staging"
```

```bash
atmos terraform apply polarbear-app -s plat-platform-usw2-dev
```

### Tear it all down

```bash
# Full regional teardown (reverse dependency order)
atmos workflow destroy-all -f destroy -s plat-platform-usw2-dev

# Or just the app layer (keep cluster, RDS, S3)
atmos workflow destroy-app-only -f destroy -s plat-platform-usw2-dev

# Or app + data (keep cluster + addons)
atmos workflow destroy-app-and-data -f destroy -s plat-platform-usw2-dev

# Or recreate the cluster on a new K8s version (keep VPC, RDS, S3)
atmos workflow destroy-cluster-only -f destroy -s plat-platform-usw2-dev
```

`tfstate-backend` is intentionally not destroyed by `destroy-all` — drop
it manually only when fully decommissioning the account.

---

## 6. Useful one-liners

```bash
# Show every stack the repo defines
atmos workflow list -f lint

# Print the merged config for a stack (with all imports/mixins resolved)
atmos describe stacks -s plat-platform-usw2-dev

# Dump the resolved vars for one component
atmos describe component polarbear-app -s plat-platform-usw2-dev

# Plan everything in a stack (safe, read-only)
atmos workflow plan-all -f plan -s plat-platform-usw2-dev

# Plan only the app
atmos workflow plan-app -f plan -s plat-platform-usw2-dev

# Open an interactive shell with the right backend + creds for a component
atmos terraform shell polarbear-app -s plat-platform-usw2-dev

# Watch the init container do the schema migration
kubectl logs -f -n polarbear-app -l app=polarbear-app -c db-schema-init

# Watch the app start up
kubectl logs -f -n polarbear-app -l app=polarbear-app -c app
```
