# Troubleshooting

The article calls out four failure modes; this repo pre-solves each in
IaC. Sections 1–4 below cover those gotchas. Sections 5–8 cover new
gotchas specific to the polar-bear-club-site app deployment.

---

## 1. "Database is not reachable" from a Pod

**Symptom:** App Pod CrashLoopBackOff with Postgres connection errors,
or init container hangs.

**Pre-solved by:** `rds` component reads the EKS cluster security group
via remote state and adds an ingress rule on `:5432`.

**Manual debug:**

```bash
kubectl run debug --rm -it --image=postgres -n polarbear-app -- bash
PGPASSWORD=$(kubectl get secret db-secrets -n polarbear-app \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d) \
  psql -h $(kubectl get secret db-secrets -n polarbear-app \
       -o jsonpath='{.data.DB_HOST}' | base64 -d) \
       -U $(kubectl get secret db-secrets -n polarbear-app \
       -o jsonpath='{.data.DB_USER}' | base64 -d) \
       -d $(kubectl get secret db-secrets -n polarbear-app \
       -o jsonpath='{.data.DB_NAME}' | base64 -d) -c '\dt'
```

If that hangs → security group is wrong.
Check: `aws ec2 describe-security-groups --group-ids <rds-sg> --query 'SecurityGroups[0].IpPermissions'`

---

## 2. Ingress sits without an ADDRESS forever

**Symptom:** `kubectl get ingress` shows blank under `ADDRESS`.

**Pre-solved by:** `vpc` component applies subnet tags
(`kubernetes.io/role/elb=1` on public, `internal-elb=1` on private).

**Manual debug:**

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
```

The smoking-gun line in the controller logs is:

```
couldn't auto-discover subnets: unable to discover at least one subnet
```

Fix:
```bash
VPC_ID=$(atmos terraform output vpc -s plat-platform-usw2-dev -- vpc_id)
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{Id:SubnetId,Tags:Tags}'
```

If subnets are missing the tag, that's a `vpc` apply that didn't take —
re-run `atmos terraform apply vpc -s ...`.

---

## 3. cert-manager Certificate stuck in `READY=False`

**Pre-solved by:** `eks/cert-manager` component creates the IRSA role
with Route53 permissions and DNS-01 challenge config out of the box.

**Manual debug:**

```bash
kubectl describe certificate app-tls -n polarbear-app
kubectl get challenge -n polarbear-app
kubectl describe challenge -n polarbear-app
kubectl logs -n cert-manager -l app=cert-manager --tail=200 | grep -i error
```

Common causes:
- IRSA role doesn't trust the cert-manager ServiceAccount → check the OIDC
  trust policy on the role
- The Route53 hosted zone isn't in the same AWS account as cert-manager's
  IRSA role → `dns-delegated` solves this by putting the zone in the same
  account as the cluster
- You're rate-limited by Let's Encrypt prod → switch `cluster_issuer` to
  `letsencrypt-staging` while iterating

---

## 4. ALB returns 503 / Service Unavailable

**Pre-solved by:**
- App Deployment declares readiness probes that match the ingress
  healthcheck path
- `target-type: ip` annotation so ALB targets Pod IPs (not NodePorts)

**Manual debug:**

```bash
# Are the Pods Ready?
kubectl get pods -n polarbear-app

