terraform {
  required_version = ">= 1.0"
}

output "greeting" {
  description = "A greeting message"
  value       = "Hello from ${var.name}!"
}
