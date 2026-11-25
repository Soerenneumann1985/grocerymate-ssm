# Log-Gruppe für die Container-Logs
# retention_in_days begrenzt die Aufbewahrung -> ohne das liegen Logs ewig und kosten dauerhaft
resource "aws_cloudwatch_log_group" "app" {
  name              = "/grocerymate/app"
  retention_in_days = 7
}

# Erlaubt der EC2-Rolle, Logs nach CloudWatch zu schreiben
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "grocerymate-prod-cloudwatch-logs"
  role = "grocery-ec2-role"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      # ":*" = alle Log-Streams innerhalb dieser einen Gruppe, nicht das ganze Konto
      Resource = "${aws_cloudwatch_log_group.app.arn}:*"
    }]
  })
}

# --- Bestehende Ressourcen nachschlagen (legt nichts an) ---

data "aws_lb" "alb" {
  name = "grocerymate-alb"
}

data "aws_db_instance" "db" {
  db_instance_identifier = "postgresql-grocerymate"   # <-- Name aus RDS -> Datenbanken
}

# --- Dashboard ---

resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = "grocerymate-prod"

  # Ein Dashboard ist im Kern ein JSON-Dokument aus Widgets.
  # x/y/width/height sind Rasterfelder, die Breite geht von 0 bis 24.
  dashboard_body = jsonencode({
    widgets = [

      # Reihe 1 links: Last auf der Instanz
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EC2 CPU"
          region = "eu-central-1"
          view   = "timeSeries"
          period = 300                    # Punkt alle 5 Minuten
          metrics = [
            # Format: [ Namespace, MetrikName, DimensionName, DimensionWert ]
            ["AWS/EC2", "CPUUtilization", "InstanceId", "i-0bfbcb32b44ba85aa"],
            ["CWAgent", "mem_used_percent", "InstanceId", "i-0bfbcb32b44ba85aa"]
          ]
        }
      },

      # Reihe 1 rechts: kommt die App beim Nutzer an?
      {
        type   = "metric"
        x      = 12                       # direkt neben Widget 1
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB Requests und Fehler"
          region = "eu-central-1"
          view   = "timeSeries"
          period = 300
          stat   = "Sum"                  # Fehler zaehlt man, man mittelt sie nicht
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", data.aws_lb.alb.arn_suffix],
            # 5XX = Fehler der Anwendung selbst, 4XX waere Nutzerfehler
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            # Ziel nicht erreichbar -> Container tot oder Health Check rot
            [".", "UnHealthyHostCount", ".", "."]
          ]
        }
      },

      # Reihe 2: Datenbank
      {
        type   = "metric"
        x      = 0
        y      = 6                        # 6 = Hoehe der ersten Reihe, also darunter
        width  = 12
        height = 6
        properties = {
          title  = "RDS"
          region = "eu-central-1"
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", data.aws_db_instance.db.db_instance_identifier],
            [".", "CPUUtilization", ".", "."],
            # Freier Arbeitsspeicher: faellt er stetig, hast du ein Leck
            [".", "FreeableMemory", ".", "."]
          ]
        }
      },

      # Reihe 2 rechts: die Logs aus Schritt 1 direkt im Dashboard
      {
        type   = "log"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Letzte Log-Zeilen"
          region = "eu-central-1"
          # Logs Insights-Abfrage - die Sprache brauchst du gleich in Schritt 3 wieder
          query  = "SOURCE '/grocerymate/app' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view   = "table"
        }
      }

    ]
  })
}

# Zaehlt Zeilen, die auf einen Anwendungsfehler hindeuten
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "grocerymate-app-errors"
  log_group_name = aws_cloudwatch_log_group.app.name

  # Das Muster: Zeile enthaelt ERROR ODER Exception ODER Traceback.
  # ?-Praefix = ODER-Verknuepfung. Ohne ? waere es ein UND.
  # Anfuehrungszeichen = Suche nach genau diesem Text, Gross-/Kleinschreibung zaehlt.
  pattern = "?ERROR ?Exception ?Traceback"

  metric_transformation {
    name      = "AppErrorCount"
    namespace = "GroceryMate/AppMetrics"   # eigener Namespace laut Architekturbild
    value     = "1"                        # jede Treffer-Zeile zaehlt 1
    default_value = "0"                    # ohne Treffer 0 melden statt Luecke
    unit      = "Count"
  }
}

