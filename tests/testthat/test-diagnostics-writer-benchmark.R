test_that("Plan 123 HOME writer benchmark uses the fixed reproducible protocol", {
  skip_if_not_installed("jsonlite")
  expect_true(exists(".benchmark_diagnostics_writer", envir = asNamespace("shinyAssistantUI"),
                     inherits = FALSE))

  root <- tempfile("plan123-writer-benchmark-")
  dir.create(root, mode = "0700")
  on.exit(unlink(root, recursive = TRUE, force = TRUE), add = TRUE)

  result <- shinyAssistantUI:::.benchmark_isolated_diagnostics_writer(
    directory = root,
    warmup_enqueues = 1000L,
    warmup_flushes = 20L,
    measured_enqueues = 10000L,
    measured_flushes = 200L,
    rotation_batches = c(40L, 80L, 120L, 160L)
  )

  expect_identical(result$protocol, list(
    warmupEnqueues = 1000L,
    warmupFlushes = 20L,
    measuredEnqueues = 10000L,
    measuredFlushes = 200L,
    rowsPerFlush = 50L,
    rotationBatches = c(40L, 80L, 120L, 160L),
    seed = 123L,
    interBatchDelayMs = 5,
    quantile = "nearest-rank"
  ))
  expect_length(result$raw$enqueueMs, 10000L)
  expect_length(result$raw$flushMs, 200L)
  expect_true(all(is.finite(result$raw$enqueueMs)))
  expect_true(all(is.finite(result$raw$flushMs)))
  expect_identical(sum(unlist(result$eventCounts, use.names = FALSE)), 10000L)
  expect_identical(result$eventCounts, list(
    chunk_summary = 3500L,
    tool_delta_summary = 2000L,
    owned_markdown_preprocess_summary = 1500L,
    frame_summary = 1000L,
    memory_guard_sample = 1000L,
    storage_outcome = 500L,
    telemetry_batch_drop = 500L
  ))
  expect_identical(result$rotationBatchesObserved, c(40L, 80L, 120L, 160L))
  expect_gte(result$rotationCount, 4L)
  expect_identical(result$summary$enqueueP95Ms,
                   shinyAssistantUI:::.diagnostics_nearest_rank(result$raw$enqueueMs, 0.95))
  expect_identical(result$summary$flushP95Ms,
                   shinyAssistantUI:::.diagnostics_nearest_rank(result$raw$flushMs, 0.95))
  expect_identical(result$summary$flushP99Ms,
                   shinyAssistantUI:::.diagnostics_nearest_rank(result$raw$flushMs, 0.99))
  expect_identical(result$summary$flushMaxMs, max(result$raw$flushMs))
  expect_named(result$thresholds, c("enqueueP95", "flushP95", "flushP99", "flushMax"))
  expect_identical(result$valid, TRUE)
  expect_identical(result$passed, all(unlist(result$thresholds, use.names = FALSE)))

  files <- list.files(root, pattern = "^diag-v1-[0-9]{13}-[0-9a-f]{32}\\.jsonl$",
                      full.names = TRUE)
  expect_gte(length(files), 5L)
  expect_identical(sum(lengths(lapply(files, readLines, warn = FALSE))), 11000L)
})
