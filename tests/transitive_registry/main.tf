terraform {
  required_version = ">= 1.0"
}

# The only `module` block in this fixture, and deliberately so.
#
# `cloudposse/security-group/aws` is itself composed of a registry module — it
# declares `module "this" { source = "cloudposse/label/null" }`. Nothing here
# names that grandchild and no `deps` entry can, because it only becomes
# visible once the parent archive has been fetched and read. Resolving one
# level deep leaves the engine looking for a module nobody installed.
module "sg" {
  source  = "cloudposse/security-group/aws"
  version = "2.2.0"

  vpc_id = "vpc-00000000000000000"
}