# Zweiter Filter: HTTP-500er aus den Zugriffszeilen des Servers
resource "aws_cloudwatch_log_metric_filter" "http_5xx" {
  name           = "grocerymate-http-5xx"
  log_group_name = aws_cloudwatch_log_group.app.name

  # Flask/Werkzeug schreibt Zeilen wie: "GET / HTTP/1.1" 500 -
  pattern = "\" 500 \""

  metric_transformation {
    name          = "Http5xxCount"
    namespace     = "GroceryMate/AppMetrics"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# --- SNS: der Briefkasten, an den Alarme ihre Meldung schicken ---

resource "aws_sns_topic" "alerts" {
  name = "grocerymate-alerts"
}

resource "aws_sns_topic_subscription" "mail" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "soerenneumann85@gmx.de"   # <-- deine Mail-Adresse
}
# WICHTIG: Nach dem apply kommt eine Bestaetigungsmail von AWS.
# Erst nach Klick auf "Confirm subscription" bekommst du Alarme.

# --- Alarm 1: Anwendungsfehler in den Logs ---
resource "aws_cloudwatch_metric_alarm" "app_errors" {
  alarm_name          = "grocerymate-app-errors"
  alarm_description   = "Fehlerzeilen in den Anwendungslogs"
  namespace           = "GroceryMate/AppMetrics"
  metric_name         = "AppErrorCount"
  statistic           = "Sum"
  period              = 300                       # Fenster: 5 Minuten
  evaluation_periods  = 1                         # ein Fenster reicht zum Ausloesen
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"            # keine Daten = kein Alarm
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]  # auch Entwarnung melden
}

# --- Alarm 2: 5XX am Load Balancer ---
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "grocerymate-alb-5xx"
  alarm_description   = "Server-Fehler am Load Balancer"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = data.aws_lb.alb.arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3                         # Einzelfehler nicht sofort melden
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# --- Alarm 3: Arbeitsspeicher der EC2 (braucht den Agenten aus Schritt B) ---
resource "aws_cloudwatch_metric_alarm" "ec2_memory" {
  alarm_name          = "grocerymate-ec2-memory"
  alarm_description   = "Arbeitsspeicher der Instanz laeuft voll"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  dimensions          = { InstanceId = "i-0bfbcb32b44ba85aa" }
  statistic           = "Average"                 # Auslastung mittelt man
  period              = 300
  evaluation_periods  = 2                         # zweimal hintereinander, gegen Ausreisser
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Konto-ID und Region nicht hart reinschreiben, sondern von AWS holen

data "aws_region" "current" {}

# Zugriffsrichtlinie des Themas (resource-based policy):
# haengt am Thema selbst und sagt, WER dort veroeffentlichen darf
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 1) Standardrechte des Kontoinhabers erhalten.
        #    Diese Policy ersetzt die Vorgabe komplett - ohne diesen Block
        #    koenntest du das Thema spaeter schlechter verwalten.
        Sid       = "AllowOwnerManagement"
        Effect    = "Allow"
        Principal = { AWS = data.aws_caller_identity.current.account_id }
        Action = [
          "sns:GetTopicAttributes",
          "sns:SetTopicAttributes",
          "sns:AddPermission",
          "sns:RemovePermission",
          "sns:DeleteTopic",
          "sns:Subscribe",
          "sns:ListSubscriptionsByTopic",
          "sns:Publish"
        ]
        Resource  = aws_sns_topic.alerts.arn
      },
      {
        # 2) Nur der Dienst CloudWatch, nur Publish, nur Alarme
        #    aus diesem Konto und dieser Region.
        Sid       = "AllowCloudWatchAlarmsToPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          # Welche Quelle darf ausloesen: nur Alarme, Region + Konto fix
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:alarm:*"
          }
          # Zweiter Riegel gegen das "Confused Deputy"-Problem
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

# --- Alarm 4: CPU der EC2 ---
resource "aws_cloudwatch_metric_alarm" "ec2_cpu" {
  alarm_name          = "grocerymate-ec2-cpu-high"
  alarm_description   = "CPU der Instanz dauerhaft hoch"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = "i-0bfbcb32b44ba85aa" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2            # zweimal hintereinander, Lastspitzen sind normal
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "missing"    # Instanz gestoppt = kein Alarm, nur "keine Daten"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# --- Alarm 5: Ziel hinter dem Load Balancer nicht erreichbar ---
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy" {
  alarm_name          = "grocerymate-alb-unhealthy-hosts"
  alarm_description   = "Health Check des Targets schlaegt fehl"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  # Diese Metrik braucht ZWEI Dimensionen: Load Balancer UND Zielgruppe
  dimensions = {
    LoadBalancer = data.aws_lb.alb.arn_suffix
    TargetGroup  = data.aws_lb_target_group.app.arn_suffix
  }
  statistic           = "Maximum"    # ein einziges krankes Ziel reicht
  period              = 60           # schneller takten, das ist ein Ausfall
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"  # keine Daten heisst hier: etwas stimmt nicht
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

data "aws_lb_target_group" "app" {
  name = "grocerymate-tg"
}

# Erlaubt dem CloudWatch-Agenten, eigene Metriken zu senden (PutMetricData)
resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = "grocery-ec2-role"
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

