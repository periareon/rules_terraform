output "id" {
  description = "Canonical `<namespace>-<environment>-<name>` identifier."
  value       = module.label.id
}

output "tags" {
  description = "Tag map derived from the same inputs."
  value       = module.label.tags
}
