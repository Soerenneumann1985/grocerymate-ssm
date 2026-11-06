terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region  = "eu-central-1"
  profile = "default"
}

# ---------- Parameter ----------

resource "aws_ssm_parameter" "db_host" {
  name  = "/grocerymate/prod/db_host"
  type  = "String"
  value = "postgresql-grocerymate.cx4mkc6ui9f5.eu-central-1.rds.amazonaws.com"
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/grocerymate/prod/db_name"
  type  = "String"
  value = "grocerymate_db"
}

resource "aws_ssm_parameter" "db_user" {
  name  = "/grocerymate/prod/db_user"
  type  = "String"
  value = "grocery_user"
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/grocerymate/prod/db_password"
  type  = "SecureString"
  value = var.db_password
}

resource "aws_ssm_parameter" "jwt_secret_key" {
  name  = "/grocerymate/prod/jwt_secret_key"
  type  = "SecureString"
  value = var.jwt_secret_key
}

# ---------- Leserechte für die EC2 ----------

data "aws_caller_identity" "current" {}

data "aws_iam_role" "ec2_role" {
  name = "grocery-ec2-role"
}

resource "aws_iam_role_policy" "ssm_read" {
  name = "grocerymate-prod-ssm-read"
  role = data.aws_iam_role.ec2_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParametersByPath"]
      Resource = "arn:aws:ssm:eu-central-1:${data.aws_caller_identity.current.account_id}:parameter/grocerymate/*"
    }]
  })
}

# ---------- ECR-Leserechte für die EC2 ----------

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = data.aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
