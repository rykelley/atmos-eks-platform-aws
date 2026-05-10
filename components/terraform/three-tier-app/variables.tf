variable "region" {
  type        = string
  description = "AWS region"
}

variable "kubernetes_namespace" {
  type        = string
  default     = "3-tier-app-eks"
  description = "Namespace where the app is deployed"
}

variable "create_namespace" {
  type        = bool
  default     = true
  description = "Create the Kubernetes namespace"
}

variable "backend_image" {
  type        = string
  description = "Container image (without tag) for the Flask backend"
}

variable "backend_tag" {
  type        = string
  description = "Image tag for the backend"
}

variable "frontend_image" {
  type        = string
  description = "Container image (without tag) for the React frontend"
}

variable "frontend_tag" {
  type        = string
  description = "Image tag for the frontend"
}

variable "backend_replicas" {
  type    = number
  default = 2
}

variable "frontend_replicas" {
  type    = number
  default = 2
}

variable "hostname_template" {
  type        = string
  description = "Hostname template; {{ .stage }} is interpolated by Atmos before reaching Terraform"
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

variable "run_db_migration_job" {
  type        = bool
  default     = true
  description = "If true, runs the Flask DB migration as a Kubernetes Job before the backend Deployment is rolled out"
}

# ---------------------------------------------------------------------------
# Wired in via Cloud Posse remote-state in main.tf
# ---------------------------------------------------------------------------
variable "rds_component_name" {
  type    = string
  default = "rds"
}

variable "eks_component_name" {
  type    = string
  default = "eks/cluster"
}
