write_inactive_diagnostic <- function(root, token = strrep("a", 32), ts = 123L) {
  dir.create(root, recursive = TRUE, mode = "0700", showWarnings = FALSE)
  handle <- shinyAssistantUI:::.native_fs_open_root(root)
  basename <- sprintf("diag-v1-%013.0f-%s.jsonl", 1000000000000, token)
  row <- shinyAssistantUI:::.diagnostics_canonical_row(
    "chunk_summary", list(count = 1, bytes = 2), now = function() ts
  )
  status <- shinyAssistantUI:::.native_fs_atomic_write_at(
    handle, paste0(".tmp-", token), basename,
    charToRaw(shinyAssistantUI:::.diagnostics_canonical_encode(row))
  )
  stopifnot(identical(status, "ok"))
  basename
}

test_that("support bundle capability is truthful", {
  cap <- shinyAssistantUI:::.diagnostics_export_capability(
    rstudio_available = function() TRUE,
    supervision = function() list(category = "ok")
  )
  expect_named(cap, c("version", "available", "reason", "schema", "canonical", "network"))
  expect_true(cap$available)
  expect_identical(cap$reason, "ok")
  expect_true(cap$canonical)
  expect_false(cap$network)
  no_supervision <- shinyAssistantUI:::.diagnostics_export_capability(
    rstudio_available = function() TRUE,
    supervision = function() list(category = "unsupported")
  )
  expect_false(no_supervision$available)
  expect_identical(no_supervision$reason, "unsupported")
})

test_that("export canonicalizer rebuilds exact rows and rejects hostile source", {
  row <- shinyAssistantUI:::.diagnostics_canonical_row(
    "chunk_summary", list(count = 1, bytes = 2), now = function() 123
  )
  canonical <- shinyAssistantUI:::.diagnostics_canonical_encode(row)
  rebuilt <- shinyAssistantUI:::.diagnostics_export_canonicalize(charToRaw(canonical))
  expect_identical(rawToChar(rebuilt$bytes), canonical)
  expect_identical(rebuilt$rows, 1L)
  expect_null(shinyAssistantUI:::.diagnostics_export_canonicalize(
    charToRaw(sub('"count":1', '"count":1e0', canonical, fixed = TRUE))
  ))
  expect_null(shinyAssistantUI:::.diagnostics_export_canonicalize(
    charToRaw('{"schema":1,"event":"chunk_summary","ts":123,"metrics":{"count":1,"count":2,"bytes":2}}\n')
  ))
})

test_that("support bundle includes inactive canonical logs and never overwrites", {
  root <- tempfile("bundle-root-"); dir.create(root, mode = "0700")
  destination <- tempfile("support-bundle-", fileext = ".zip")
  on.exit(unlink(c(root, destination), recursive = TRUE, force = TRUE), add = TRUE)
  write_inactive_diagnostic(root)
  result <- shinyAssistantUI:::.diagnostics_export_worker_main(
    root, destination, parent_pid = Sys.getpid(),
    parent_start_token = shinyAssistantUI:::.native_process_start_token(Sys.getpid()),
    bootstrap = function(...) TRUE
  )
  expect_identical(result$category, "ok")
  expect_true(file.exists(destination))
  bytes <- readBin(destination, "raw", n = file.info(destination)$size)
  expect_true(shinyAssistantUI:::.native_verify_store_zip(bytes))
  before <- tools::md5sum(destination)
  second <- shinyAssistantUI:::.diagnostics_export_worker_main(
    root, destination, parent_pid = Sys.getpid(),
    parent_start_token = shinyAssistantUI:::.native_process_start_token(Sys.getpid()),
    bootstrap = function(...) TRUE
  )
  expect_identical(second$category, "existing")
  expect_identical(tools::md5sum(destination), before)
})

test_that("picker cancel is inert and select starts worker only after return", {
  events <- character()
  controller <- shinyAssistantUI:::.new_support_bundle_controller(
    diagnostics_root = tempfile("bundle-controller-"),
    picker = function() { events <<- c(events, "picker"); NULL },
    start_worker = function(...) { events <<- c(events, "worker"); list() }
  )
  expect_identical(controller$pick(), "cancelled")
  expect_identical(events, "picker")

  destination <- tempfile(fileext = ".zip")
  controller <- shinyAssistantUI:::.new_support_bundle_controller(
    diagnostics_root = tempfile("bundle-controller-"),
    picker = function() { events <<- c(events, "picker-selected"); destination },
    start_worker = function(...) { events <<- c(events, "worker"); list() }
  )
  expect_identical(controller$pick(), "started")
  expect_identical(tail(events, 2L), c("picker-selected", "worker"))
  expect_true(any(vapply(shinyAssistantUI:::.claude_action_items(), function(item)
    identical(item$id, "export-support-bundle"), logical(1))))
})

