# Cloud Posse's remote-state module reads the outputs of sibling components
# (eks/cluster, rds) using the Atmos stack config. No need to duplicate
# data sources or hard-code state paths.

module "eks" {
  source  = "cloudposse/stack-config/yaml//modules/remote-state"
  version = "1.5.0"

  component = var.eks_component_name
  context   = module.this.context
}

module "rds" {
  source  = "cloudposse/stack-config/yaml//modules/remote-state"
  version = "1.5.0"

  component = var.rds_component_name
  context   = module.this.context
}
