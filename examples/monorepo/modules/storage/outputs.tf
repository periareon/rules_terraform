output "bucket_name" {
  description = "Name of the bucket that was created."
  value       = null_resource.bucket.triggers.name
}
