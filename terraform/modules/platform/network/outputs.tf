output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = [for subnet in aws_subnet.public : subnet.id]
}

output "private_subnet_ids" {
  value = [for subnet in aws_subnet.private : subnet.id]
}

output "public_subnet_cidrs" {
  description = "Where the ALB's own interfaces live, which is the address a request through it arrives from. OpenBao trusts a forwarded-for header only from these."
  value       = [for subnet in aws_subnet.public : subnet.cidr_block]
}

output "private_subnet_cidrs" {
  description = "Bounds hilt's AppRole token to the VPC. Coarse by nature: it separates the VPC from the internet, not one task from another."
  value       = [for subnet in aws_subnet.private : subnet.cidr_block]
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "service_security_group_id" {
  value = aws_security_group.service.id
}

output "lambda_security_group_id" {
  value = aws_security_group.lambda.id
}

output "database_security_group_id" {
  value = aws_security_group.database.id
}

output "namespace_id" {
  value = aws_service_discovery_private_dns_namespace.internal.id
}

output "namespace_name" {
  value = aws_service_discovery_private_dns_namespace.internal.name
}