# What does the target group think?
ALB=$(kubectl get ingress polarbear-app -n polarbear-app \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
TG_ARN=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(LoadBalancerArns, \`$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName==\`$ALB\`].LoadBalancerArn" --output text)\`)].TargetGroupArn" \
  --output text | head -1)
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

If targets are `unhealthy` with `HealthCheck failed`, the readiness probe
path doesn't match the Ingress healthcheck path
(`alb.ingress.kubernetes.io/healthcheck-path`).

Particularly common with this app: the catalog default healthcheck path
is `/api/healthcheck`, which Next.js doesn't ship out of the box. Add a
trivial route at `app/api/healthcheck/route.ts` in the polar-bear-club-site
repo, or temporarily change the path to `/` in the catalog while you're
testing:

```yaml
# stacks/catalog/polarbear-app.yaml
ingress_annotations:
  alb.ingress.kubernetes.io/healthcheck-path: "/"
```

---

## 5. Init container `db-schema-init` fails

**Symptom:** `kubectl get pods -n polarbear-app` shows the Pod stuck in
`Init:Error` or `Init:CrashLoopBackOff`.

**Debug:**

```bash
kubectl logs -n polarbear-app -l app=polarbear-app -c db-schema-init
```

Common causes:

| Log message                                   | Cause                                                   |
|-----------------------------------------------|---------------------------------------------------------|
| `psql: error: connection to server at … failed` | RDS security group blocking — see section 1            |
| `FATAL: password authentication failed`       | DB password rotated but ESO hasn't re-synced — `kubectl annotate externalsecret db-secrets -n polarbear-app force-sync=$(date +%s) --overwrite` |
| `ERROR: syntax error at or near "key"`        | Schema SQL uses MySQL backticks; should use double-quoted identifiers (the catalog ships a Postgres-compatible variant — check it didn't get overridden) |
| `ERROR: relation "tokens" already exists`     | Schema is missing `IF NOT EXISTS` — check `db_schema_sql` in the catalog |

To skip the init container temporarily (e.g. while iterating on schema):

```yaml
# stacks/catalog/polarbear-app.yaml
run_db_schema_init: false
```

---

## 6. ExternalSecret stays `SecretSyncedError`

```bash
kubectl describe externalsecret app-secrets-integrations -n polarbear-app
```

Most common causes:

| `status.conditions[].message` snippet                | Fix |
|------------------------------------------------------|-----|
| `secret "plat/dev/polarbear-app/integrations" not found` | Run the polarbear-app apply (creates the empty secret), then populate per `docs/secrets-bootstrap.md` |
| `key not found in secret`                            | A key in `var.env_secrets` isn't present in the Secrets Manager JSON. Either add the key to the JSON, or remove it from `env_secrets`. |
| `AccessDeniedException: not authorized to perform secretsmanager:GetSecretValue` | The `external-secrets-operator` IRSA role doesn't have access. The component grants `secretsmanager:*` on `arn:aws:secretsmanager:*:*:secret:*` by default. If you tightened the policy, re-allow `arn:aws:secretsmanager:*:*:secret:plat/*/polarbear-app/*`. |

---

## 7. ImagePullBackOff on the GHCR image

**Symptom:** Pod stuck in `ImagePullBackOff` after a `kubectl describe pod`
shows `denied: denied` or `unauthorized: authentication required`.

**Cause:** Your GHCR image is private and the cluster doesn't have a
pull secret.

**Fix:**

1. Generate a GitHub PAT with `read:packages` scope
2. Create the dockerconfigjson Secret:
   ```bash
   kubectl create secret docker-registry ghcr-pull \
     --namespace polarbear-app \
     --docker-server=ghcr.io \
     --docker-username=<your-github-username> \
     --docker-password=<your-pat> \
     [email protected]
   ```
3. Reference it from the catalog:
   ```yaml
   # stacks/catalog/polarbear-app.yaml
   image_pull_secret_name: "ghcr-pull"
   ```
4. `atmos terraform apply polarbear-app -s plat-platform-usw2-dev`

For a fully-IaC version, store the PAT in Secrets Manager and add an
ExternalSecret with `template.type: kubernetes.io/dockerconfigjson` to
materialize it.

---

## 8. App boots but throws "AUTH_SECRET is required"

The Pod is up, the init container ran, but the app crashes on startup
with a missing env var. Almost always means the integrations secret
hasn't been populated yet.

```bash
# Verify the K8s Secret has the key
kubectl get secret app-secrets-integrations -n polarbear-app \
  -o json | jq '.data | keys'

# If it's missing, populate the AWS Secrets Manager secret then
kubectl annotate externalsecret app-secrets-integrations \
  -n polarbear-app force-sync=$(date +%s) --overwrite
kubectl rollout restart deployment polarbear-app -n polarbear-app
```

See [`docs/secrets-bootstrap.md`](secrets-bootstrap.md) for the full
JSON shape.
