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
    name     = string
    type     = string
    content  = optional(string)
    ttl      = optional(number, 1)
    proxied  = optional(bool, false)
    priority = optional(number)
    comment  = optional(string, "Managed by devantler-tech/cloudflare")
    tags     = optional(set(string), ["owner:cloudflare-repo"])
  }))
  default = {}
}

variable "r2_buckets" {
  description = "R2 buckets keyed by their immutable bucket name."
  type = map(object({
    jurisdiction  = optional(string, "default")
    location      = optional(string)
    storage_class = optional(string, "Standard")
  }))
  default = {}
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
