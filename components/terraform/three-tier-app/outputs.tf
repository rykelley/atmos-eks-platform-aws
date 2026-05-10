output "namespace" {
  value       = local.namespace
  description = "Kubernetes namespace the app runs in"
}

output "hostname" {
  value       = local.hostname
  description = "Public hostname the app is reachable at over HTTPS"
}

output "ingress_name" {
  value       = try(kubernetes_ingress_v1.this[0].metadata[0].name, null)
  description = "Name of the Ingress (looked up to find the ALB DNS)"
}
