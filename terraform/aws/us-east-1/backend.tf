terraform {
  backend "s3" {
    bucket         = "bff-overmind-prod-terraform-state"
    key            = "aws/us-east-1/overmind.tfstate"
    region         = "us-east-1"
    dynamodb_table = "bff-overmind-prod-terraform-locks"
    encrypt        = true
  }
}
