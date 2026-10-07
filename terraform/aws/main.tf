module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "tripsync-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["eu-central-1a", "eu-central-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Project = "TripSync"
  }
}

# Commented out until the homelab k3s pipeline (Terraform -> Helm -> Jenkins ->
# Cloudflare Tunnel) is proven end-to-end. Uncomment when ready to actually
# `terraform apply` against AWS for real — this is the expensive part
# (EKS control plane bills ~$0.10/hr the moment it exists).
#
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "tripsync-cluster"
  cluster_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Without this, the IAM user that creates the cluster gets no Kubernetes
  # permissions and kubectl is denied right after apply.
  enable_cluster_creator_admin_permissions = true

  # Jenkins runs outside AWS, so the API endpoint must be reachable publicly.
  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["c7i-flex.large"]
      min_size       = 1
      max_size       = 2
      desired_size   = 1
    }
  }

  tags = {
    Project = "TripSync"
  }
}
