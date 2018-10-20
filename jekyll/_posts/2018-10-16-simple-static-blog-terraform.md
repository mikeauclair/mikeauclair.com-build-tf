---
layout: post
title:  "A simple static blog via Terraform"
date:   2018-10-16 10:15:00 -0500
categories: blog
tags: terraform
---
When I decided to spin up this blog, I knew I wanted the solution I put in place to have a few core requirements:
1. It needed low-touch content editing with familiar workflows
1. It needed to be automatically provisioned (I don't want to pick up any snowflake-infrastructure bad habits, fiddling around in the AWS console)
1. It needed to be low-cost

I landed on the following approach:
- Use Jekyll as the core of the blog, since I've used it a bunch, and it's a pretty light lift to implement generally
- Serving of the blog would be handled by CloudFront, backed by an S3 bucket
- Per-PR preview builds would be rendered into an S3 bucket, with a link to the preview posted in the PR comments
- AWS CodeBuild would be my CI solution, since it requires no durable infrastructure, integrates nicely with IAM, and you only pay for compute during builds, satisfying my cost requirement

To automatically provision the blog, I used Terraform - it's a broadly used tool with solid support for AWS primitives, and is open source unlike CloudFormation, making it a compelling choice for this use case. Below is the annotated source of the terraform I used if you want to roll out something similar. Note: You'd probably want to break this up into modules if you were to build on it, but I skipped modularizing to cut down on noise here.

## Set up some boilerplate and environmental bits
```hcl
provider "aws" {}

# you'll need to provide the state bucket name on terraform init...
terraform {
  backend "s3" {
    key    = "website"
    region = "us-east-1"
  }
}

# ...and the bucket names on run
variable prod_bucket_name {}
variable preview_bucket_name {}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# You need to create the ACM certificate outside of TF since it require manual intervention
data "aws_acm_certificate" "blog" {
  domain   = "<DOMAIN NAME>"
  statuses = ["ISSUED"]
}
```

## Create buckets
```hcl
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

# since preview is just for posting preview links on the GitHub PR, just make it world readable

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
```

## Add cloudfront distribution
```hcl

# Create a unique ID for the production S3 bucket - this comes into play if you are routing to multiple sources

locals {
  s3_origin_id = "S3-${var.prod_bucket_name}"
}

# Create an identity for the cloudfront distribution - this lets us not open the S3 bucket to the world

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

  aliases = ["<DOMAIN_NAME>"]

  # Simple cache config, and toss all methods but GET and HEAD since we're just reading
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${local.s3_origin_id}"

    # Throw these away since they are not needed

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

  # US, CA, EU edges only because I'm cheap like that

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Use the certificate we imported earlier, and use SNI so that we don't pay for dedicated IPs

  viewer_certificate {
    acm_certificate_arn = "${data.aws_acm_certificate.blog.arn}"
    ssl_support_method  = "sni-only"
  }
}

# Add a policy onto the production bucket that lets the cloudfront identity we created earlier read from it
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
```

## The Preview Build
```hcl
resource "aws_codebuild_project" "pr" {
  name          = "websitePR"
  build_timeout = "5"
  service_role  = "${aws_iam_role.codebuild-websitePR-service-role.arn}"

  # Codebuild will let you ship up a zip, jar, etc to S3 if your build requires it - we'll manually call AWS APIs via the CLI
  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = "LINUX_CONTAINER"
    image        = "aws/codebuild/ruby:2.5.1"
    compute_type = "BUILD_GENERAL1_SMALL"

    # Populate this from Parameter Store to keep it secret

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
    # We have separate builds for the two environments. The production build uses the default path (buildspec.yml)
    buildspec           = "buildspec_pr.yml"
  }

  build_timeout = 60
}

# I chose not to manage this webhook via TF for simplicity's sake. This will create a hook that builds on PR and push. Disable the `push` option in the GitHub interface

resource "aws_codebuild_webhook" "pr" {
  project_name  = "${aws_codebuild_project.pr.name}"
  branch_filter = "master"
}

# Policy to let CodeBuild spawn infrastructure to run builds

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

# Policy to let CodeBuild access a namespace in ParameterStore (to read the GitHub token for writing comments on the PR)

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

# Policy to let CodeBuild write to the preview S3 bucket

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
```

## The production build
```hcl
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

# Like preview, role to let CodeBuild spin up infrastructure...

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

# ...and write to the production bucket
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
```

## buildspec.yml
```yaml
version: 0.2

phases:
  install:
    commands:
      - cd jekyll
      - bundle install
  build:
    commands:
      - bundle exec jekyll build
      - export BUCKET_NAME=<YOUR BUCKET NAME HERE>
      - aws s3 sync _site s3://$BUCKET_NAME --delete
```

## buildspec_pr.yml
```yaml
version: 0.2

env:
  parameter-store:
    "GH_TOKEN": "/CodeBuild/GH_TOKEN"

phases:
  install:
    commands:
      - cd jekyll
      - bundle install
  build:
    commands:
      # Prepend the PR number to the urls in the jekyll build...
      - bundle exec jekyll build --baseurl=${CODEBUILD_SOURCE_VERSION}
      - export BUCKET_NAME=<YOUR BUCKET NAME HERE>
      # ...and the sync destination
      - export SITE_PATH=$BUCKET_NAME/${CODEBUILD_SOURCE_VERSION}
      - aws s3 sync _site s3://$SITE_PATH
      # since CODEBUILD_SOURCE_VERSION comes through as pr/<PR_NUMBER> so we just trim the first 3 characters off to get the number by itself
      - export PR_ID=$(echo $CODEBUILD_SOURCE_VERSION | cut -c 4-)
      - 'curl -H "Authorization: token ${GH_TOKEN}" --data-binary "{\"body\": \"Preview rendered at http://$BUCKET_NAME.s3-website-us-east-1.amazonaws.com/${CODEBUILD_SOURCE_VERSION}\"}" https://api.github.com/repos/<OWNER>/<REPO>/issues/${PR_ID}/comments'
```
