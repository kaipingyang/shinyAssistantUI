test_that("Plan 123 installed-browser gate assets are fixture-only and complete", {
  root <- testthat::test_path("..", "..")
  sidecar <- file.path(root, "tests", "verify", "plan123_performance_sidecar.js")
  app <- file.path(root, "tests", "verify", "plan123_performance_app.R")
  driver <- file.path(root, "tests", "verify", "verify_plan123_performance_gate.R")

  expect_true(file.exists(sidecar))
  expect_true(file.exists(app))
  expect_true(file.exists(driver))
  expect_false(file.exists(file.path(root, "inst", "www", basename(sidecar))))

  sidecar_text <- paste(readLines(sidecar, warn = FALSE), collapse = "\n")
  expect_match(sidecar_text, "fixtureOrdinal", fixed = TRUE)
  expect_match(sidecar_text, "fixtureInstance", fixed = TRUE)
  expect_match(sidecar_text, "MutationObserver", fixed = TRUE)
  expect_match(sidecar_text, "quietFrames >= 2", fixed = TRUE)
  expect_match(sidecar_text, "quietMs >= 100", fixed = TRUE)
  expect_match(sidecar_text, "crypto.subtle.digest", fixed = TRUE)
  expect_match(sidecar_text, "nativeRequestAnimationFrame", fixed = TRUE)
  expect_match(sidecar_text, "productSchedulers", fixed = TRUE)

  driver_text <- paste(readLines(driver, warn = FALSE), collapse = "\n")
  for (contract in c(
    "MEASURED_PAIRS <- 30L", "WARMUP_PAIRS <- 2L", "FIXED_SEED <-",
    "HeapProfiler$collectGarbage", "Runtime$getHeapUsage", "nearest_rank",
    "8 * MIB", "0.25", "4 * MIB", "activeChildren=0",
    "console", "runtime", "network", "target_crash"
  )) expect_match(driver_text, contract, fixed = TRUE)

  app_text <- paste(readLines(app, warn = FALSE), collapse = "\n")
  expect_match(app_text, "set.seed", fixed = TRUE)
  expect_match(app_text, "on_tool_call", fixed = TRUE)
  expect_match(app_text, "diagnostics =", fixed = TRUE)
  expect_false(grepl("Claude|ellmer|copilot-api|https?://", app_text))
})

test_that("Plan 123 percentile and heap budget helpers follow the exact formulas", {
  env <- new.env(parent = baseenv())
  sys.source(
    testthat::test_path("..", "verify", "verify_plan123_performance_gate.R"),
    envir = env,
    keep.source = FALSE
  )
  expect_identical(env$nearest_rank(1:30, 0.95), 29L)
  expect_identical(env$nearest_rank(c(30:1), 0.95), 29L)
  expect_equal(env$least_squares_slope(1:30, 2 * (1:30) + 5), 2)
  expect_true(env$heap_budget_verdict(0, 8 * env$MIB, 0.25 * env$MIB)$ok)
  expect_false(env$heap_budget_verdict(0, 8 * env$MIB + 1, 0)$ok)
  expect_false(env$heap_budget_verdict(0, 1, 0.25 * env$MIB + 1)$ok)
})
