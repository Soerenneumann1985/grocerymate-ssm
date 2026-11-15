# ---------------------------------------------
# 1. Das Secret (der "Tresor")
# ---------------------------------------------
resource "aws_secretsmanager_secret" "db_credentials" {
  name = "grocerymate/prod/db-credentials"
}

# ---------------------------------------------
# 2. Der Inhalt des Tresors (die Zugangsdaten als JSON)
# ---------------------------------------------
resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    username = var.db_username
    password = var.db_password
    engine   = "postgres"
    host     = var.db_host
    port     = 5432      # Standard-Port von PostgreSQL
    dbname   = var.db_name
  })
}

# ---------------------------------------------
# 3. Nicht geheime Einstellungen -> Parameter Store
# ---------------------------------------------
resource "aws_ssm_parameter" "app_env" {
  name  = "/grocerymate/prod/app_env"
  type  = "String"
  value = "production"
}

resource "aws_ssm_parameter" "log_level" {
  name  = "/grocerymate/prod/log_level"
  type  = "String"
  value = "INFO"
}

# ---------------------------------------------
# 4. Policy: EC2-Rolle darf GENAU dieses Secret lesen
# ---------------------------------------------
resource "aws_iam_role_policy" "secrets_read" {
  name = "grocerymate-prod-secrets-read"
  role = data.aws_iam_role.ec2_role.name      # Name deiner EC2-Rolle aus main.tf

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.db_credentials.arn
      }
    ]
  })
}
