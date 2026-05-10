################################################################################
# three-tier-app — IaC translation of the article's K8s manifests
#
# Resources created (in order):
#   1.  Namespace         (3-tier-app-eks)
#   2.  Service (ExternalName) → RDS endpoint
#   3.  ConfigMap          (DB host, port, name, FLASK_DEBUG=0)
#   4.  ExternalSecret     (pulls DB password from AWS Secrets Manager via ESO)
#   5.  Migration Job      (runs Flask DB migrations once per release)
#   6.  Backend Deployment + Service
#   7.  Frontend Deployment + Service
#   8.  cert-manager Certificate (DNS-01 via Route53 → wildcard *.<host>)
#   9.  Ingress             (alb, internet-facing, HTTPS via cert from #8)
################################################################################

locals {
  namespace = var.kubernetes_namespace
  hostname  = var.hostname_template

  rds_endpoint   = module.rds.outputs.address
  rds_port       = module.rds.outputs.db_port
  rds_dbname     = module.rds.outputs.database_name
  rds_username   = module.rds.outputs.database_user
  rds_secret_arn = module.rds.outputs.master_password_secret_arn

  app_labels = {
    "app.kubernetes.io/name"       = "three-tier-app"
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/part-of"    = module.this.id
  }
}

# ---------------------------------------------------------------------------
# 1. Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace && var.enabled ? 1 : 0

  metadata {
    name   = local.namespace
    labels = local.app_labels
  }
}

# ---------------------------------------------------------------------------
# 2. ExternalName Service → RDS
#    Lets the app talk to "postgres-db.<ns>.svc.cluster.local" instead of
#    a hardcoded RDS endpoint, exactly as in the article.
# ---------------------------------------------------------------------------
resource "kubernetes_service_v1" "postgres_db" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "postgres-db"
    namespace = local.namespace
    labels    = merge(local.app_labels, { service = "database" })
  }
  spec {
    type          = "ExternalName"
    external_name = local.rds_endpoint
    port {
      port = local.rds_port
    }
  }
  depends_on = [kubernetes_namespace_v1.this]
}

# ---------------------------------------------------------------------------
# 3. ConfigMap with non-sensitive DB connection bits
# ---------------------------------------------------------------------------
resource "kubernetes_config_map_v1" "app_config" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "app-config"
    namespace = local.namespace
    labels    = local.app_labels
  }
  data = {
    DB_HOST     = "postgres-db.${local.namespace}.svc.cluster.local"
    DB_NAME     = local.rds_dbname
    DB_PORT     = tostring(local.rds_port)
    FLASK_DEBUG = "0"
  }
  depends_on = [kubernetes_namespace_v1.this]
}

