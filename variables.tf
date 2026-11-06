variable "db_password" {
  description = "Passwort des PostgreSQL-Benutzers"
  type        = string
  sensitive   = true
}

variable "jwt_secret_key" {
  description = "Geheimer Schlüssel zum Signieren der JWT-Login-Tokens"
  type        = string
  sensitive   = true
}