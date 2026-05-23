provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

# EKS auth — pulled from the eks/cluster component's outputs.
data "aws_eks_cluster" "this" {
  name = module.eks.outputs.eks_cluster_id
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.outputs.eks_cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
