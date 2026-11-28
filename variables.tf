variable "account_id" {
  description = "Cloudflare account ID."
  type        = string
}

variable "zone_name" {
  description = "Primary authoritative DNS zone name."
  type        = string
}

variable "dns_records" {
  description = "Authoritative DNS records keyed by a stable logical name."
  type = map(object({
    name            = string
    type            = string
    content         = optional(string)
    ttl             = optional(number, 1)
    proxied         = optional(bool, false)
    priority        = optional(number)
    comment         = optional(string)
    tags            = optional(set(string), [])
    private_routing = optional(bool)
    settings = optional(object({
      flatten_cname = optional(bool)
      ipv4_only     = optional(bool)
      ipv6_only     = optional(bool)
    }))
  }))
  default = {}
}

variable "r2_buckets" {
  description = "R2 buckets keyed by their immutable bucket name."
  type = map(object({
    jurisdiction            = optional(string, "default")
    location                = optional(string)
    storage_class           = optional(string, "Standard")
    retention_lock_days     = optional(number)
    account_removal_journal = optional(bool, false)
  }))
  default = {}

  validation {
    condition = alltrue([
      for bucket in values(var.r2_buckets) :
      bucket.retention_lock_days == null ? true : (
        bucket.retention_lock_days >= 90 && floor(bucket.retention_lock_days) == bucket.retention_lock_days
      )
      if !bucket.account_removal_journal
    ])
    error_message = "An archive retention lock requires a whole number of days, with a minimum of 90."
  }

  validation {
    condition = alltrue([
      for bucket in values(var.r2_buckets) :
      bucket.jurisdiction == "eu" && bucket.retention_lock_days == 30
      if bucket.account_removal_journal
    ])
    error_message = "An account removal journal requires EU storage and a 30-day retention lock."
  }

  # These are the lock jurisdictions accepted by the pinned Cloudflare provider.
  validation {
    condition = alltrue([
      for bucket in values(var.r2_buckets) :
      bucket.retention_lock_days == null || contains(["default", "eu", "fedramp"], lower(bucket.jurisdiction))
    ])
    error_message = "The pinned Cloudflare provider supports archive retention locks in the default, eu and fedramp jurisdictions."
  }
}

variable "r2_lifecycle_rules" {
  description = "R2 lifecycle rules keyed by bucket name."
  type = map(list(object({
    id                                         = string
    prefix                                     = optional(string, "")
    enabled                                    = optional(bool, true)
    abort_multipart_uploads_after_days         = optional(number)
    delete_objects_after_days                  = optional(number)
    transition_to_infrequent_access_after_days = optional(number)
  })))
  default = {}

  validation {
    condition = alltrue([
      for bucket, rules in var.r2_lifecycle_rules : alltrue([
        for rule in rules : !rule.enabled || rule.delete_objects_after_days == null
      ])
      if try(var.r2_buckets[bucket].account_removal_journal, false)
    ])
    error_message = "An account removal journal requires controlled cleanup and cannot use automatic object expiration."
  }
}

variable "account_tokens" {
  description = "Least-privilege token policies keyed by stable purpose. Generated token values are sensitive state."
  type = map(object({
    name = string
    policies = list(object({
      effect               = optional(string, "allow")
      permission_group_ids = set(string)
      resources            = map(string)
    }))
    allowed_cidrs = optional(set(string), [])
    denied_cidrs  = optional(set(string), [])
    not_before    = optional(string)
    expires_on    = optional(string)
  }))
  default = {}
}
