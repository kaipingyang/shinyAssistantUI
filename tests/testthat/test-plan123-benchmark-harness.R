plan123_harness_env <- function() {
  env <- new.env(parent = baseenv())
  sys.source(
    testthat::test_path("..", "verify", "plan123_benchmark_pure.R"),
    envir = env,
    keep.source = FALSE
  )
  env
}

plan123_synthetic_sample <- function(mode, index, order = "control-first") {
  common <- list(
    index = as.integer(index),
    ordinal = as.integer(index),
    instance = sprintf("%032x", as.integer(index)),
    order = order
  )
  if (mode %in% c("D", "O")) {
    return(c(common, list(
      control = list(frameP95Ms = index, frameMaxMs = index + 1, jankCount = 0L,
                     callbackToDomMs = index + 2, schedulerOk = TRUE),
      candidate = list(frameP95Ms = index + 1, frameMaxMs = index + 2, jankCount = 0L,
                       callbackToDomMs = index + 3, schedulerOk = TRUE),
      integrity = TRUE
    )))
  }
  if (identical(mode, "heap")) {
    return(c(common, list(
      control = list(baselineBytes = 10 * 1024^2,
                     usedBytes = (10 + index / 200) * 1024^2, settled = TRUE),
      candidate = list(baselineBytes = 10 * 1024^2,
                       usedBytes = (10 + index / 100) * 1024^2, settled = TRUE),
      integrity = TRUE
    )))
  }
  c(common, list(
    control = list(preprocessMs = index, domMilestoneMs = index + 1,
                   semanticHashMatch = TRUE, quietFrames = 2L, quietMs = 100),
    candidate = list(preprocessMs = index + 0.5, domMilestoneMs = index + 2,
                     semanticHashMatch = TRUE, quietFrames = 2L, quietMs = 100),
    integrity = TRUE
  ))
}

plan123_complete_shards <- function(env, fingerprint = paste(rep("a", 64), collapse = ""), seed = 1231501L) {
  shards <- list()
  for (mode in c("D", "O", "heap", "markdown")) {
    orders <- env$plan123_balanced_orders(seed, mode)
    for (start in seq.int(1L, 30L, by = 5L)) {
      indices <- start:(start + 4L)
      samples <- lapply(indices, function(index) {
        plan123_synthetic_sample(mode, index, orders[[index]])
      })
      shards[[length(shards) + 1L]] <- env$plan123_new_shard(
        fingerprint = fingerprint,
        mode = mode,
        start = start,
        count = 5L,
        seed = seed,
        samples = samples,
        errors = list(),
        cleanup = list(appExited = TRUE, browserContextDisposed = TRUE, activeChildren = 0L)
      )
    }
  }
  shards
}

test_that("Plan123 shard CLI accepts only bounded non-overflowing units", {
  env <- plan123_harness_env()
  parsed <- env$plan123_parse_shard_args(c("D", "6", "5", "1231501", "raw/shard.json"))
  expect_identical(parsed$mode, "D")
  expect_identical(parsed$start, 6L)
  expect_identical(parsed$count, 5L)
  expect_identical(parsed$seed, 1231501L)
  expect_identical(parsed$artifactPath, "raw/shard.json")
  expect_identical(parsed$unit, "pairs")

  parsed_heap <- env$plan123_parse_shard_args(c("heap", "26", "5", "9", "heap.json"))
  expect_identical(parsed_heap$unit, "cycles")
  expect_error(env$plan123_parse_shard_args(c("bad", "1", "1", "1", "x.json")), "mode")
  expect_error(env$plan123_parse_shard_args(c("D", "1", "6", "1", "x.json")), "at most 5")
  expect_error(env$plan123_parse_shard_args(c("O", "29", "3", "1", "x.json")), "30")
  expect_error(env$plan123_parse_shard_args(c("markdown", "0", "1", "1", "x.json")), "start")
  expect_error(env$plan123_parse_shard_args(c("heap", "1", "1", "x", "x.json")), "seed")
})

