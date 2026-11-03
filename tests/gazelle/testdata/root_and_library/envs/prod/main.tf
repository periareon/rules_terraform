terraform {
  backend "s3" {
    bucket = "state"
    key    = "prod"
  }
}

module "net" {
  source = "../../modules/net"
  cidr   = "10.0.0.0/16"
}
