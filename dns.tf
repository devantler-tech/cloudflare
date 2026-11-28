# DNS records this repository owns. Every value here is already published in
# public DNS, so the records are reviewed in the open; the account and zone
# identifiers stay in the encrypted configuration.
#
# Records that the platform's external-dns owns stay with it, together with
# their `_externaldns.` TXT registry. That includes the Email sender's SES
# `bounce` records. Certificate challenges stay with their issuer.
# `scripts/apply-dns.sh` imports a declared record when exactly one live
# record has the same name, type and content, and refuses an import that would
# change it.

# The site entry points. They stay separate resources so a reviewed change can
# hand one to external-dns with a `removed` block that keeps the record.
#
# The apex follows www, which external-dns points at the platform gateway, so
# the site keeps working if the gateway address changes. It was already a
# CNAME, so this is an in-place edit of one record and never leaves a gap.
# Roll back by restoring `devantler.github.io` with `proxied = false`.
resource "cloudflare_dns_record" "apex" {
  zone_id  = cloudflare_zone.primary.id
  name     = "devantler.tech"
  type     = "CNAME"
  content  = "www.devantler.tech"
  ttl      = 1
  proxied  = true
  comment  = "Follows www to the platform gateway"
  settings = { flatten_cname = false }
}

# external-dns serves www from the business site's public route. It took over
# the old www CNAME through a one-time ownership record (forgotten below),
# replaced it with the gateway addresses and owns them through its own
# `_externaldns.a-www` and `_externaldns.aaaa-www` records. This repository
# manages none of them.
removed {
  from = cloudflare_dns_record.www_external_dns_owner

  lifecycle {
    destroy = false
  }
}

removed {
  from = cloudflare_dns_record.www

  lifecycle {
    destroy = false
  }
}

resource "cloudflare_dns_record" "ksail_docs" {
  zone_id  = cloudflare_zone.primary.id
  name     = "ksail.devantler.tech"
  type     = "CNAME"
  content  = "devantler-tech.github.io"
  ttl      = 1
  proxied  = false
  comment  = "GitHub Pages"
  settings = { flatten_cname = false }
}

# Company Email is delivered to the platform's own mail server
# (devantler-tech/platform#5481); mail.devantler.tech is published by the
# platform. The former second iCloud MX record is retired through
# .github/dns-retirements.json. Rollback: revert this change, which points this
# record back to mx01.mail.icloud.com and recreates mx02.mail.icloud.com. The
# iCloud SPF include and DKIM record below stay until iCloud is retired.
resource "cloudflare_dns_record" "mail_mx_01" {
  zone_id  = cloudflare_zone.primary.id
  name     = "devantler.tech"
  type     = "MX"
  content  = "mail.devantler.tech"
  priority = 10
  ttl      = 3600
  proxied  = false
  settings = {}
}

resource "cloudflare_dns_record" "mail_spf" {
  zone_id  = cloudflare_zone.primary.id
  name     = "devantler.tech"
  type     = "TXT"
  content  = "\"v=spf1 include:icloud.com ~all\""
  ttl      = 3600
  proxied  = false
  settings = {}
}

resource "cloudflare_dns_record" "mail_dmarc" {
  zone_id  = cloudflare_zone.primary.id
  name     = "_dmarc.devantler.tech"
  type     = "TXT"
  content  = "\"v=DMARC1; p=none; rua=mailto:b5a283adfc26471c8ee5facda309570b@dmarc-reports.cloudflare.net\""
  ttl      = 1
  proxied  = false
  settings = {}
}

resource "cloudflare_dns_record" "mail_dkim_sig1" {
  zone_id  = cloudflare_zone.primary.id
  name     = "sig1._domainkey.devantler.tech"
  type     = "CNAME"
  content  = "sig1.dkim.devantler.tech.at.icloudmailadmin.com"
  ttl      = 3600
  proxied  = false
  settings = { flatten_cname = false }
}

resource "cloudflare_dns_record" "apple_domain" {
  zone_id  = cloudflare_zone.primary.id
  name     = "devantler.tech"
  type     = "TXT"
  content  = "\"apple-domain=e9xblGFwUZq601pe\""
  ttl      = 3600
  proxied  = false
  settings = {}
}

# Domain ownership proofs for external services.
resource "cloudflare_dns_record" "apple_business_verification" {
  zone_id  = cloudflare_zone.primary.id
  name     = "devantler.tech"
  type     = "TXT"
  content  = "\"apple-domain-verification=4dQV9V0uTcnCM2Vu\""
  ttl      = 1
  proxied  = false
  comment  = "Apple Business identity verification"
  settings = {}
}

resource "cloudflare_dns_record" "github_organization_verification" {
  zone_id  = cloudflare_zone.primary.id
  name     = "_gh-devantler-tech-o.devantler.tech"
  type     = "TXT"
  content  = "\"05ddf7694b\""
  ttl      = 1
  proxied  = false
  comment  = "GitHub Organization Challenge"
  settings = {}
}

resource "cloudflare_dns_record" "github_pages_verification_personal" {
  zone_id  = cloudflare_zone.primary.id
  name     = "_github-pages-challenge-devantler.devantler.tech"
  type     = "TXT"
  content  = "\"543a342b74e6ce2f3f31b118a5ead2\""
  ttl      = 1
  proxied  = false
  comment  = "GitHub Pages Challenge"
  settings = {}
}

resource "cloudflare_dns_record" "github_pages_verification_organization" {
  zone_id  = cloudflare_zone.primary.id
  name     = "_github-pages-challenge-devantler-tech.devantler.tech"
  type     = "TXT"
  content  = "\"95af3e964364c659e04e4fbc58cce9\""
  ttl      = 1
  proxied  = false
  comment  = "GitHub Pages Challenge"
  settings = {}
}

resource "cloudflare_dns_record" "visual_studio_marketplace_verification" {
  zone_id  = cloudflare_zone.primary.id
  name     = "_visual-studio-marketplace-devantler.devantler.tech"
  type     = "TXT"
  content  = "\"e403e2c7-8fd4-4721-847b-23a083f773a6\""
  ttl      = 1
  proxied  = false
  comment  = "Visual Studio Marketplace"
  settings = {}
}
