data "aws_iam_user" "jenkins" {
  user_name = "jenkins-eks"
}


module "vpc" {
  source              = "./modules/vpc"
  project_name        = "tripsync"
  vpc_cidr            = "10.0.0.0/16"
  private_subnet_cidr = "10.0.1.0/24"
  public_subnet_cidrs = ["10.0.101.0/24", "10.0.102.0/24"]
  enable_nat_gateway  = true
  zones               = ["eu-central-1a", "eu-central-1b"]
  tags = {
    Project = "TripSync"
  }
}


module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "tripsync-cluster"
  cluster_version = "1.37"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Without this, the IAM user that creates the cluster gets no Kubernetes
  # permissions and kubectl is denied right after apply.
  enable_cluster_creator_admin_permissions = true

  # Jenkins runs outside AWS, so the API endpoint must be reachable publicly.
  cluster_endpoint_public_access = true


  control_plane_subnet_ids = module.vpc.public_subnets

  access_entries = {
    jenkins = {
      principal_arn = data.aws_iam_user.jenkins.arn
      policy_associations = {
        edit = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["tripsync"]
          }
        }
      }
    }
  }


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
