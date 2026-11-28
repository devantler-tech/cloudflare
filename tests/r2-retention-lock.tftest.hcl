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

run "protect_account_removal_journal" {
  command = plan

  variables {
    r2_buckets = {
      audit-archive = {
        jurisdiction        = "eu"
        retention_lock_days = 90
      }
      recovery-journal = {
        jurisdiction            = "eu"
        retention_lock_days     = 30
        account_removal_journal = true
      }
    }
    r2_lifecycle_rules = {
      recovery-journal = [{
        id                                 = "abandoned-uploads"
        abort_multipart_uploads_after_days = 7
      }]
    }
  }

  assert {
    condition = alltrue([
      length(cloudflare_r2_bucket_lock.retention) == 2,
      cloudflare_r2_bucket_lock.retention["audit-archive"].rules[0].condition.max_age_seconds == 7776000,
      cloudflare_r2_bucket_lock.retention["recovery-journal"].jurisdiction == "eu",
      cloudflare_r2_bucket_lock.retention["recovery-journal"].rules[0].enabled,
      cloudflare_r2_bucket_lock.retention["recovery-journal"].rules[0].prefix == "",
      cloudflare_r2_bucket_lock.retention["recovery-journal"].rules[0].condition.max_age_seconds == 2592000,
      cloudflare_r2_bucket_lifecycle.rules["recovery-journal"].rules[0].delete_objects_transition == null,
    ])
    error_message = "The journal requires 30 days of EU protection with separate, controlled cleanup."
  }
}

run "reject_account_removal_journal_without_eu" {
  command = plan

  variables {
    r2_buckets = {
      recovery-journal = {
        account_removal_journal = true
        retention_lock_days     = 30
      }
    }
  }

  expect_failures = [var.r2_buckets]
}

run "reject_archive_window_for_account_removal_journal" {
  command = plan

  variables {
    r2_buckets = {
      recovery-journal = {
        jurisdiction            = "eu"
        retention_lock_days     = 90
        account_removal_journal = true
      }
    }
  }

  expect_failures = [var.r2_buckets]
}

run "reject_unlocked_account_removal_journal" {
  command = plan

  variables {
    r2_buckets = {
      recovery-journal = {
        jurisdiction            = "eu"
        account_removal_journal = true
      }
    }
  }

  expect_failures = [var.r2_buckets]
}

run "reject_expiring_account_removal_journal" {
  command = plan

  variables {
    r2_buckets = {
      recovery-journal = {
        jurisdiction            = "eu"
        retention_lock_days     = 30
        account_removal_journal = true
      }
    }
    r2_lifecycle_rules = {
      recovery-journal = [{
        id                        = "premature-expiration"
        prefix                    = "accounts/"
        delete_objects_after_days = 31
      }]
    }
  }

  expect_failures = [var.r2_lifecycle_rules]
}
