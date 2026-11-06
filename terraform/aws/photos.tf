# Photos on EKS: a private S3 bucket instead of Garage (on k3s, Garage stays).
# The backend reaches it with an IAM role, not an access key: EKS Pod Identity
# gives the role to exactly one ServiceAccount (tripsync/tripsync-backend, made
# by the Helm chart when s3.enabled) and hands its pods short-lived credentials,
# which boto3 picks up by itself.

data "aws_caller_identity" "current" {}

# Bucket names are global across all AWS accounts; the account id makes it
# unique, and Jenkins computes the same name (aws sts get-caller-identity).
resource "aws_s3_bucket" "photos" {
  bucket = "tripsync-photos-${data.aws_caller_identity.current.account_id}"
  # EKS is a test environment, torn down after each session: destroy empties
  # the bucket instead of failing on it (same idea as the gp3 reclaim policy).
  force_destroy = true
  tags = {
    Project = "TripSync"
  }
}

# Never public: photos are only served through the backend's signed links.
resource "aws_s3_bucket_public_access_block" "photos" {
  bucket                  = aws_s3_bucket.photos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The role the backend's pods get. Only the EKS Pod Identity service may
# assume it (TagSession: it tags the session with the cluster/namespace/SA).
resource "aws_iam_role" "backend_photos" {
  name = "tripsync-backend-photos"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# Least privilege: read, write and delete objects in this one bucket. List is
# there so a missing photo answers "not found" instead of "access denied".
resource "aws_iam_role_policy" "backend_photos" {
  name = "photos-bucket"
  role = aws_iam_role.backend_photos.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.photos.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.photos.arn
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "backend_photos" {
  cluster_name    = module.eks.cluster_name
  namespace       = "tripsync"
  service_account = "tripsync-backend"
  role_arn        = aws_iam_role.backend_photos.arn
}

output "photos_bucket" {
  value = aws_s3_bucket.photos.bucket
}
