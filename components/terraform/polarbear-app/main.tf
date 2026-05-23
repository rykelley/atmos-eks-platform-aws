################################################################################
# polarbear-app — Next.js 15 standalone deployment for polar-bear-club-site
#
# Resources (in dependency order):
#
#   AWS:
#     1.  IAM user + access key scoped to the s3-bucket component's bucket
#     2.  Secrets Manager secret "<ns>/polarbear-app/<stage>/aws"
#         (managed — holds the IAM user's keys + bucket name + region)
#     3.  Secrets Manager secret "<ns>/polarbear-app/<stage>/integrations"
#         (placeholder — user populates Resend / Stripe / OAuth keys after
#          first apply; Terraform never reads these values back)
#
#   Kubernetes:
#     4.  Namespace
#     5.  ConfigMap   `app-config`         — non-secret env (var.env_config)
#     6.  ConfigMap   `db-init-schema`     — Postgres schema DDL
#     7.  SecretStore `aws-secrets-manager` (uses ESO IRSA SA in cluster)
#     8.  ExternalSecret `app-secrets-aws`         (TF-managed AWS secret)
#     9.  ExternalSecret `app-secrets-integrations` (user-populated secret)
#    10.  ExternalSecret `db-secrets`              (RDS-managed secret)
#    11.  Deployment   (initContainer = psql schema; app = next start)
#    12.  Service ClusterIP :3000
#    13.  cert-manager Certificate                  (DNS-01 → Let's Encrypt)
#    14.  Ingress (alb, HTTPS, HTTP→HTTPS redirect)
################################################################################

locals {
  ns       = var.kubernetes_namespace
  hostname = var.hostname

  rds_endpoint   = module.rds.outputs.address
  rds_port       = module.rds.outputs.db_port
  rds_dbname     = module.rds.outputs.database_name
  rds_username   = module.rds.outputs.database_user
  rds_secret_arn = module.rds.outputs.master_password_secret_arn

  s3_bucket_id     = module.s3.outputs.bucket_id
  s3_bucket_arn    = module.s3.outputs.bucket_arn
  s3_bucket_region = var.region

  # JSON-encoded blob written into the AWS Secrets Manager secret that
  # ESO syncs into the `app-secrets-aws` Kubernetes Secret.
  aws_secret_payload = jsonencode({
    AWS_KEY_ID            = aws_iam_access_key.app[0].id
    AWS_SECRET_ACCESS_KEY = aws_iam_access_key.app[0].secret
    AWS_S3_BUCKET_NAME    = local.s3_bucket_id
    AWS_REGION_NAME       = local.s3_bucket_region
  })

  # Stage-aware secret name. These get created in Secrets Manager so ESO
  # can reference them. The "integrations" one stays empty; user populates.
  aws_sm_aws_arn_name          = "${module.this.namespace}/${module.this.stage}/polarbear-app/aws"
  aws_sm_integrations_arn_name = "${module.this.namespace}/${module.this.stage}/polarbear-app/integrations"

  app_labels = {
    "app.kubernetes.io/name"       = "polarbear-app"
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = module.this.id
  }
}

# ---------------------------------------------------------------------------
# 1. IAM user scoped to the S3 bucket
# ---------------------------------------------------------------------------
resource "aws_iam_user" "app" {
  count = var.enabled ? 1 : 0
  name  = "${module.this.id}-s3"
  path  = "/service/"
  tags  = module.this.tags
}

resource "aws_iam_access_key" "app" {
  count = var.enabled ? 1 : 0
  user  = aws_iam_user.app[0].name
}

resource "aws_iam_user_policy" "app_s3" {
  count = var.enabled ? 1 : 0
  name  = "s3-access"
  user  = aws_iam_user.app[0].name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectAcl",
          "s3:PutObjectAcl",
        ]
        Resource = "${local.s3_bucket_arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = local.s3_bucket_arn
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# 2. AWS Secrets Manager — Terraform-managed (S3 keys + bucket meta)
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "aws" {
  count       = var.enabled ? 1 : 0
  name        = local.aws_sm_aws_arn_name
  description = "Polar-Bear-Club site: AWS S3 access keys + bucket meta"
  tags        = module.this.tags

  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "aws" {
  count         = var.enabled ? 1 : 0
  secret_id     = aws_secretsmanager_secret.aws[0].id
  secret_string = local.aws_secret_payload
}

# ---------------------------------------------------------------------------
# 3. AWS Secrets Manager — user-managed (integrations: Resend, Stripe, etc.)
#
# Created empty; user populates JSON via console / CLI. Terraform deliberately
# does NOT manage `secret_string` here so re-applies don't blow user values.
# See docs/secrets-bootstrap.md.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "integrations" {
  count       = var.enabled ? 1 : 0
  name        = local.aws_sm_integrations_arn_name
  description = "Polar-Bear-Club site: 3rd-party API keys (populate by hand)"
  tags        = module.this.tags

  recovery_window_in_days = 7
}

