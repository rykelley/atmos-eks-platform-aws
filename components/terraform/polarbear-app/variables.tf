variable "region" {
  type        = string
  description = "AWS region"
}

variable "kubernetes_namespace" {
  type        = string
  default     = "polarbear-app"
  description = "Namespace where the app is deployed"
}

variable "create_namespace" {
  type        = bool
  default     = true
  description = "Create the Kubernetes namespace"
}

variable "image" {
  type        = string
  description = "Container image (without tag) — e.g. ghcr.io/<owner>/polar-bear-club-site"
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Image tag — bump to roll a new release"
}

variable "image_pull_policy" {
  type    = string
  default = "IfNotPresent"
}

variable "image_pull_secret_name" {
  type        = string
  default     = ""
  description = "Name of a pre-existing dockerconfigjson Secret in the app namespace; leave blank for a public image"
}

variable "replicas" {
  type    = number
  default = 2
}

variable "port" {
  type    = number
  default = 3000
}

variable "resources" {
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "100m", memory = "256Mi" }
    limits   = { memory = "1Gi" }
  }
}

variable "hostname" {
  type        = string
  description = "Public hostname this app is reachable at over HTTPS"
}

variable "cluster_issuer" {
  type        = string
  default     = "letsencrypt-prod"
  description = "cert-manager ClusterIssuer name"
}

variable "ingress_class_name" {
  type    = string
  default = "alb"
}

variable "ingress_annotations" {
  type        = map(string)
  description = "Annotations applied to the Ingress object"
}

variable "run_db_schema_init" {
  type        = bool
  default     = true
  description = "If true, runs `psql` against RDS as an init container before the app starts (idempotent)"
}

variable "db_schema_sql" {
  type        = string
  description = "Postgres-compatible schema DDL applied by the init container"
}

variable "env_config" {
  type        = map(string)
  description = "Non-secret env vars rendered into the ConfigMap"
}

variable "env_secrets" {
  type        = map(string)
  description = "Map of K8s env-var name → JSON property key inside the AWS Secrets Manager secret"
}

# ---------------------------------------------------------------------------
# Wired in via remote state — don't override unless you really know.
# ---------------------------------------------------------------------------
variable "rds_component_name" {
  type    = string
  default = "rds"
}

variable "eks_component_name" {
  type    = string
  default = "eks/cluster"
}

variable "s3_component_name" {
  type    = string
  default = "s3-bucket"
}
