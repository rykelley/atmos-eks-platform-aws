# Troubleshooting

The article calls out four specific failure modes. This repo pre-solves
each one in IaC, but here's how to debug if you hit them anyway.

---

## 1. "Database is not reachable" from a Pod

**Symptom:** Backend Pod CrashLoopBackOff with `psycopg2.OperationalError`.

**Pre-solved by:** `rds` component reads the EKS cluster security group via
remote state and adds an ingress rule on `:5432`.

**Manual debug:**

```bash
kubectl run debug --rm -it --image=postgres -n 3-tier-app-eks -- bash
PGPASSWORD=$(kubectl get secret db-secrets -n 3-tier-app-eks \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d) \
  psql -h postgres-db.3-tier-app-eks.svc.cluster.local \
       -U appadmin -d appdb -c '\dt'
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

**Pre-solved by:** `eks/cert-manager` component creates the IRSA role with
Route53 permissions and DNS-01 challenge config out of the box.

**Manual debug:**

```bash
kubectl describe certificate app-tls -n 3-tier-app-eks
kubectl get challenge -n 3-tier-app-eks
kubectl describe challenge -n 3-tier-app-eks
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
- Backend & frontend Deployments declare readiness probes that match the
  ingress healthcheck path
- `target-type: ip` annotation on Ingress so ALB targets Pod IPs (not
  NodePorts), so target group registration is fast

**Manual debug:**

```bash
# Are the Pods Ready?
kubectl get pods -n 3-tier-app-eks

# What does the target group think?
ALB=$(kubectl get ingress three-tier-app-ingress -n 3-tier-app-eks \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
TG_ARN=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(LoadBalancerArns, \`$(aws elbv2 describe-load-balancers --query "LoadBalancers[?DNSName==\`$ALB\`].LoadBalancerArn" --output text)\`)].TargetGroupArn" \
  --output text | head -1)
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

If targets are `unhealthy` with `HealthCheck failed`, your readiness probe
path doesn't match the Ingress healthcheck path
(`alb.ingress.kubernetes.io/healthcheck-path`).

---

## 5. New gotcha: ExternalSecret stays `SecretSyncedError`

This isn't in the article (because the article hand-encodes the secret).
It's the most likely failure for *this* repo:

```bash
kubectl describe externalsecret db-secrets -n 3-tier-app-eks
```

Most common cause: the `external-secrets-operator` IRSA role can't
`secretsmanager:GetSecretValue` on the RDS-managed secret. The
`eks/external-secrets-operator` component grants `secretsmanager:*` on
all secrets in the account by default — if you tightened the policy,
re-allow `arn:aws:secretsmanager:*:*:secret:rds!*`.
