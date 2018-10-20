provider "aws" {}

terraform {
  backend "s3" {
    key    = "website"
    region = "us-east-1"
  }
}

variable prod_bucket_name {}
variable preview_bucket_name {}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_acm_certificate" "blog" {
  domain   = "<DOMAIN>"
  statuses = ["ISSUED"]
}

resource "aws_s3_bucket" "prod" {
  bucket = "${var.prod_bucket_name}"
  acl    = "private"
}

resource "aws_s3_bucket" "preview" {
  bucket = "${var.preview_bucket_name}"
  acl    = "public-read"

  website {
    index_document = "index.html"
    error_document = "error.html"
  }
}

resource "aws_s3_bucket_policy" "cfread" {
  bucket = "${aws_s3_bucket.prod.id}"

  policy = <<POLICY
{
  "Version": "2008-10-17",
  "Id": "PolicyForCloudFrontPrivateContent",
  "Statement": [
    {
      "Sid": "1",
      "Effect": "Allow",
      "Principal": {
        "AWS": "${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"
      },
      "Action": "s3:GetObject",
      "Resource": "${aws_s3_bucket.prod.arn}/*"
    }
  ]
}
POLICY
}

locals {
  s3_origin_id = "S3-${var.prod_bucket_name}"
}

resource "aws_s3_bucket_policy" "webread" {
  bucket = "${aws_s3_bucket.preview.id}"

  policy = <<POLICY
{
  "Id": "bucket_policy_site",
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "1",
      "Action": [
        "s3:GetObject"
      ],
      "Effect": "Allow",
      "Resource": "${aws_s3_bucket.preview.arn}/*",
      "Principal": "*"
    }
  ]
}
POLICY
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "access-identity-${var.prod_bucket_name}.s3.amazonaws.com"
}

resource "aws_cloudfront_distribution" "distribution" {
  origin {
    domain_name = "${aws_s3_bucket.prod.bucket_regional_domain_name}"
    origin_id   = "${local.s3_origin_id}"

    s3_origin_config {
      origin_access_identity = "${aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path}"
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = ["<DOMAIN>"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${local.s3_origin_id}"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 300
    max_ttl                = 86400
  }

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = "${data.aws_acm_certificate.blog.arn}"
    ssl_support_method  = "sni-only"
  }
}

resource "aws_iam_role" "websitebuild" {
  name = "websitebuild"
  path = "/service-role/"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy" "website-build-s3-write-policy" {
  role = "${aws_iam_role.websitebuild.name}"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
    "Effect": "Allow",
    "Resource": [
        "${aws_s3_bucket.prod.arn}",
        "${aws_s3_bucket.prod.arn}/*"
    ],
    "Action": [
        "s3:PutObject",
        "s3:Get*",
        "s3:List*",
        "s3:DeleteObject"
    ]
    }
  ]
}
POLICY
}

resource "aws_iam_role" "codebuild-websitePR-service-role" {
  name = "codebuild-websitePR-service-role"
  path = "/service-role/"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy" "website-pr-parameter-store-policy" {
  role = "${aws_iam_role.codebuild-websitePR-service-role.name}"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ssm:GetParameters",
      "Resource": "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/CodeBuild/*"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy" "website-pr-s3-write-policy" {
  role = "${aws_iam_role.codebuild-websitePR-service-role.name}"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
    "Effect": "Allow",
    "Resource": [
        "${aws_s3_bucket.preview.arn}",
        "${aws_s3_bucket.preview.arn}/*"
    ],
    "Action": [
        "s3:PutObject",
        "s3:Get*",
        "s3:List*"
    ]
    }
  ]
}
POLICY
}

resource "aws_codebuild_project" "master" {
  name          = "websitebuild"
  build_timeout = "5"
  service_role  = "${aws_iam_role.websitebuild.arn}"

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = "LINUX_CONTAINER"
    image        = "aws/codebuild/ruby:2.5.1"
    compute_type = "BUILD_GENERAL1_SMALL"
  }

  source {
    type                = "GITHUB"
    location            = "<REPO>"
    git_clone_depth     = 1
    report_build_status = true
  }

  badge_enabled = true
  build_timeout = 60
}

# I chose not to manage this webhook via TF for simplicity's sake. This will create a hook that builds on PR and push. Disable the `PR` option

resource "aws_codebuild_webhook" "master" {
  project_name  = "${aws_codebuild_project.master.name}"
  branch_filter = "master"
}

resource "aws_codebuild_project" "pr" {
  name          = "websitePR"
  build_timeout = "5"
  service_role  = "${aws_iam_role.codebuild-websitePR-service-role.arn}"

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = "LINUX_CONTAINER"
    image        = "aws/codebuild/ruby:2.5.1"
    compute_type = "BUILD_GENERAL1_SMALL"

    environment_variable {
      name  = "GH_TOKEN"
      value = "/CodeBuild/GH_TOKEN"
      type  = "PARAMETER_STORE"
    }
  }

  source {
    type                = "GITHUB"
    location            = "<REPO>"
    git_clone_depth     = 1
    report_build_status = false
    buildspec           = "buildspec_pr.yml"
  }

  build_timeout = 60
}

# I chose not to manage this webhook via TF for simplicity's sake. This will create a hook that builds on PR and push. Disable the `push` option

resource "aws_codebuild_webhook" "pr" {
  project_name  = "${aws_codebuild_project.pr.name}"
  branch_filter = "master"
}
