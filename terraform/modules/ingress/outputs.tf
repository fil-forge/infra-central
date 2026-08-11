output "listener_arn" {
  value = aws_lb_listener.https.arn
}

output "dns_name" {
  value = aws_lb.this.dns_name
}

output "zone_id" {
  value = aws_lb.this.zone_id
}

output "route53_zone_id" {
  value = data.aws_route53_zone.this.zone_id
}