# ---------------------------------------------------------------------------
# 4. Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace && var.enabled ? 1 : 0

  metadata {
    name   = local.ns
    labels = local.app_labels
  }
}

# ---------------------------------------------------------------------------
# 5. ConfigMap: non-secret env vars (+ injected S3 region/bucket)
# ---------------------------------------------------------------------------
resource "kubernetes_config_map_v1" "app_config" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "app-config"
    namespace = local.ns
    labels    = local.app_labels
  }

  # User-provided env_config wins over the auto-injected AWS_* keys, so
  # external buckets can be pointed at by overriding in the catalog.
  data = merge(
    {
      AWS_REGION_NAME    = local.s3_bucket_region
      AWS_S3_BUCKET_NAME = local.s3_bucket_id
    },
    var.env_config,
  )

  depends_on = [kubernetes_namespace_v1.this]
}

# ---------------------------------------------------------------------------
# 6. ConfigMap: Postgres schema DDL for the init container
# ---------------------------------------------------------------------------
resource "kubernetes_config_map_v1" "db_init_schema" {
  count = var.enabled && var.run_db_schema_init ? 1 : 0

  metadata {
    name      = "db-init-schema"
    namespace = local.ns
    labels    = local.app_labels
  }
  data = {
    "schema.sql" = var.db_schema_sql
  }
  depends_on = [kubernetes_namespace_v1.this]
}

# ---------------------------------------------------------------------------
# 7. ESO SecretStore — relies on the external-secrets ServiceAccount IRSA
#    set up by the eks/external-secrets-operator component.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "secret_store" {
  count = var.enabled ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "SecretStore"
    metadata = {
      name      = "aws-secrets-manager"
      namespace = local.ns
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets-sa"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.this]
}

# ---------------------------------------------------------------------------
# 8. ExternalSecret — Terraform-managed AWS keys
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "external_secret_aws" {
  count = var.enabled ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "app-secrets-aws"
      namespace = local.ns
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aws-secrets-manager"
        kind = "SecretStore"
      }
      target = {
        name           = "app-secrets-aws"
        creationPolicy = "Owner"
      }
      dataFrom = [
        {
          extract = {
            key = local.aws_sm_aws_arn_name
          }
        }
      ]
    }
  }
  depends_on = [
    kubernetes_manifest.secret_store,
    aws_secretsmanager_secret_version.aws,
  ]
}

# ---------------------------------------------------------------------------
# 9. ExternalSecret — user-populated 3rd-party integrations
#    Selectively pulls only the keys listed in `var.env_secrets`.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "external_secret_integrations" {
  count = var.enabled ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "app-secrets-integrations"
      namespace = local.ns
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aws-secrets-manager"
        kind = "SecretStore"
      }
      target = {
        name           = "app-secrets-integrations"
        creationPolicy = "Owner"
      }
      data = [
        for env_key, sm_key in var.env_secrets : {
          secretKey = env_key
          remoteRef = {
            key      = local.aws_sm_integrations_arn_name
            property = sm_key
          }
        }
      ]
    }
  }
  depends_on = [
    kubernetes_manifest.secret_store,
    aws_secretsmanager_secret.integrations,
  ]
}

# ---------------------------------------------------------------------------
# 10. ExternalSecret — DB password from RDS-managed secret, then a
#     templated Secret with both pooled + direct Postgres URLs.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "external_secret_db" {
  count = var.enabled ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "db-secrets"
      namespace = local.ns
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aws-secrets-manager"
        kind = "SecretStore"
      }
      target = {
        name           = "db-secrets"
        creationPolicy = "Owner"
        template = {
          type = "Opaque"
          data = {
            DB_USER                     = local.rds_username
            DB_PASSWORD                 = "{{ .password }}"
            DB_HOST                     = local.rds_endpoint
            DB_PORT                     = tostring(local.rds_port)
            DB_NAME                     = local.rds_dbname
            POSTGRES_DIRECT_URL         = "postgresql://${local.rds_username}:{{ .password }}@${local.rds_endpoint}:${local.rds_port}/${local.rds_dbname}?sslmode=require"
            POSTGRES_SESSION_POOLED_URL = "postgresql://${local.rds_username}:{{ .password }}@${local.rds_endpoint}:${local.rds_port}/${local.rds_dbname}?sslmode=require"
          }
        }
      }
      data = [
        {
          secretKey = "password"
          remoteRef = {
            key      = local.rds_secret_arn
            property = "password"
          }
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.secret_store]
}

