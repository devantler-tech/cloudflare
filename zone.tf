# Zone features that rewrite the HTML of proxied pages, or override a site's own
# crawler policy, stay off, so visitors get exactly the bytes the origin serves.
# The business site forbids injected scripts, and a strict
# Content-Security-Policy would block them anyway.
#
# - Email Address Obfuscation replaces mailto links with a JavaScript decoder,
#   which hides the published contact address from visitors without JS.
# - Bot Fight Mode injects the JavaScript Detections script on every page; on
#   the Free plan it cannot be turned off separately. It can also challenge the
#   platform's API and sign-in traffic, which sign-in protects instead.
# - AI Labyrinth (`crawler_protection`) adds hidden honeypot links to pages.
# - "Block AI bots" (`ai_bots_protection`) answered AI crawlers with 403 although
#   the site's robots.txt allows every crawler, keeping the business site out of
#   AI search. Each site states its crawler policy in its own robots.txt.
#
# Every other bot setting keeps its live value, because the provider treats
# unset attributes as computed.
resource "cloudflare_zone_setting" "email_obfuscation" {
  zone_id    = cloudflare_zone.primary.id
  setting_id = "email_obfuscation"
  value      = "off"
}

resource "cloudflare_bot_management" "primary" {
  zone_id            = cloudflare_zone.primary.id
  fight_mode         = false
  enable_js          = false
  crawler_protection = "disabled"
  ai_bots_protection = "disabled"
}
