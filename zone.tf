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
# - The AI training crawler policy (`ai_training = "disallow"`) answered GPTBot,
#   ClaudeBot and PerplexityBot with 403 at the edge, although the site's
#   robots.txt allows every crawler. "Block AI bots" (`ai_bots_protection`) was
#   already off and stays off. Each site states its crawler policy in its own
#   robots.txt instead.
#
# Every other bot setting keeps its live value. Most unset attributes are
# computed; the two the provider would otherwise reset (a static default and an
# optional, non-computed flag) are ignored so this resource never changes them.
resource "cloudflare_zone_setting" "email_obfuscation" {
  zone_id    = cloudflare_zone.primary.id
  setting_id = "email_obfuscation"
  value      = "off"
}

# Network Error Logging makes visitors' browsers store a reporting policy for
# seven days and send failed-connection reports to Cloudflare. Off, responses
# stop setting that policy, which removes it as a consent question under the
# Danish cookie order (BEK 1148/2011). A browser that already stored it keeps it
# until it expires, at most seven days later. The platform's own monitoring is
# unaffected (#84).
resource "cloudflare_zone_setting" "nel" {
  zone_id    = cloudflare_zone.primary.id
  setting_id = "nel"
  value      = { enabled = false }
}

resource "cloudflare_bot_management" "primary" {
  zone_id            = cloudflare_zone.primary.id
  fight_mode         = false
  enable_js          = false
  crawler_protection = "disabled"
  ai_bots_protection = "disabled"
  ai_training        = "disabled"

  lifecycle {
    ignore_changes = [ai_bots_migration_opt_out, bot_preference_sync_enabled]
  }
}
