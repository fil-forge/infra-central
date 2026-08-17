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

# What a public hostname should point at: the accelerator where the stage has
# one, the load balancer otherwise. Callers alias these without knowing which
# they got, which is what lets the accelerator be turned on for a stage without
# touching a single service's DNS record.
output "public_dns_name" {
  description = "Alias target for the stage's public hostnames."
  value       = var.enable_global_accelerator ? aws_globalaccelerator_accelerator.this[0].dns_name : aws_lb.this.dns_name
}

output "public_zone_id" {
  description = "Hosted zone of the alias target above. Global Accelerator publishes one fixed zone for every accelerator; the ALB's is per-region."
  value       = var.enable_global_accelerator ? aws_globalaccelerator_accelerator.this[0].hosted_zone_id : aws_lb.this.zone_id
}
