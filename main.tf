# AWS provider
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = "us-east-1"
}

# Azure provider
provider "azurerm" {
  features {}

  client_id       = var.azure_client_id
  client_secret   = var.azure_client_secret
  subscription_id = var.azure_subscription_id
  tenant_id       = var.azure_tenant_id
}

# Define an S3 bucket for static website hosting
resource "aws_s3_bucket" "weather_app" {
  bucket = "weather-tracker-app-bucket-202600"

  website {
    index_document = "index.html"
    error_document = "error.html"
  }

}

resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket                  = aws_s3_bucket.weather_app.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Upload website files
resource "aws_s3_object" "website_index" {
  bucket       = aws_s3_bucket.weather_app.id
  key          = "index.html"
  source       = "website/index.html"
  content_type = "text/html"

  etag = filemd5("website/index.html")
}

resource "aws_s3_object" "website_style" {
  bucket       = aws_s3_bucket.weather_app.id
  key          = "styles.css"
  source       = "website/styles.css"
  content_type = "text/css"

  etag = filemd5("website/styles.css")
}

resource "aws_s3_object" "website_script" {
  bucket       = aws_s3_bucket.weather_app.id
  key          = "script.js"
  source       = "website/script.js"
  content_type = "application/javascript"

  etag = filemd5("website/script.js")
}

# Upload assets
resource "aws_s3_object" "website_assets" {
  for_each = fileset("website/assets", "*")
  bucket   = aws_s3_bucket.weather_app.id
  key      = "assets/${each.value}"
  source   = "website/assets/${each.value}"
}

# Public access policy
resource "aws_s3_bucket_policy" "bucket_policy" {
  bucket = aws_s3_bucket.weather_app.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "arn:aws:s3:::${aws_s3_bucket.weather_app.id}/*"
      }
    ]
  })
}

# Define Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-static-website"
  location = "East US"
}

# Define Storage Account with Static Website
resource "azurerm_storage_account" "storage" {
  name                     = "mystorageaccount202600"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  static_website {
    index_document = "index.html"
  }
}

resource "azurerm_storage_blob" "main_files" {
  for_each = toset([
    "index.html",
    "styles.css",
    "script.js"
  ])

  name                   = each.value
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = "$web"
  type                   = "Block"
  source                 = "${path.module}/website/${each.value}"

  content_type = lookup({
    "html" = "text/html",
    "css"  = "text/css",
    "js"   = "application/javascript"
  }, split(".", each.value)[1], "application/octet-stream")
}

resource "azurerm_storage_blob" "assets" {
  for_each = fileset("website/assets", "*")

  name                   = "assets/${each.value}"
  storage_account_name   = azurerm_storage_account.storage.name
  storage_container_name = "$web"
  type                   = "Block"
  source                 = "${path.module}/website/assets/${each.value}"
}

#############################################
# ROUTE53 HOSTED ZONE
#############################################

resource "aws_route53_zone" "main" {
  name = "viyan-626-411.site"
}

#############################################
# HEALTH CHECKS
#############################################

# AWS (CloudFront) Health Check
resource "aws_route53_health_check" "aws_health_check" {
  type              = "HTTPS"
  fqdn              = "d26p2y3aucl8qv.cloudfront.net"
  port              = 443
  request_interval  = 30
  failure_threshold = 3
}

# Azure Health Check
resource "aws_route53_health_check" "azure_health_check" {
  type              = "HTTPS"
  fqdn              = "mystorageaccount202600.z13.web.core.windows.net"
  port              = 443
  request_interval  = 30
  failure_threshold = 3
}

#############################################
# PRIMARY RECORD (AWS - CloudFront)
#############################################

resource "aws_route53_record" "primary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "viyan-626-411.site"
  type    = "A"

  alias {
    name                   = "d26p2y3aucl8qv.cloudfront.net"
    zone_id                = "Z2FDTNDATAQYW2" # CloudFront hosted zone ID
    evaluate_target_health = true
  }

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.aws_health_check.id
}

#############################################
# SECONDARY RECORD (AZURE - BACKUP)
#############################################

resource "aws_route53_record" "secondary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.viyan-626-411.site"
  type    = "CNAME"

  ttl     = 300
  records = ["mystorageaccount202600.z13.web.core.windows.net"]

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier  = "secondary"
  health_check_id = aws_route53_health_check.azure_health_check.id
}
