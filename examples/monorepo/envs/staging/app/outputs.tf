output "name" {
  description = "Canonical name from the shared naming library."
  value       = module.naming.id
}

output "release" {
  description = "Release handle from the random provider, which only staging uses."
  value       = random_pet.release.id
}

output "owner_tags" {
  description = "Tags from the registry module this root names directly."
  value       = module.tags.tags
}