# ---------------------------------------------------------------------------
# 11. Deployment — Next.js standalone server
#     initContainer runs psql against RDS to apply the schema (idempotent).
# ---------------------------------------------------------------------------
resource "kubernetes_deployment_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "polarbear-app"
    namespace = local.ns
    labels    = merge(local.app_labels, { app = "polarbear-app" })
  }

  spec {
    replicas = var.replicas
    selector {
      match_labels = { app = "polarbear-app" }
    }

    template {
      metadata {
        labels = merge(local.app_labels, { app = "polarbear-app" })
        annotations = {
          # Force Pod restart when secrets change
          "checksum/aws-keys" = sha256(local.aws_secret_payload)
          "checksum/config"   = sha256(jsonencode(var.env_config))
        }
      }
      spec {
        dynamic "image_pull_secrets" {
          for_each = var.image_pull_secret_name != "" ? [1] : []
          content {
            name = var.image_pull_secret_name
          }
        }

        # ----------------------------------------------------------------
        # Init container — apply Postgres schema before the app boots.
        # Uses the official postgres image (~70 MB) so we don't rely on
        # the app image having psql installed.
        # ----------------------------------------------------------------
        dynamic "init_container" {
          for_each = var.run_db_schema_init ? [1] : []
          content {
            name  = "db-schema-init"
            image = "postgres:15-alpine"
            command = [
              "sh",
              "-c",
              "PGPASSWORD=\"$DB_PASSWORD\" psql -h \"$DB_HOST\" -p \"$DB_PORT\" -U \"$DB_USER\" -d \"$DB_NAME\" -v ON_ERROR_STOP=1 -f /schema/schema.sql && echo 'schema applied'",
            ]
            env_from {
              secret_ref {
                name = "db-secrets"
              }
            }
            volume_mount {
              name       = "schema"
              mount_path = "/schema"
              read_only  = true
            }
            resources {
              requests = { cpu = "50m", memory = "64Mi" }
              limits   = { memory = "128Mi" }
            }
          }
        }

        # ----------------------------------------------------------------
        # Main container — Next.js standalone server
        # ----------------------------------------------------------------
        container {
          name              = "app"
          image             = "${var.image}:${var.image_tag}"
          image_pull_policy = var.image_pull_policy

          port {
            container_port = var.port
            name           = "http"
          }

          env_from {
            config_map_ref {
              name = "app-config"
            }
          }
          env_from {
            secret_ref {
              name = "db-secrets"
            }
          }
          env_from {
            secret_ref {
              name = "app-secrets-aws"
            }
          }
          env_from {
            secret_ref {
              name = "app-secrets-integrations"
            }
          }

          readiness_probe {
            http_get {
              path = "/api/healthcheck"
              port = var.port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            failure_threshold     = 6
          }
          liveness_probe {
            http_get {
              path = "/api/healthcheck"
              port = var.port
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }

          resources {
            requests = var.resources.requests
            limits   = var.resources.limits
          }
        }

        dynamic "volume" {
          for_each = var.run_db_schema_init ? [1] : []
          content {
            name = "schema"
            config_map {
              name = "db-init-schema"
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_config_map_v1.app_config,
    kubernetes_config_map_v1.db_init_schema,
    kubernetes_manifest.external_secret_aws,
    kubernetes_manifest.external_secret_integrations,
    kubernetes_manifest.external_secret_db,
  ]
}

# ---------------------------------------------------------------------------
# 12. Service
# ---------------------------------------------------------------------------
resource "kubernetes_service_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "polarbear-app"
    namespace = local.ns
    labels    = local.app_labels
  }
  spec {
    selector = { app = "polarbear-app" }
    type     = "ClusterIP"
    port {
      port        = var.port
      target_port = var.port
      name        = "http"
    }
  }
}

# ---------------------------------------------------------------------------
# 13. cert-manager Certificate (DNS-01 → Let's Encrypt → app-tls Secret)
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "certificate" {
  count = var.enabled ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "app-tls"
      namespace = local.ns
    }
    spec = {
      secretName = "app-tls"
      issuerRef = {
        name = var.cluster_issuer
        kind = "ClusterIssuer"
      }
      dnsNames = [local.hostname]
    }
  }
  depends_on = [kubernetes_namespace_v1.this]
}

# ---------------------------------------------------------------------------
# 14. Ingress (alb, HTTPS, HTTP→HTTPS redirect)
# ---------------------------------------------------------------------------
resource "kubernetes_ingress_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "polarbear-app"
    namespace = local.ns
    labels    = local.app_labels
    annotations = merge(
      var.ingress_annotations,
      {
        "external-dns.alpha.kubernetes.io/hostname" = local.hostname
      },
    )
  }
  spec {
    ingress_class_name = var.ingress_class_name
    tls {
      hosts       = [local.hostname]
      secret_name = "app-tls"
    }
    rule {
      host = local.hostname
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "polarbear-app"
              port {
                number = var.port
              }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_service_v1.this,
    kubernetes_manifest.certificate,
  ]
}
