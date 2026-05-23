# Architecture

## Inheritance flow (how a single value cascades)

```
                       atmos.yaml
                            │
       ┌────────────────────┼─────────────────────────┐
       │                    │                         │
   stacks/orgs/plat/_defaults.yaml         stacks/catalog/*.yaml
                            │                         │
            stacks/orgs/plat/platform/_defaults.yaml  │
                            │                         │
       stacks/orgs/plat/platform/dev/_defaults.yaml   │
            (imports mixins/stage/dev.yaml)           │
                            │                         │
       stacks/orgs/plat/platform/dev/us-west-2.yaml ──┘
            (imports mixins/region/us-west-2.yaml +
             every catalog/* needed for this stack)
                            │
                            ▼
              Final, merged stack manifest
              (`atmos describe stacks -s plat-platform-usw2-dev`)
```

A change to `stacks/catalog/eks/cluster.yaml::node_groups.standard-workers.instance_types`
propagates to every stack that imports that catalog, unless overridden
in a more-specific layer (stage mixin, top-level stack, etc.).

## Component dependency graph

```
            ┌──────────────────┐
            │ tfstate-backend  │  (bootstraps state for everything else)
            └─────────┬────────┘
                      ▼
                  ┌──────┐
                  │ vpc  │
                  └──┬───┘
       ┌─────┬───────┼────────────────┬──────────────┐
       ▼     ▼       ▼                ▼              ▼
   ┌──────┐┌──────┐┌─────────┐  ┌─────────────┐
   │ rds  ││ s3-  ││  acm    │  │ eks/cluster │
   │      ││bucket││         │  │             │
   └──┬───┘└──┬───┘└────┬────┘  └──────┬──────┘
      │      │          │              │
      │      │          │   ┌──────────┼──────────────────────────┐
      │      │          │   ▼          ▼            ▼             ▼
      │      │          │  eks/aws-  eks/cert-  eks/external- eks/external-
      │      │          │  load-bal- manager    dns           secrets-operator
      │      │          │  ancer-                             │
      │      │          │  controller                         │
      │      │          │   │          │            │         │
      │      │          ▼   ▼          ▼            ▼         ▼
      └──────┴──────► polarbear-app  (reads rds + s3 + eks via remote-state)
```

## Multi-account / multi-region topology

```
AWS Organization (plat)
├── platform-prod        333333333333
│   ├── gbl              dns-primary (apex zone)
│   └── us-west-2        full app stack (private endpoint, multi-AZ RDS)
├── platform-staging     222222222222
│   ├── gbl              dns-delegated stg.<domain>
│   └── us-west-2        full app stack (multi-AZ, scaled-down)
└── platform-dev         111111111111
    ├── gbl              dns-delegated dev.<domain>
    └── us-west-2        full app stack (single-AZ, smallest sizes)
```

Each stage owns its own:
- VPC (non-overlapping CIDRs: `10.10/16` dev, `10.15/16` stg, `10.20/16` prod)
- EKS cluster
- RDS instance
- Subset of `<domain>` via `dns-delegated`
- ACM cert for that subzone

Only the **prod** account holds the apex Route53 zone; dev/stg accounts
delegate sub-zones via NS records, so the registrar only ever points at
one set of name servers.
