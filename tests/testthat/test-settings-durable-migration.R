test_that("settings atomic publish is durable and rejects symlink target", {
  home <- tempfile("settings-durable-"); dir.create(home, mode = "0700")
  on.exit(unlink(home, recursive = TRUE, force = TRUE), add = TRUE)
  path <- file.path(home, "addin_settings.json")
  first <- shinyAssistantUI:::.transact_addin_setting(
    "diagnosticsEnabled", 0, FALSE, path
  )
  expect_identical(first$category, "ok")
  expect_identical(as.octmode(file.info(path)$mode), as.octmode("600"))
  second <- shinyAssistantUI:::.transact_addin_setting(
    "diagnosticsEnabled", 1, TRUE, path
  )
  expect_identical(second$category, "ok")
  expect_true(shinyAssistantUI:::.read_addin_settings(path)$diagnosticsEnabled)

  outside <- tempfile("settings-outside-"); writeLines("KEEP", outside)
  link <- file.path(home, "linked.json")
  expect_true(file.symlink(outside, link))
  result <- shinyAssistantUI:::.transact_addin_setting(
    "diagnosticsEnabled", 0, FALSE, link
  )
  expect_false(result$ok)
  expect_identical(readLines(outside), "KEEP")
})

test_that("RDS migration journals prepared/published state and safely deletes matching legacy", {
  home <- tempfile("settings-migration-durable-"); dir.create(home, mode = "0700")
  on.exit(unlink(home, recursive = TRUE, force = TRUE), add = TRUE)
  addin <- file.path(home, ".claude_addin"); dir.create(addin, mode = "0700")
  legacy <- list(
    default_permission_mode.rds = "default",
    composer_density.rds = "compact",
    run_r_enabled.rds = TRUE,
    mode_visibility.rds = list(showBypass = FALSE, showYolo = FALSE)
  )
  for (name in names(legacy)) {
    saveRDS(legacy[[name]], file.path(addin, name))
    Sys.chmod(file.path(addin, name), "0600", use_umask = FALSE)
  }
  expect_true(shinyAssistantUI:::.migrate_addin_settings(home))
  expect_true(file.exists(file.path(addin, "addin_settings.json")))
  expect_false(any(file.exists(file.path(addin, names(legacy)))))
  expect_false(file.exists(file.path(addin, ".settings-rds-migration-v2.json")))
  expect_false(shinyAssistantUI:::.migrate_addin_settings(home))
})

test_that("migration journal owner takeover is fail-closed for reuse and unknown", {
  old <- list(pid = 123, startToken = "old", createdUtc = 1, token = strrep("a", 32))
  dead <- shinyAssistantUI:::.settings_migration_owner_status(
    old, probe = local({ i <- 0L; function(pid) {
      i <<- i + 1L; list(category = "dead", startToken = NULL)
    }})
  )
  expect_identical(dead, "dead")
  reused <- shinyAssistantUI:::.settings_migration_owner_status(
    old, probe = function(pid) list(category = "live", startToken = "new")
  )
  expect_identical(reused, "reused")
  unknown <- shinyAssistantUI:::.settings_migration_owner_status(
    old, probe = function(pid) list(category = "unknown", startToken = NULL)
  )
  expect_identical(unknown, "unknown")
})

test_that("published journal recovery supplements only identity and hash matching deletes", {
  expect_true(is.function(shinyAssistantUI:::.settings_migration_recover_locked))
  expect_true(is.function(shinyAssistantUI:::.settings_migration_capture_entry))
  expect_true(is.function(shinyAssistantUI:::.native_sha256))
})


migration_fixture <- function() {
  home <- tempfile("settings-migration-fixture-"); dir.create(home, mode = "0700")
  directory <- file.path(home, ".claude_addin"); dir.create(directory, mode = "0700")
  values <- list(
    default_permission_mode.rds = "default",
    mode_visibility.rds = list(showBypass = FALSE, showYolo = FALSE),
    composer_density.rds = "compact",
    run_r_enabled.rds = TRUE
  )
  for (name in names(values)) {
    saveRDS(values[[name]], file.path(directory, name))
    Sys.chmod(file.path(directory, name), "0600", use_umask = FALSE)
  }
  list(home = home, directory = directory, values = values,
       path = file.path(directory, "addin_settings.json"))
}

