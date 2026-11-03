terraform {
  backend "s3" {
    bucket = "state"
    key    = "app"
  }
}

resource "null_resource" "app" {}