test_that("Plan123 balanced orders and fixture identities are deterministic and shard invariant", {
  env <- plan123_harness_env()
  for (mode in c("D", "O", "heap", "markdown")) {
    orders <- env$plan123_balanced_orders(1231501L, mode)
    expect_length(orders, 30L)
    expect_identical(sum(orders == "control-first"), 15L)
    expect_identical(sum(orders == "candidate-first"), 15L)
    expect_identical(orders, env$plan123_balanced_orders(1231501L, mode))
    ids <- lapply(1:30, function(index) env$plan123_fixture_identity(mode, index, 1231501L))
    expect_identical(vapply(ids, `[[`, integer(1), "ordinal"),
                     vapply(ids, `[[`, integer(1), "ordinal"))
    expect_true(all(grepl("^[0-9a-f]{32}$", vapply(ids, `[[`, character(1), "instance"))))
    expect_length(unique(vapply(ids, `[[`, character(1), "instance")), 30L)
  }
})

test_that("Plan123 raw shard schema carries required provenance and cleanup", {
  env <- plan123_harness_env()
  fingerprint <- paste(rep("b", 64), collapse = "")
  orders <- env$plan123_balanced_orders(7L, "D")
  shard <- env$plan123_new_shard(
    fingerprint, "D", 1L, 2L, 7L,
    samples = lapply(1:2, function(index) plan123_synthetic_sample("D", index, orders[[index]])),
    errors = list(),
    cleanup = list(appExited = TRUE, browserContextDisposed = TRUE, activeChildren = 0L)
  )
  expect_named(shard, c(
    "schemaVersion", "kind", "fingerprint", "mode", "start", "count", "seed",
    "condition", "order", "samples", "errors", "cleanup"
  ), ignore.order = FALSE)
  expect_identical(shard$order, unname(orders[1:2]))
  expect_identical(shard$condition, list(control = "diagnostics-off", candidate = "diagnostics-on"))
  expect_error(env$plan123_new_shard(fingerprint, "D", 1L, 2L, 7L,
                                     samples = list(plan123_synthetic_sample("D", 1L)),
                                     errors = list(), cleanup = list()), "sample")
})

test_that("Plan123 aggregation withholds verdict until every exact 30-unit mode is present", {
  env <- plan123_harness_env()
  shards <- plan123_complete_shards(env)
  incomplete <- env$plan123_aggregate_shards(shards[-length(shards)])
  expect_false(incomplete$ready)
  expect_null(incomplete$verdict)
  expect_identical(incomplete$coverage$markdown$missing, 26:30)

  complete <- env$plan123_aggregate_shards(shards)
  expect_true(complete$ready)
  expect_true(is.list(complete$verdict))
  expect_identical(complete$coverage$D$count, 30L)
  expect_identical(complete$coverage$O$count, 30L)
  expect_identical(complete$coverage$heap$count, 30L)
  expect_identical(complete$coverage$markdown$count, 30L)
  expect_identical(env$plan123_nearest_rank(1:30, 0.95), 29L)
  expect_identical(complete$statistics$D$frame$p95DeltaMs, 1)
  expect_equal(complete$statistics$heap$control$p95GrowthBytes, 29 / 200 * 1024^2)
  expect_equal(complete$statistics$heap$candidate$p95GrowthBytes, 29 / 100 * 1024^2)
  expect_true(complete$statistics$heap$control$settled)
  expect_true(complete$statistics$heap$candidate$settled)
  expect_identical(complete$statistics$markdown$preprocess$controlP95Ms, 29)
  expect_true(complete$verdict$overall)
})

