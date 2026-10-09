output "vpn_gateway_id" {
  description = "Null in a stage with no sites."
  value       = one(aws_vpn_gateway.this[*].id)
}

# What a site's operator needs to bring the tunnels up. The addresses are
# public, and the key ARNs grant nothing on their own.
output "sites" {
  value = {
    for site, connection in aws_vpn_connection.this : site => {
      vpn_connection_id = connection.id
      tunnel1_address   = connection.tunnel1_address
      tunnel2_address   = connection.tunnel2_address
      preshared_key_arn = connection.preshared_key_arn
    }
  }
}