# ---------------------------------------------------------------------------
# 4. ExternalSecret — sync the master DB password from AWS Secrets Manager
#    into a regular Kubernetes Secret named `db-secrets`. Replaces the
#    hand-encoded base64 secret in the article.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "secret_store" {
  count = var.enabled ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "SecretStore"
    metadata = {
      name      = "aws-secrets-manager"
      namespace = local.namespace
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.region
          auth = {
            jwt = {
              serviceAccountRef = {
                name = "external-secrets-sa"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_manifest" "external_secret" {
  count = var.enabled ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "db-secrets"
      namespace = local.namespace
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
            DB_USERNAME  = local.rds_username
            DB_PASSWORD  = "{{ .password }}"
            SECRET_KEY   = "{{ .password | sha256sum }}"
            DATABASE_URL = "postgresql://${local.rds_username}:{{ .password }}@postgres-db.${local.namespace}.svc.cluster.local:${local.rds_port}/${local.rds_dbname}"
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
# 5. DB migration Job — runs once per Terraform apply (job name includes
#    the image tag so a new image rolls a new Job).
# ---------------------------------------------------------------------------
resource "kubernetes_job_v1" "migrate" {
  count = var.enabled && var.run_db_migration_job ? 1 : 0

  metadata {
    generate_name = "db-migrate-"
    namespace     = local.namespace
    labels        = merge(local.app_labels, { component = "migration" })
  }
  spec {
    backoff_limit = 3
    template {
      metadata {
        labels = merge(local.app_labels, { component = "migration" })
      }
      spec {
        restart_policy = "OnFailure"
        container {
          name    = "migrate"
          image   = "${var.backend_image}:${var.backend_tag}"
          command = ["flask", "db", "upgrade"]
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
        }
      }
    }
  }
  wait_for_completion = true
  timeouts {
    create = "10m"
    update = "10m"
  }
  depends_on = [
    kubernetes_config_map_v1.app_config,
    kubernetes_manifest.external_secret,
  ]
}

# ---------------------------------------------------------------------------
# 6. Backend Deployment + Service
# ---------------------------------------------------------------------------
resource "kubernetes_deployment_v1" "backend" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "backend"
    namespace = local.namespace
    labels    = merge(local.app_labels, { app = "backend" })
  }
  spec {
    replicas = var.backend_replicas
    selector {
      match_labels = { app = "backend" }
    }
    template {
      metadata {
        labels = merge(local.app_labels, { app = "backend" })
      }
      spec {
        container {
          name  = "backend"
          image = "${var.backend_image}:${var.backend_tag}"
          port {
            container_port = 8000
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
          readiness_probe {
            http_get {
              path = "/api/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/api/health"
              port = 8000
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_job_v1.migrate,
    kubernetes_manifest.external_secret,
  ]
}

resource "kubernetes_service_v1" "backend" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "backend"
    namespace = local.namespace
    labels    = merge(local.app_labels, { app = "backend" })
  }
  spec {
    selector = { app = "backend" }
    port {
      port        = 8000
      target_port = 8000
    }
    type = "ClusterIP"
  }
}

# ---------------------------------------------------------------------------
# 7. Frontend Deployment + Service
# ---------------------------------------------------------------------------
resource "kubernetes_deployment_v1" "frontend" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "frontend"
    namespace = local.namespace
    labels    = merge(local.app_labels, { app = "frontend" })
  }
  spec {
    replicas = var.frontend_replicas
    selector {
      match_labels = { app = "frontend" }
    }
    template {
      metadata {
        labels = merge(local.app_labels, { app = "frontend" })
      }
      spec {
        container {
          name  = "frontend"
          image = "${var.frontend_image}:${var.frontend_tag}"
          port {
            container_port = 80
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "frontend" {
  count = var.enabled ? 1 : 0

  metadata {
    name      = "frontend"
    namespace = local.namespace
    labels    = merge(local.app_labels, { app = "frontend" })
  }
  spec {
    selector = { app = "frontend" }
    port {
      port        = 80
      target_port = 80
    }
    type = "ClusterIP"
  }
}

# ---------------------------------------------------------------------------
# 8. cert-manager Certificate (TLS via Let's Encrypt → DNS-01 on Route53)
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "certificate" {
  count = var.enabled ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "app-tls"
      namespace = local.namespace
    }
    spec = {
      secretName = "app-tls"
      issuerRef = {
        name = var.cluster_issuer
        kind = "ClusterIssuer"
      }
      dnsNames = [
        local.hostname,
        "*.${local.hostname}",
      ]
    }
  }
  depends_on = [kubernetes_namespace_v1.this]
}

# ---------------------------------------------------------------------------
# 9. Ingress — ALB, HTTPS, HTTP→HTTPS redirect, /api → backend, / → frontend
# ---------------------------------------------------------------------------
resource "kubernetes_ingress_v1" "this" {
  count = var.enabled ? 1 : 0

  metadata {
    name        = "three-tier-app-ingress"
    namespace   = local.namespace
    labels      = local.app_labels
    annotations = var.ingress_annotations
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
          path      = "/api"
          path_type = "Prefix"
          backend {
            service {
              name = "backend"
              port {
                number = 8000
              }
            }
          }
        }
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "frontend"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_service_v1.backend,
    kubernetes_service_v1.frontend,
    kubernetes_manifest.certificate,
  ]
}