test_that("Plan123 aggregation rejects overlaps, mixed fingerprints, errors, and failed cleanup", {
  env <- plan123_harness_env()
  shards <- plan123_complete_shards(env)
  expect_error(env$plan123_aggregate_shards(c(shards, shards[1L])), "overlap")

  mixed <- shards
  mixed[[2L]]$fingerprint <- paste(rep("c", 64), collapse = "")
  expect_error(env$plan123_aggregate_shards(mixed), "fingerprint")

  errored <- shards
  errored[[1L]]$errors <- list(list(type = "runtime", message = "fixture failure"))
  result <- env$plan123_aggregate_shards(errored)
  expect_false(result$ready)
  expect_null(result$verdict)
  expect_false(result$integrity$errorsZero)

  dirty <- shards
  dirty[[1L]]$cleanup$activeChildren <- 1L
  result <- env$plan123_aggregate_shards(dirty)
  expect_false(result$ready)
  expect_false(result$integrity$cleanupComplete)
})


test_that("Plan123 shard and pure aggregate entrypoints expose the bounded browser contracts", {
  root <- testthat::test_path("..", "..")
  verify <- file.path(root, "tests", "verify")
  files <- file.path(verify, c(
    "plan123_benchmark_pure.R",
    "run_plan123_performance_shard.R",
    "aggregate_plan123_performance_shards.R"
  ))
  expect_true(all(file.exists(files)))
  invisible(lapply(files, parse))

  shard_text <- paste(readLines(files[[2L]], warn = FALSE), collapse = "\n")
  for (contract in c(
    "plan123_parse_shard_args", "PLAN123_HOME_LIBRARY",
    "plan123_performance_app.R", "createBrowserContext",
    "HOME = home", "addScriptToEvaluateOnNewDocument",
    "frameProbe(12)", "schedulerOk", "plan123_fixture_identity",
    "semantic DOM hash + MutationObserver quiet", "activeChildren",
    "plan123_new_shard"
  )) expect_match(shard_text, contract, fixed = TRUE)
  expect_false(grepl("npm run build|R CMD INSTALL|pkill -f", shard_text, fixed = FALSE))

  aggregate_text <- paste(readLines(files[[3L]], warn = FALSE), collapse = "\n")
  expect_match(aggregate_text, "plan123_aggregate_shards", fixed = TRUE)
  expect_match(aggregate_text, "PLAN123_AGGREGATE_VERDICT=withheld", fixed = TRUE)
  expect_false(grepl("chromote|Chromote|library\\(shiny", aggregate_text))
})

test_that("Plan123 pure aggregate JSON roundtrip withholds incomplete verdict", {
  skip_if_not_installed("jsonlite")
  env <- plan123_harness_env()
  aggregate_env <- new.env(parent = baseenv())
  sys.source(
    testthat::test_path("..", "verify", "aggregate_plan123_performance_shards.R"),
    envir = aggregate_env,
    keep.source = FALSE
  )
  shard <- env$plan123_new_shard(
    fingerprint = paste(rep("d", 64), collapse = ""), mode = "D",
    start = 1L, count = 1L, seed = 1231501L,
    samples = list(plan123_synthetic_sample(
      "D", 1L, env$plan123_balanced_orders(1231501L, "D")[[1L]]
    )),
    errors = list(),
    cleanup = list(appExited = TRUE, browserContextDisposed = TRUE, activeChildren = 0L)
  )
  directory <- tempfile("plan123-aggregate-")
  dir.create(directory)
  on.exit(unlink(directory, recursive = TRUE, force = TRUE), add = TRUE)
  shard_path <- file.path(directory, "D-01.json")
  output_path <- file.path(directory, "aggregate.json")
  jsonlite::write_json(shard, shard_path, auto_unbox = TRUE, pretty = TRUE,
                       null = "null", digits = NA)
  result <- aggregate_env$run_plan123_aggregate(c(output_path, shard_path))
  expect_false(result$ready)
  expect_null(result$verdict)
  written <- jsonlite::fromJSON(output_path, simplifyVector = FALSE)
  expect_false(written$ready)
  expect_null(written$verdict)
  expect_identical(written$coverage$D$count, 1L)
  expect_identical(written$coverage$O$count, 0L)
})
