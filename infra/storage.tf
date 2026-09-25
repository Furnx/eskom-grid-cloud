# The raw landing zone: the cloud counterpart of the local data/raw directory.
#
# Objects are keyed raw/<area_id>/<YYYYMMDD_HHMMSS>.json — identical to the
# local layout, because the application's S3RawSink builds the same path.
# S3 has no real directories; the slashes are just part of the key.

resource "aws_s3_bucket" "raw" {
  # Bucket names are globally unique across all AWS accounts, so the account ID
  # is appended. Naming it here means no console-generated suffix surprises.
  bucket = "${var.project_name}-${data.aws_caller_identity.current.account_id}"
}

# Keeps superseded versions of an object instead of discarding them. The
# extraction writes a new key per run, so this mainly protects against an
# accidental overwrite or deletion.
resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Belt and braces: even if an object or bucket policy were to grant public
# access, these settings override it. This is the control whose absence is
# behind most publicised "data left open on S3" incidents.
resource "aws_s3_bucket_public_access_block" "raw" {
  bucket = aws_s3_bucket.raw.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning means deleted or overwritten objects linger and accumulate storage.
# Current versions are kept indefinitely, but superseded ones expire, on two
# clocks because the two prefixes behave differently:
#   raw/        the history the project exists to collect. Each object is
#               written once, so old versions are rare; kept a month.
#   warehouse/  one file, replaced every hour (a few MB each time) and
#               rebuildable from raw/; a month of old versions would be ~2 GB.
# Nothing else is stored in this bucket.
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    id     = "expire-noncurrent-raw"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }

  rule {
    id     = "expire-noncurrent-warehouse"
    status = "Enabled"

    filter {
      prefix = "warehouse/"
    }

    noncurrent_version_expiration {
      noncurrent_days = var.warehouse_noncurrent_version_expiration_days
    }
  }

  # Lifecycle rules are rejected while versioning is still being enabled.
  depends_on = [aws_s3_bucket_versioning.raw]
}
