output "zone_id" {
  description = "Cloudflare zone ID consumed by inventory and recovery procedures."
  value       = cloudflare_zone.primary.id
}

output "account_token_values" {
  description = "One-time token values. Transfer directly to approved custody; never print or persist locally."
  value       = { for name, token in cloudflare_account_token.tokens : name => token.value }
  sensitive   = true
}

