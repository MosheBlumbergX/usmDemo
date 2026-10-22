# Target bucket for the S3 sink connector running on CP Connect. The Connect pods
# get credentials through EKS Pod Identity (no static AWS keys anywhere).

resource "random_id" "suffix" {
  byte_length = 3
}

resource "aws_s3_bucket" "sink" {
  bucket        = "${var.name}-sink-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "sink" {
  bucket                  = aws_s3_bucket.sink.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "connect" {
  name               = "${var.name}-connect"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "connect_s3" {
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.sink.arn]
  }
  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.sink.arn}/*"]
  }
}

resource "aws_iam_role_policy" "connect_s3" {
  name   = "s3-sink"
  role   = aws_iam_role.connect.id
  policy = data.aws_iam_policy_document.connect_s3.json
}

# Must match spec.podTemplate.serviceAccountName on the Connect CR.
resource "aws_eks_pod_identity_association" "connect" {
  cluster_name    = module.eks.cluster_name
  namespace       = "usm"
  service_account = "connect"
  role_arn        = aws_iam_role.connect.arn
}