prepare_migration_crash <- function(fixture, publish = FALSE, published_state = FALSE) {
  lock <- shinyAssistantUI:::.settings_acquire_lock(fixture$path)
  root <- shinyAssistantUI:::.native_fs_open_root(fixture$directory)
  paths <- shinyAssistantUI:::.settings_migration_legacy_paths(fixture$home)
  entries <- lapply(names(paths), function(field)
    shinyAssistantUI:::.settings_migration_capture_entry(root, field, paths[[field]]))
  candidate <- shinyAssistantUI:::.settings_migration_candidate(entries)
  journal <- list(
    version = 1L, migrationId = strrep("b", 32), state = "prepared",
    owner = shinyAssistantUI:::.settings_migration_lock_owner(lock), takeover = NULL,
    entries = entries,
    candidateSha256 = shinyAssistantUI:::.native_sha256(
      shinyAssistantUI:::.settings_json_bytes(candidate)
    )
  )
  stopifnot(shinyAssistantUI:::.settings_migration_write_journal(
    fixture$directory, root, lock, journal, create = TRUE
  ))
  if (publish) stopifnot(shinyAssistantUI:::.settings_atomic_publish(candidate, fixture$path, lock))
  if (published_state) {
    journal$state <- "published"
    stopifnot(shinyAssistantUI:::.settings_migration_write_journal(
      fixture$directory, root, lock, journal, create = FALSE
    ))
  }
  shinyAssistantUI:::.settings_release_lock(lock)
  list(journal = journal, candidate = candidate)
}

dead_probe <- function(pid) list(category = "dead", startToken = NULL)

test_that("prepared journal takeover recovers before and after settings publish", {
  for (publish in c(FALSE, TRUE)) {
    fixture <- migration_fixture(); on.exit(unlink(fixture$home, recursive = TRUE, force = TRUE), add = TRUE)
    prepare_migration_crash(fixture, publish = publish)
    lock <- shinyAssistantUI:::.settings_acquire_lock(fixture$path)
    result <- shinyAssistantUI:::.settings_migration_recover_locked(
      fixture$path, lock, probe = dead_probe
    )
    expect_identical(result$category, "completed")
    expect_true(shinyAssistantUI:::.settings_release_lock(lock))
    expect_true(file.exists(fixture$path))
    expect_false(file.exists(file.path(fixture$directory, ".settings-rds-migration-v2.json")))
    expect_false(any(file.exists(file.path(fixture$directory, names(fixture$values)))))
  }
})

test_that("published partial-delete crash is idempotently supplemented", {
  fixture <- migration_fixture(); on.exit(unlink(fixture$home, recursive = TRUE, force = TRUE), add = TRUE)
  state <- prepare_migration_crash(fixture, publish = TRUE, published_state = TRUE)
  unlink(file.path(fixture$directory, state$journal$entries[[1L]]$legacyBasename))
  lock <- shinyAssistantUI:::.settings_acquire_lock(fixture$path)
  result <- shinyAssistantUI:::.settings_migration_recover_locked(
    fixture$path, lock, probe = dead_probe
  )
  expect_identical(result$category, "completed")
  expect_true(shinyAssistantUI:::.settings_release_lock(lock))
  expect_false(any(file.exists(file.path(fixture$directory, names(fixture$values)))))
})