test_that("support bundle worker is supervised and reaps its complete tree", {
  skip_if_not_installed("callr")
  root <- tempfile("bundle-worker-root-"); dir.create(root, mode = "0700")
  destination <- tempfile("bundle-worker-", fileext = ".zip")
  on.exit(unlink(c(root, destination), recursive = TRUE, force = TRUE), add = TRUE)
  write_inactive_diagnostic(root, token = strrep("d", 32))
  baseline <- shinyAssistantUI:::.owned_descendant_pids(Sys.getpid())
  worker <- shinyAssistantUI:::.start_diagnostics_export_worker(root, destination)
  expect_true(is.list(worker))
  result <- worker$result(timeout = 10)
  expect_identical(result$category, "ok")
  expect_true(file.exists(destination))
  remaining <- setdiff(
    shinyAssistantUI:::.owned_descendant_pids(Sys.getpid()), baseline
  )
  expect_identical(length(remaining), 0L)
})

test_that("export action is omitted when capability is unavailable", {
  items <- shinyAssistantUI:::.claude_action_items(include_export = FALSE)
  expect_false(any(vapply(items, function(item)
    identical(item$id, "export-support-bundle"), logical(1))))
})


test_that("export capture binds size and identity to the opened fd", {
  root <- tempfile("bundle-fd-root-"); dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  write_inactive_diagnostic(root, token = strrep("e", 32))
  capture <- shinyAssistantUI:::.diagnostics_export_capture(root)
  on.exit(for (entry in capture$handles) shinyAssistantUI:::.native_file_close(entry$handle), add = TRUE)
  expect_identical(capture$category, "ok")
  expect_length(capture$handles, 1L)
  fd_identity <- shinyAssistantUI:::.native_file_stat(capture$handles[[1L]]$handle)
  expect_identical(capture$handles[[1L]]$size, fd_identity$size)
  expect_identical(capture$handles[[1L]]$identity[c("dev", "ino", "size", "ctime")],
                   fd_identity[c("dev", "ino", "size", "ctime")])
})

test_that("full ZIP verifier scans every canonical entry and manifest", {
  row <- shinyAssistantUI:::.diagnostics_canonical_row(
    "chunk_summary", list(count = 1, bytes = 2), now = function() 123
  )
  canonical <- charToRaw(shinyAssistantUI:::.diagnostics_canonical_encode(row))
  manifest <- function(rows, bytes) charToRaw(paste0(as.character(jsonlite::toJSON(list(
    schema = 1L, fileCount = 1L, rowCount = rows, canonicalBytes = bytes,
    minTs = 123, maxTs = 123, eventCounts = list(chunk_summary = rows),
    limits = list(files = 128L, sourceBytes = 8 * 1024^2,
                  rawBytes = 48 * 1024^2, rows = 200000L,
                  outputBytes = 64 * 1024^2)
  ), auto_unbox = TRUE, null = "null", digits = NA)), "\n"))
  valid <- shinyAssistantUI:::.diagnostics_store_zip(list(
    "manifest.json" = manifest(1L, length(canonical)), "logs/0001.jsonl" = canonical
  ))
  expect_true(shinyAssistantUI:::.diagnostics_verify_store_zip(valid))
  noncanonical <- charToRaw(sub('"count":1', '"count":1e0', rawToChar(canonical), fixed = TRUE))
  hostile <- shinyAssistantUI:::.diagnostics_store_zip(list(
    "manifest.json" = manifest(1L, length(noncanonical)), "logs/0001.jsonl" = noncanonical
  ))
  expect_true(shinyAssistantUI:::.native_verify_store_zip(hostile))
  expect_false(shinyAssistantUI:::.diagnostics_verify_store_zip(hostile))
  inconsistent <- shinyAssistantUI:::.diagnostics_store_zip(list(
    "manifest.json" = manifest(2L, length(canonical)), "logs/0001.jsonl" = canonical
  ))
  expect_false(shinyAssistantUI:::.diagnostics_verify_store_zip(inconsistent))
})
