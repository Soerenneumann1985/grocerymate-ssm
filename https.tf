# ---------------------------------------------
# 1. Bestehende Infrastruktur einlesen
# ---------------------------------------------
data "aws_instance" "app" {
  instance_id = var.instance_id
}

data "aws_subnet" "app" {
  id = data.aws_instance.app.subnet_id
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_subnet.app.vpc_id]
  }
}

# Von AWS gepflegte IP-Liste aller CloudFront-Server
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

# ---------------------------------------------
# 2. Security Group fuer den Load Balancer
#    Port 80 nur von CloudFront, nicht von ueberall
# ---------------------------------------------
resource "aws_security_group" "alb" {
  name        = "grocerymate-alb-sg"
  description = "ALB: HTTP nur von CloudFront"
  vpc_id      = data.aws_subnet.app.vpc_id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------
# 3. Application Load Balancer
# ---------------------------------------------
resource "aws_lb" "app" {
  name               = "grocerymate-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.public.ids
}

# Zielgruppe: dahin schickt der ALB die Anfragen
resource "aws_lb_target_group" "app" {
  name     = "grocerymate-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = data.aws_subnet.app.vpc_id

  health_check {
    path = "/"
    matcher = "200-399"
  }
}

# Deine EC2-Instanz in die Zielgruppe haengen
resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = data.aws_instance.app.id
  port             = 5000
}

# HTTP-Listener auf Port 80
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# EC2 erlaubt Port 5000 nur vom Load Balancer
resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  security_group_id            = tolist(data.aws_instance.app.vpc_security_group_ids)[0]
  from_port                    = 5000
  to_port                      = 5000
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.alb.id
}

# ---------------------------------------------
# 4. CloudFront mit HTTPS vor dem Load Balancer
# ---------------------------------------------
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "app" {
  enabled = true

  origin {
    domain_name = aws_lb.app.dns_name
    origin_id   = "grocerymate-alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id         = "grocerymate-alb"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "cloudfront_url" {
  value = "https://${aws_cloudfront_distribution.app.domain_name}"
}

resource "aws_ebs_encryption_by_default" "main" {
  enabled = true
}