test_that("PID reuse and unknown probe quarantine journal and retain every RDS", {
  probes <- list(
    reused = function(pid) list(category = "live", startToken = "different"),
    unknown = function(pid) list(category = "unknown", startToken = NULL)
  )
  for (kind in names(probes)) {
    fixture <- migration_fixture(); on.exit(unlink(fixture$home, recursive = TRUE, force = TRUE), add = TRUE)
    prepare_migration_crash(fixture)
    lock <- shinyAssistantUI:::.settings_acquire_lock(fixture$path)
    result <- shinyAssistantUI:::.settings_migration_recover_locked(
      fixture$path, lock, probe = probes[[kind]]
    )
    expect_identical(result$category, paste0("quarantined_", kind))
    expect_true(shinyAssistantUI:::.settings_release_lock(lock))
    expect_false(file.exists(file.path(fixture$directory, ".settings-rds-migration-v2.json")))
    expect_true(any(grepl("^\\.settings-rds-migration-v2\\.json\\.quarantine-",
                          list.files(fixture$directory, all.files = TRUE))))
    expect_true(all(file.exists(file.path(fixture$directory, names(fixture$values)))))
    expect_false(file.exists(fixture$path))
    expect_false(shinyAssistantUI:::.migrate_addin_settings(fixture$home))
    expect_true(all(file.exists(file.path(fixture$directory, names(fixture$values)))))
  }
})

test_that("published recovery retains replaced legacy but deletes matching entries", {
  fixture <- migration_fixture(); on.exit(unlink(fixture$home, recursive = TRUE, force = TRUE), add = TRUE)
  state <- prepare_migration_crash(fixture, publish = TRUE, published_state = TRUE)
  changed <- file.path(fixture$directory, state$journal$entries[[1L]]$legacyBasename)
  unlink(changed); saveRDS("plan", changed); Sys.chmod(changed, "0600", use_umask = FALSE)
  lock <- shinyAssistantUI:::.settings_acquire_lock(fixture$path)
  result <- shinyAssistantUI:::.settings_migration_recover_locked(
    fixture$path, lock, probe = dead_probe
  )
  expect_identical(result$category, "completed_with_retained")
  expect_identical(result$retained, 1L)
  expect_true(shinyAssistantUI:::.settings_release_lock(lock))
  expect_true(file.exists(changed))
  expect_false(any(file.exists(file.path(
    fixture$directory,
    vapply(state$journal$entries[-1L], `[[`, character(1), "legacyBasename")
  ))))
})

test_that("valid v2 without journal never reads or deletes legacy RDS", {
  fixture <- migration_fixture(); on.exit(unlink(fixture$home, recursive = TRUE, force = TRUE), add = TRUE)
  tx <- shinyAssistantUI:::.transact_addin_setting("diagnosticsEnabled", 0, TRUE, fixture$path)
  expect_true(tx$ok)
  before <- unname(tools::md5sum(file.path(fixture$directory, names(fixture$values))))
  expect_false(shinyAssistantUI:::.migrate_addin_settings(fixture$home))
  expect_true(all(file.exists(file.path(fixture$directory, names(fixture$values)))))
  expect_identical(unname(tools::md5sum(file.path(fixture$directory, names(fixture$values)))), before)
  expect_identical(
    shinyAssistantUI:::.native_sha256(charToRaw("abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  )
})


test_that("prepared recovery quarantines changed legacy hash and publishes nothing", {
  fixture <- migration_fixture(); on.exit(unlink(fixture$home, recursive = TRUE, force = TRUE), add = TRUE)
  state <- prepare_migration_crash(fixture)
  changed <- file.path(fixture$directory, state$journal$entries[[1L]]$legacyBasename)
  unlink(changed); saveRDS("plan", changed); Sys.chmod(changed, "0600", use_umask = FALSE)
  lock <- shinyAssistantUI:::.settings_acquire_lock(fixture$path)
  result <- shinyAssistantUI:::.settings_migration_recover_locked(
    fixture$path, lock, probe = dead_probe
  )
  expect_identical(result$category, "quarantined")
  expect_true(shinyAssistantUI:::.settings_release_lock(lock))
  expect_false(file.exists(fixture$path))
  expect_true(all(file.exists(file.path(fixture$directory, names(fixture$values)))))
  expect_true(any(grepl("^\\.settings-rds-migration-v2\\.json\\.quarantine-",
                        list.files(fixture$directory, all.files = TRUE))))
})
