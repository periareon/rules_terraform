output "subnet_cidrs" {
  description = "One CIDR per subnet, carved out of var.cidr_block."
  value       = local.subnet_cidrs
}
