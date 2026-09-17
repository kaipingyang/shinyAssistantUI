secure_storage_config <- function(root, ...) {
  shinyAssistantUI:::.normalize_diagnostics_config(
    c(list(enabled = TRUE, directory = root, buffer_max_events = 1000L,
           max_file_bytes = 4096L, retention_max_bytes = 8192,
           retention_seconds = 10), list(...)),
    sample_uniform = function() 0
  )
}

test_that("secure storage publishes file and lease under one retention lock", {
  root <- tempfile("secure-storage-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  storage <- shinyAssistantUI:::.new_diagnostics_storage(secure_storage_config(root))
  on.exit(storage$close(), add = TRUE)
  snap <- storage$snapshot()
  expect_identical(snap$category, "ok")
  expect_true(snap$active)
  expect_true(file.exists(file.path(root, snap$basename)))
  expect_true(file.exists(file.path(root, snap$lease_basename)))
  expect_false(dir.exists(file.path(root, ".retention.lock")))
  identity <- shinyAssistantUI:::.native_fs_stat_at(
    shinyAssistantUI:::.native_fs_open_root(root), snap$basename
  )
  expect_true(identity$regular)
  expect_identical(identity$nlink, 1)
  expect_identical(identity$mode, 384L) # 0600
})

test_that("secure storage close publishes marker and removes matching lease", {
  root <- tempfile("secure-close-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  storage <- shinyAssistantUI:::.new_diagnostics_storage(secure_storage_config(root))
  before <- storage$snapshot()
  expect_true(storage$write(charToRaw("{\"schema\":1}\n")))
  expect_true(storage$close())
  after <- storage$snapshot()
  expect_false(after$active)
  expect_false(file.exists(file.path(root, before$lease_basename)))
  expect_true(file.exists(file.path(root, before$closed_basename)))
  expect_false(storage$close())
})

test_that("close busy is immediate and uses lock-free no-replace marker", {
  root <- tempfile("secure-close-busy-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  storage <- shinyAssistantUI:::.new_diagnostics_storage(secure_storage_config(root))
  before <- storage$snapshot()
  lock <- shinyAssistantUI:::.diagnostics_retention_lock_acquire(root)
  expect_true(is.list(lock))
  started <- proc.time()[["elapsed"]]
  expect_true(storage$close())
  expect_lt(proc.time()[["elapsed"]] - started, 0.1)
  expect_true(file.exists(file.path(root, before$closed_basename)))
  expect_true(file.exists(file.path(root, before$lease_basename)))
  expect_true(shinyAssistantUI:::.diagnostics_retention_lock_release(lock))
})

test_that("recovery removes orphan lease and preserves complete orphan log", {
  root <- tempfile("secure-recovery-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  native <- shinyAssistantUI:::.native_fs_open_root(root)
  orphan_log <- paste0("diag-v1-1000000000000-", strrep("a", 32), ".jsonl")
  orphan_lease <- paste0("diag-v1-1000000000001-", strrep("b", 32), ".jsonl.lease")
  expect_identical(shinyAssistantUI:::.native_fs_atomic_write_at(
    native, ".tmp-log", orphan_log, charToRaw("{\"schema\":1}\n")
  ), "ok")
  expect_identical(shinyAssistantUI:::.native_fs_atomic_write_at(
    native, ".tmp-lease", orphan_lease, charToRaw("{}\n")
  ), "ok")
  result <- shinyAssistantUI:::.diagnostics_storage_recover(root)
  expect_true(file.exists(file.path(root, orphan_log)))
  expect_false(file.exists(file.path(root, orphan_lease)))
  expect_gte(result$recovered, 1L)
})

test_that("retention never follows symlinks and protects live legacy producer", {
  root <- tempfile("secure-retention-"); dir.create(root, mode = "0700")
  outside <- tempfile("outside-sentinel-"); writeLines("KEEP", outside)
  on.exit(unlink(c(root, outside), recursive = TRUE, force = TRUE), add = TRUE)
  link <- file.path(root, paste0("diag-v1-1000000000000-", strrep("c", 32), ".jsonl"))
  expect_true(file.symlink(outside, link))
  legacy <- file.path(root, sprintf("diagnostics-g_a-s_b-p%d-u_c.jsonl", Sys.getpid()))
  writeLines("legacy", legacy); Sys.chmod(legacy, "0600", use_umask = FALSE)
  result <- shinyAssistantUI:::.diagnostics_retention_pass(
    root, now = as.POSIXct("2026-09-15", tz = "UTC"), max_bytes = 1,
    max_age = 1
  )
  expect_identical(readLines(outside), "KEEP")
  expect_true(file.exists(link))
  expect_true(file.exists(legacy))
  expect_gte(result$protected_count, 1L)
})


test_that("legacy pre-delete revalidation protects PID reuse unknown and identity races", {
  identity <- list(dev = 1, ino = 2, mode = 384L, nlink = 1, size = 7,
                   mtime = 10, ctime = 11, uid = 1, regular = TRUE)
  candidate <- list(
    basename = "diagnostics-g_a-s_b-p123-u_c.jsonl", pid = 123L,
    identity = identity, active = FALSE, unsafe = FALSE, kind = "legacy"
  )
  run <- function(probes, identities = list(identity, identity)) {
    probe_index <- 0L; stat_index <- 0L; removed <- 0L
    result <- shinyAssistantUI:::.diagnostics_revalidate_legacy_delete(
      root_handle = structure(list(), class = "fake-root"), candidate = candidate,
      stat = function(root, basename) {
        stat_index <<- stat_index + 1L
        identities[[min(stat_index, length(identities))]]
      },
      probe = function(pid) {
        probe_index <<- probe_index + 1L
        probes[[min(probe_index, length(probes))]]
      },
      remove = function(...) { removed <<- removed + 1L; "ok" },
      token = function() strrep("a", 32)
    )
    list(result = result, removed = removed)
  }
  dead <- list(category = "dead", startToken = NULL)
  expect_true(run(list(dead, dead))$result)
  expect_identical(run(list(dead, dead))$removed, 1L)
  expect_false(run(list(
    list(category = "live", startToken = "new"),
    list(category = "live", startToken = "new")
  ))$result)
  expect_false(run(list(
    list(category = "unknown", startToken = NULL), dead
  ))$result)
  changed <- identity; changed$ctime <- 12
  expect_false(run(list(dead, dead), list(identity, changed))$result)
})
