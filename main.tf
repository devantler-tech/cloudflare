resource "cloudflare_zone" "primary" {
  account = {
    id = var.account_id
  }
  name = var.zone_name
  type = "full"

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_dns_record" "records" {
  for_each = var.dns_records

  zone_id  = cloudflare_zone.primary.id
  name     = each.value.name
  type     = each.value.type
  content  = each.value.content
  ttl      = each.value.ttl
  proxied  = each.value.proxied
  priority = each.value.priority
  comment  = each.value.comment
  tags     = each.value.tags
}

resource "cloudflare_r2_bucket" "buckets" {
  for_each = var.r2_buckets

  account_id    = var.account_id
  name          = each.key
  jurisdiction  = each.value.jurisdiction
  location      = each.value.location
  storage_class = each.value.storage_class

  lifecycle {
    prevent_destroy = true
  }
}

resource "cloudflare_r2_bucket_lifecycle" "rules" {
  for_each = var.r2_lifecycle_rules

  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.buckets[each.key].name
  jurisdiction = try(
    cloudflare_r2_bucket.buckets[each.key].jurisdiction,
    "default"
  )
  rules = [
    for rule in each.value : {
      id      = rule.id
      enabled = rule.enabled
      conditions = {
        prefix = rule.prefix
      }
      abort_multipart_uploads_transition = rule.abort_multipart_uploads_after_days == null ? null : {
        condition = {
          max_age = rule.abort_multipart_uploads_after_days * 86400
          type    = "Age"
        }
      }
      delete_objects_transition = rule.delete_objects_after_days == null ? null : {
        condition = {
          max_age = rule.delete_objects_after_days * 86400
          type    = "Age"
        }
      }
      storage_class_transitions = rule.transition_to_infrequent_access_after_days == null ? [] : [{
        condition = {
          max_age = rule.transition_to_infrequent_access_after_days * 86400
          type    = "Age"
        }
        storage_class = "InfrequentAccess"
      }]
    }
  ]
}

resource "cloudflare_account_token" "tokens" {
  for_each = var.account_tokens

  account_id = var.account_id
  name       = each.value.name
  policies = [
    for policy in each.value.policies : {
      effect = policy.effect
      permission_groups = [
        for permission_group_id in policy.permission_group_ids : {
          id = permission_group_id
        }
      ]
      resources = jsonencode(policy.resources)
    }
  ]
  condition = length(each.value.allowed_cidrs) == 0 && length(each.value.denied_cidrs) == 0 ? null : {
    # An empty list is sent as null, not []: `in = []` would require the caller to
    # belong to an empty allowed set and make a deny-only token unusable.
    request_ip = {
      in     = length(each.value.allowed_cidrs) == 0 ? null : each.value.allowed_cidrs
      not_in = length(each.value.denied_cidrs) == 0 ? null : each.value.denied_cidrs
    }
  }
  not_before = each.value.not_before
  expires_on = each.value.expires_on
}

