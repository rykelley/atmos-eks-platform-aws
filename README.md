# atmos-eks-platform-aws

Production-grade Infrastructure-as-Code for a 3-tier app on AWS EKS, built
with the [Atmos](https://atmos.tools) framework on top of
[Cloud Posse's `terraform-aws-components`](https://github.com/cloudposse/terraform-aws-components).

This is the IaC translation of the AWS Tip article
*["Real-world Kubernetes project on AWS EKS (2026)"](https://awstip.com/real-world-kubernetes-project-on-aws-eks-deploy-a-production-3-tier-app-with-https-2026-16dc13217dcf)*
— every `eksctl`, `aws cli`, `kubectl`, and `helm` command in that post is
encoded as a vendored Atmos component, with sane multi-account / multi-region
defaults baked in.

> **TL;DR** — `atmos vendor pull && make bootstrap STACK=plat-platform-usw2-dev`
> gives you a managed EKS cluster, RDS Postgres in private subnets, the AWS
> Load Balancer Controller, cert-manager + ExternalDNS + ExternalSecrets,
> and a React+Flask quiz app reachable at
> `https://app.dev.thepolarbearclub3d.com`.

---

## Architecture

```
                            Route53 (apex zone in prod account)
                                       │
                                       │ NS delegation
                                       ▼
                       Route53 (dev.thepolarbearclub3d.com)
                                       │
                                       │ A-alias  (managed by external-dns)
                                       ▼
   Internet ───► Application Load Balancer (HTTPS, ACM cert)
                                       │
                                       ▼
                       ┌─── Ingress (alb class) ───┐
                       │                           │
                  /api │                           │ /
                       ▼                           ▼
                  Flask backend           React frontend
                       │
                       │ postgres-db.<ns>.svc.cluster.local
                       ▼  (ExternalName Service)
                  ┌───────────────────────────────┐
                  │  RDS Postgres (private subnets)│
                  └───────────────────────────────┘

                  Inside the cluster (kube-system & friends):
                  - aws-load-balancer-controller   (ALB provisioning)
                  - cert-manager                   (Let's Encrypt → Cert)
                  - external-dns                   (Route53 records)
                  - external-secrets-operator      (AWS SM → K8s Secrets)
                  - metrics-server                 (HPA / kubectl top)
```

---

## Repo layout

```
atmos-eks-platform-aws/
├── atmos.yaml              # Atmos CLI config (paths, GHA integration)
├── vendor.yaml             # Pulls Cloud Posse components (run `atmos vendor pull`)
├── Makefile                # Convenience targets: bootstrap, destroy, validate
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
│       └── three-tier-app/                      # custom — the actual app
│
├── stacks/
│   ├── catalog/                                  # reusable component defaults
│   ├── mixins/
│   │   ├── region/  { us-west-2, us-east-1, global }
│   │   └── stage/   { dev, staging, prod }
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
    ├── runbook.md               # Day-1 deploy & day-2 ops
    └── troubleshooting.md       # The article's gotchas, pre-solved
```

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

---

## Quick start

```bash
# 1. Install prerequisites
brew install cloudposse/tap/atmos terraform awscli kubectl helm

# 2. Pull Cloud Posse components into ./components/terraform/
atmos vendor pull

# 3. Validate everything parses
atmos validate stacks

# 4. Bootstrap the dev account (in order — see Makefile)
make bootstrap STACK=plat-platform-usw2-dev

# 5. Test
kubectl get ingress -n 3-tier-app-eks
curl -kI https://app.dev.thepolarbearclub3d.com
```

Detailed walkthrough: [`docs/runbook.md`](docs/runbook.md).
Stuck on something the article also got stuck on?
See [`docs/troubleshooting.md`](docs/troubleshooting.md).

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
| Hand-encoded base64 `Secret` for DB creds         | `eks/external-secrets-operator` + RDS-managed secret |
| `kubectl apply -f namespace/configmap/.../ingress`| `three-tier-app` (custom component)     |
| `acm import-certificate` workflow                 | Not needed — ALB uses ACM cert directly via `dns-delegated` + ALBC annotation |

---

## Why Atmos + Cloud Posse?

- **Component reuse without forks.** `vendor.yaml` pins exact versions of
  Cloud Posse modules. Bumping the platform = bump one number.
- **Stack inheritance.** `dev` → `usw2` → `plat-platform` overrides flow
  cleanly, so prod actually looks like dev (with safety knobs flipped).
- **Affected-only CI.** The Cloud Posse Atmos GHA actions only plan/apply
  the components that changed in the PR.
- **Native remote state.** `three-tier-app` reads the RDS endpoint and EKS
  cluster name from sibling components without us hand-wiring data sources.
