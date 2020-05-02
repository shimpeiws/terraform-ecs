provider "aws" {
  region  = "ap-northeast-1"
  profile = "default"
  version = "~> 2.44"
}

terraform {
  required_version = "~> 0.12.0"
  backend "s3" {
    bucket = "shimpeiws-codebuild-ecs"
    key    = "./terraform.tfstate"
    region = "ap-northeast-1"
  }
}
