# Runbook — atmos-eks-platform-aws

Step-by-step walk-through to take this repo from a fresh clone to a working
HTTPS endpoint at `https://app.dev.thepolarbearclub3d.com`.

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

---

## 1. First-time bootstrap (per account)

The state backend is a chicken/egg: we need an S3 bucket + Dynamo table
*before* Terraform can write state to it.

```bash
# Vendor the components into the working tree
atmos vendor pull

# Bootstrap state backend with local state, then migrate
cd components/terraform/tfstate-backend
terraform init
atmos terraform apply tfstate-backend -s plat-platform-usw2-dev

# Re-init Terraform pointing at the new S3 backend
atmos terraform init tfstate-backend -s plat-platform-usw2-dev -- -migrate-state
cd ../../..
```

From here on out everything goes through `atmos terraform ...`.

---

## 2. Apply order (matches `make bootstrap`)

```bash
STACK=plat-platform-usw2-dev

atmos terraform apply vpc                           -s $STACK
atmos terraform apply dns-primary                   -s plat-platform-gbl-prod   # one-time
atmos terraform apply dns-delegated                 -s plat-platform-gbl-dev
atmos terraform apply acm                           -s $STACK
atmos terraform apply eks/cluster                   -s $STACK

# Wire kubectl to the new cluster (one-liner via Cloud Posse output)
aws eks update-kubeconfig --region us-west-2 \
  --name $(atmos terraform output eks/cluster -s $STACK -- eks_cluster_id)

atmos terraform apply eks/aws-load-balancer-controller -s $STACK
atmos terraform apply eks/external-dns                 -s $STACK
atmos terraform apply eks/cert-manager                 -s $STACK
atmos terraform apply eks/external-secrets-operator    -s $STACK
atmos terraform apply eks/metrics-server               -s $STACK

atmos terraform apply rds                              -s $STACK
atmos terraform apply three-tier-app                   -s $STACK
```

Or, all of the above:

```bash
make bootstrap STACK=plat-platform-usw2-dev
```

---

## 3. Verify

```bash
kubectl get nodes
kubectl get pods -A | grep -E 'aws-load-balancer|cert-manager|external-dns|external-secrets'
kubectl get ingress -n 3-tier-app-eks
kubectl get certificate -n 3-tier-app-eks      # READY=True within ~2 min
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

## 4. Day-2 ops

### Roll the app forward

Edit the image tag in `stacks/catalog/three-tier-app.yaml` (or override per
stage) and apply:

```bash
atmos terraform apply three-tier-app -s plat-platform-usw2-dev
```

### Bump a Cloud Posse component

```bash
sed -i '' 's/version: "1.520.0"/version: "1.521.0"/' vendor.yaml
atmos vendor pull
git diff components/terraform   # review the upgrade
atmos terraform plan eks/cluster -s plat-platform-usw2-dev
```

### Switch from Let's Encrypt staging → prod

```yaml
# stacks/mixins/stage/dev.yaml
components:
  terraform:
    three-tier-app:
      vars:
        cluster_issuer: "letsencrypt-prod"   # was "letsencrypt-staging"
```

```bash
atmos terraform apply three-tier-app -s plat-platform-usw2-dev
```

### Tear it all down

```bash
make destroy STACK=plat-platform-usw2-dev
```
