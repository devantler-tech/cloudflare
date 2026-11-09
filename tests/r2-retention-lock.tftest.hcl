mock_provider "cloudflare" {}

variables {
  account_id = "00000000000000000000000000000000"
  zone_name  = "example.com"
}

run "protect_only_the_archive" {
  command = plan

  variables {
    r2_buckets = {
      audit-archive = {
        jurisdiction        = "eu"
        retention_lock_days = 90
      }
      snapshots = {}
    }
  }

  assert {
    condition     = length(cloudflare_r2_bucket_lock.retention) == 1
    error_message = "Only the explicit archive bucket gets an object lock."
  }

  assert {
    condition = alltrue([
      cloudflare_r2_bucket_lock.retention["audit-archive"].bucket_name == "audit-archive",
      cloudflare_r2_bucket_lock.retention["audit-archive"].jurisdiction == "eu",
      cloudflare_r2_bucket_lock.retention["audit-archive"].rules[0].enabled,
      cloudflare_r2_bucket_lock.retention["audit-archive"].rules[0].prefix == "",
      cloudflare_r2_bucket_lock.retention["audit-archive"].rules[0].condition.type == "Age",
      cloudflare_r2_bucket_lock.retention["audit-archive"].rules[0].condition.max_age_seconds == 7776000,
      length(cloudflare_r2_bucket_lifecycle.rules) == 0,
    ])
    error_message = "All objects in the private EU archive must be locked for 90 days, without an expiry rule."
  }
}

run "reject_short_retention" {
  command = plan

  variables {
    r2_buckets = {
      audit-archive = {
        retention_lock_days = 89
      }
    }
  }

  expect_failures = [var.r2_buckets]
}

run "reject_fractional_retention" {
  command = plan

  variables {
    r2_buckets = {
      audit-archive = {
        retention_lock_days = 90.5
      }
    }
  }

  expect_failures = [var.r2_buckets]
}

run "reject_retention_in_us" {
  command = plan

  variables {
    r2_buckets = {
      audit-archive = {
        jurisdiction        = "us"
        retention_lock_days = 90
      }
    }
  }

  expect_failures = [var.r2_buckets]
}

run "reject_retention_in_fedramp_high" {
  command = plan

  variables {
    r2_buckets = {
      audit-archive = {
        jurisdiction        = "fedramp-high"
        retention_lock_days = 90
      }
    }
  }

  expect_failures = [var.r2_buckets]
}
