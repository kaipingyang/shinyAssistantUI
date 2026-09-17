diagnostics_test_config <- function(directory, ...) {
  shinyAssistantUI:::.normalize_diagnostics_config(
    c(list(enabled = TRUE, directory = directory), list(...)),
    sample_uniform = function() 0
  )
}

test_that("generic diagnostics remains default-off and config is bounded", {
  expect_false(shinyAssistantUI:::.normalize_diagnostics_config(NULL)$enabled)
  expect_false(shinyAssistantUI:::.normalize_diagnostics_config(FALSE)$enabled)
  enabled <- shinyAssistantUI:::.normalize_diagnostics_config(
    TRUE, sample_uniform = function() 0
  )
  expect_true(enabled$enabled)
  expect_lte(enabled$frontend_batch_max, enabled$frontend_queue_max)
  expect_identical(enabled$retention_max_bytes, 50 * 1024^2)
  expect_identical(enabled$retention_seconds, 7 * 24 * 60 * 60)
})

test_that("diagnostics env parser is exact and never canonicalizes a disabled path", {
  expect_null(shinyAssistantUI:::.diagnostics_launch_from_env("", "/PRIVATE"))
  expect_false(shinyAssistantUI:::.diagnostics_launch_from_env("off", "/PRIVATE"))
  expect_false(shinyAssistantUI:::.diagnostics_launch_from_env("maybe", "/PRIVATE"))
  expect_identical(
    shinyAssistantUI:::.diagnostics_launch_from_env(" YES ", " /tmp/diag "),
    list(enabled = TRUE, directory = "/tmp/diag")
  )
})

test_that("canonical schema and rows have exact privacy-safe shape", {
  schema <- shinyAssistantUI:::.diagnostics_schema()
  expect_identical(schema$artifactVersion, 1L)
  expect_identical(schema$commonFields, as.list(c("schema", "event", "ts", "metrics")))
  row <- shinyAssistantUI:::.diagnostics_canonical_row(
    "memory_guard_sample",
    list(state = "hard", pssBytes = 1, rssBytes = 2,
         cgroupCurrentBytes = 7, cgroupMaxBytes = 8, cgroupLimit = "limited",
         softPssBytes = 3, hardPssBytes = 4, softRssBytes = 5, hardRssBytes = 6),
    now = function() 10
  )
  expect_named(row, c("schema", "event", "ts", "metrics"))
  expect_null(shinyAssistantUI:::.diagnostics_canonical_row(
    "chunk_summary", list(count = 1, bytes = 2, pid = 3)
  ))
  encoded <- shinyAssistantUI:::.diagnostics_canonical_encode(row)
  expect_false(grepl("pid|path|thread|run|source|error", encoded, ignore.case = TRUE))
  expect_true(endsWith(encoded, "\n"))
})

test_that("writer callback path is event-driven and writes private canonical JSONL", {
  root <- tempfile("diag-writer-")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  callbacks <- list()
  writer <- shinyAssistantUI:::.new_diagnostics_writer(
    diagnostics_test_config(root), schedule = function(callback, delay) {
      callbacks[[length(callbacks) + 1L]] <<- callback
      function() NULL
    }, warn = function(category) NULL,
    elapsed = function() 0
  )
  secret <- "PROMPT-PRIVATE-SENTINEL"
  expect_true(writer$write_event(
    "backend", "chunk_summary", list(count = 1, bytes = nchar(secret))
  ))
  expect_length(callbacks, 1L)
  expect_false(dir.exists(root))
  callbacks[[1L]]()
  path <- writer$snapshot()$path
  expect_true(file.exists(path))
  expect_match(basename(path), "^diag-v1-[0-9]{13}-[0-9a-f]{32}\\.jsonl$")
  if (.Platform$OS.type != "windows") {
    expect_identical(as.octmode(file.info(root)$mode), as.octmode("700"))
    expect_identical(as.octmode(file.info(path)$mode), as.octmode("600"))
  }
  line <- readLines(path, warn = FALSE)
  expect_false(grepl(secret, line, fixed = TRUE))
  row <- jsonlite::fromJSON(line, simplifyVector = FALSE)
  expect_named(row, c("schema", "event", "ts", "metrics"))
  expect_true(writer$close())
  expect_true(writer$close())
})

test_that("writer uses immutable rotations and exact frontend batches", {
  root <- tempfile("diag-rotation-")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  writer <- shinyAssistantUI:::.new_diagnostics_writer(
    diagnostics_test_config(root, max_file_bytes = 4096L,
                            event_max_bytes = 1024L, buffer_max_events = 1000L),
    schedule = NULL, warn = function(category) NULL,
    elapsed = function() 0
  )
  expect_false(writer$ingest_frontend_batch(list(rows = list())))
  expect_false(writer$ingest_frontend_batch(list(
    version = 2L, schema = 1L,
    rows = list(list(schema = 1L, event = "frontend_mount", ts = 1, metrics = list(), extra = 1))
  )))
  expect_true(writer$ingest_frontend_batch(list(
    version = 2L, schema = 1L,
    rows = list(
      list(schema = 1L, event = "frontend_mount", ts = 1L, metrics = list()),
      list(schema = 1L, event = "ui_counts", ts = 2L, metrics = list(
        messageCount = 1L, toolCardCount = 0L, domCardCount = 1L
      ))
    )
  )))
  for (index in seq_len(100L)) {
    writer$write_event("backend", "chunk_summary", list(count = index, bytes = 999999))
    if (index %% 20L == 0L) writer$flush()
  }
  writer$flush(); writer$close()
  files <- list.files(root, pattern = "^diag-v1-.*\\.jsonl$", full.names = TRUE)
  expect_gte(length(files), 2L)
  expect_true(all(file.info(files)$size <= 4096L))
})

test_that("retention age then cap preserves live legacy and unrelated files", {
  root <- tempfile("diag-retention-"); dir.create(root)
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  old <- file.path(root, paste0("diag-v1-1000000000000-", strrep("a", 32), ".jsonl"))
  live <- file.path(root, sprintf("diagnostics-g_a-s_b-p%d-u_c.jsonl", Sys.getpid()))
  unrelated <- file.path(root, "sentinel.keep")
  writeLines("old", old); writeLines("live", live); writeLines("keep", unrelated)
  result <- shinyAssistantUI:::.diagnostics_retention_pass(
    root, now = as.POSIXct("2026-09-15", tz = "UTC")
  )
  expect_false(file.exists(old))
  expect_true(file.exists(live))
  expect_identical(readLines(unrelated), "keep")
  expect_gte(result$deleted_count, 1)
})

test_that("assistantUIServer generic NULL is inert and TRUE is per-session canonical", {
  root <- tempfile("diag-server-")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  disabled <- enabled <- NULL
  handler <- function(message, on_done, ...) on_done()
  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler)
  }, { disabled <<- session$getOutput("chat")$config })
  expect_false("diagnostics" %in% names(disabled))

  shiny::testServer(function(input, output, session) {
    assistantUIServer("chat", handler = handler, diagnostics = list(
      enabled = TRUE, directory = root, sample_rate = 1,
      frontend_batch_ms = 0L, frontend_batch_max = 5L,
      frontend_queue_max = 10L, frontend_batch_max_bytes = 4096L,
      event_max_bytes = 1024L, buffer_max_events = 10L,
      max_file_bytes = 4096L
    ))
  }, {
    enabled <<- session$getOutput("chat")$config$diagnostics
    session$setInputs(chat_input_telemetry = list(
      version = 2L, schema = 1L,
      rows = list(list(schema = 1L, event = "ui_counts", ts = 1, metrics = list(
        messageCount = 1, toolCardCount = 0, domCardCount = 1
      )))
    ))
    session$flushReact()
  })
  expect_named(enabled, c("version", "enabled", "schema", "batchMax",
                          "queueMax", "batchMaxBytes", "eventMaxBytes"))
  expect_false(any(c("generation", "session", "pid") %in% names(enabled)))
  files <- list.files(root, pattern = "^diag-v1-.*\\.jsonl$", full.names = TRUE)
  expect_gte(length(files), 1L)
  rows <- unlist(lapply(files, readLines, warn = FALSE), use.names = FALSE)
  expect_true(all(vapply(rows, function(line) {
    identical(names(jsonlite::fromJSON(line, simplifyVector = FALSE)),
              c("schema", "event", "ts", "metrics"))
  }, logical(1))))
})

test_that("app-wide diagnostics service binds sessions but closes writer only once", {
  root <- tempfile("diag-service-")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)
  callbacks <- list()
  service <- shinyAssistantUI:::.new_diagnostics_service(
    list(enabled = TRUE, directory = root),
    writer_factory = shinyAssistantUI:::.new_diagnostics_writer,
    schedule = function(callback, delay) {
      callbacks[[length(callbacks) + 1L]] <<- callback
      function() NULL
    }
  )
  unbind_a <- service$bind_session(); unbind_b <- service$bind_session()
  expect_identical(service$snapshot()$active_bindings, 2L)
  expect_true(service$emit("run_state", list(phase = "running")))
  expect_false(dir.exists(root))
  callbacks[[1L]]()
  expect_true(unbind_a())
  expect_identical(service$snapshot()$active_bindings, 1L)
  expect_true(service$emit("run_state", list(phase = "complete")))
  expect_true(unbind_b())
  expect_true(service$close())
  expect_false(service$close())
})

test_that("Claude diagnostics wrapper never adds a poll and hides content", {
  expect_identical(shinyAssistantUI:::.claude_diagnostics_batch_events(list()), list())
  secret <- "TOOL-DELTA-SECRET"
  stream <- structure(list(event = list(
    type = "content_block_delta",
    delta = list(type = "input_json_delta", partial_json = secret)
  )), class = "StreamEvent")
  events <- shinyAssistantUI:::.claude_diagnostics_batch_events(list(stream))
  summary <- Filter(function(x) identical(x$event, "tool_delta_summary"), events)
  expect_length(summary, 1L)
  expect_equal(summary[[1L]]$metrics$bytes, nchar(secret, type = "bytes"))
  expect_false(grepl(secret, paste(capture.output(str(events)), collapse = ""), fixed = TRUE))

  polls <- 0L
  messages <- list(structure(list(is_error = FALSE), class = "ResultMessage"))
  poller <- function() { polls <<- polls + 1L; messages }
  expect_identical(shinyAssistantUI:::.claude_poll_with_diagnostics(
    poller, function(...) stop("telemetry failure")
  ), messages)
  expect_identical(polls, 1L)
})
