# Pure protocol and aggregation helpers for the Plan123 browser benchmark.
# This file deliberately has no Shiny, chromote, or process side effects.

PLAN123_MODES <- c("D", "O", "heap", "markdown")
PLAN123_TOTAL_UNITS <- 30L
PLAN123_MAX_SHARD_UNITS <- 5L
PLAN123_MIB <- 1024^2
PLAN123_PROTOCOL_VERSION <- 2L

plan123_stop <- function(..., call. = FALSE) stop(..., call. = call.)

plan123_scalar_integer <- function(value, name, minimum = 0L) {
  text <- as.character(value)
  if (length(text) != 1L || is.na(text) || !grepl("^[0-9]+$", text)) {
    plan123_stop(name, " must be a non-negative integer")
  }
  number <- suppressWarnings(as.numeric(text))
  if (!is.finite(number) || number > .Machine$integer.max || number != floor(number) || number < minimum) {
    plan123_stop(name, " must be an integer >= ", minimum)
  }
  as.integer(number)
}

plan123_mode_unit <- function(mode) {
  if (!mode %in% PLAN123_MODES) plan123_stop("mode must be one of D, O, heap, markdown")
  if (identical(mode, "heap")) "cycles" else "pairs"
}

plan123_parse_shard_args <- function(args) {
  if (length(args) != 5L) {
    plan123_stop("usage: <mode:D|O|heap|markdown> <start> <count> <seed> <artifact-path>")
  }
  mode <- as.character(args[[1L]])
  unit <- plan123_mode_unit(mode)
  start <- plan123_scalar_integer(args[[2L]], "start", 1L)
  count <- plan123_scalar_integer(args[[3L]], "count", 1L)
  seed <- plan123_scalar_integer(args[[4L]], "seed", 0L)
  artifact_path <- as.character(args[[5L]])
  if (length(artifact_path) != 1L || is.na(artifact_path) || !nzchar(artifact_path)) {
    plan123_stop("artifact path must be non-empty")
  }
  if (count > PLAN123_MAX_SHARD_UNITS) {
    plan123_stop("count must contain at most 5 ", unit)
  }
  if (start > PLAN123_TOTAL_UNITS || start + count - 1L > PLAN123_TOTAL_UNITS) {
    plan123_stop("requested range must stay within 1..30")
  }
  list(mode = mode, start = start, count = count, seed = seed,
       artifactPath = artifact_path, unit = unit)
}

plan123_with_seed <- function(seed, expression) {
  global <- .GlobalEnv
  had_seed <- exists(".Random.seed", envir = global, inherits = FALSE)
  if (had_seed) old_seed <- get(".Random.seed", envir = global, inherits = FALSE)
  on.exit({
    if (had_seed) {
      assign(".Random.seed", old_seed, envir = global)
    } else if (exists(".Random.seed", envir = global, inherits = FALSE)) {
      rm(".Random.seed", envir = global)
    }
  }, add = TRUE)
  set.seed(seed)
  force(expression)
}

plan123_mode_offset <- function(mode) {
  match(mode, PLAN123_MODES) * 100003L
}

plan123_balanced_orders <- function(seed, mode, total = PLAN123_TOTAL_UNITS) {
  seed <- plan123_scalar_integer(seed, "seed", 0L)
  plan123_mode_unit(mode)
  total <- plan123_scalar_integer(total, "total", 2L)
  if (total %% 2L != 0L) plan123_stop("total must be even for balanced order")
  derived_seed <- (as.double(seed) + plan123_mode_offset(mode)) %% .Machine$integer.max
  values <- rep(c("control-first", "candidate-first"), each = total / 2L)
  unname(plan123_with_seed(as.integer(derived_seed), sample(values, length(values), replace = FALSE)))
}

plan123_fixture_identity <- function(mode, index, seed) {
  plan123_mode_unit(mode)
  index <- plan123_scalar_integer(index, "index", 1L)
  if (index > PLAN123_TOTAL_UNITS) plan123_stop("index must stay within 1..30")
  seed <- plan123_scalar_integer(seed, "seed", 0L)
  mode_base <- c(D = 100000L, O = 200000L, heap = 300000L, markdown = 400000L)[[mode]]
  token <- sprintf("plan123-v%d|%s|%d|%d", PLAN123_PROTOCOL_VERSION, mode, seed, index)
  instance <- substr(digest::digest(token, algo = "sha256", serialize = FALSE), 1L, 32L)
  list(ordinal = as.integer(mode_base + index), instance = instance)
}

plan123_condition <- function(mode) {
  switch(mode,
    D = list(control = "diagnostics-off", candidate = "diagnostics-on"),
    O = list(control = "orb-hidden", candidate = "orb-shown"),
    heap = list(control = "diagnostics-off", candidate = "diagnostics-on"),
    markdown = list(control = "diagnostics-off", candidate = "diagnostics-on"),
    plan123_stop("mode must be one of D, O, heap, markdown")
  )
}

plan123_fingerprint <- function(seed, installed_js_sha256, fixture_sha256,
                                sidecar_sha256, harness_sha256,
                                package_version = "unknown") {
  seed <- plan123_scalar_integer(seed, "seed", 0L)
  hashes <- c(installed_js_sha256, fixture_sha256, sidecar_sha256, harness_sha256)
  if (any(!grepl("^[0-9a-f]{64}$", hashes))) {
    plan123_stop("fingerprint inputs must contain lowercase SHA-256 values")
  }
  payload <- list(
    protocolVersion = PLAN123_PROTOCOL_VERSION,
    seed = seed,
    packageVersion = as.character(package_version),
    installedJsSha256 = installed_js_sha256,
    fixtureSha256 = fixture_sha256,
    sidecarSha256 = sidecar_sha256,
    harnessSha256 = harness_sha256,
    totalUnits = PLAN123_TOTAL_UNITS,
    maxShardUnits = PLAN123_MAX_SHARD_UNITS,
    conditions = lapply(PLAN123_MODES, plan123_condition)
  )
  encoded <- jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null", digits = NA)
  digest::digest(encoded, algo = "sha256", serialize = FALSE)
}

plan123_new_shard <- function(fingerprint, mode, start, count, seed, samples,
                              errors, cleanup) {
  if (length(fingerprint) != 1L || !grepl("^[0-9a-f]{64}$", fingerprint)) {
    plan123_stop("fingerprint must be one lowercase SHA-256 value")
  }
  parsed <- plan123_parse_shard_args(c(mode, start, count, seed, "artifact.json"))
  if (!is.list(samples) || length(samples) != parsed$count) {
    plan123_stop("sample count must equal the shard count")
  }
  expected_indices <- seq.int(parsed$start, length.out = parsed$count)
  actual_indices <- vapply(samples, function(sample) {
    if (!is.list(sample) || is.null(sample$index)) plan123_stop("each sample must contain index")
    plan123_scalar_integer(sample$index, "sample index", 1L)
  }, integer(1))
  if (!identical(actual_indices, expected_indices)) {
    plan123_stop("sample indices must exactly match the requested shard range")
  }
  orders <- plan123_balanced_orders(parsed$seed, parsed$mode)
  expected_orders <- unname(orders[expected_indices])
  sample_orders <- vapply(samples, function(sample) as.character(sample$order), character(1))
  if (!identical(sample_orders, expected_orders)) {
    plan123_stop("sample order must match the deterministic global order")
  }
  if (!is.list(errors)) plan123_stop("errors must be a list")
  if (!is.list(cleanup)) plan123_stop("cleanup must be a list")
  list(
    schemaVersion = PLAN123_PROTOCOL_VERSION,
    kind = "plan123-performance-shard",
    fingerprint = fingerprint,
    mode = parsed$mode,
    start = parsed$start,
    count = parsed$count,
    seed = parsed$seed,
    condition = plan123_condition(parsed$mode),
    order = expected_orders,
    samples = samples,
    errors = errors,
    cleanup = cleanup
  )
}

plan123_nearest_rank <- function(values, probability) {
  original <- values
  numeric_values <- as.numeric(values)
  probability <- as.numeric(probability)
  if (!length(original) || length(probability) != 1L || !is.finite(probability) ||
      probability <= 0 || probability > 1 || any(!is.finite(numeric_values))) {
    plan123_stop("nearest-rank requires finite values and probability in (0, 1]")
  }
  sort(original)[[ceiling(probability * length(original))]]
}

plan123_least_squares_slope <- function(x, y) {
  x <- as.numeric(x); y <- as.numeric(y)
  if (length(x) != length(y) || length(x) < 2L || any(!is.finite(c(x, y)))) {
    plan123_stop("least-squares slope requires equal finite vectors of length >= 2")
  }
  centered <- x - mean(x)
  denominator <- sum(centered^2)
  if (!is.finite(denominator) || denominator <= 0) plan123_stop("slope x values must vary")
  sum(centered * (y - mean(y))) / denominator
}

plan123_number <- function(object, name) {
  value <- as.numeric(object[[name]])
  if (length(value) != 1L || !is.finite(value)) plan123_stop("sample field ", name, " must be finite")
  value
}

plan123_flag <- function(object, name) {
  value <- object[[name]]
  if (length(value) != 1L || is.na(value)) return(FALSE)
  isTRUE(value)
}

plan123_cleanup_ok <- function(cleanup) {
  is.list(cleanup) && isTRUE(cleanup$appExited) &&
    isTRUE(cleanup$browserContextDisposed) &&
    identical(as.integer(cleanup$activeChildren), 0L)
}

plan123_validate_shard <- function(shard) {
  required <- c("schemaVersion", "kind", "fingerprint", "mode", "start", "count", "seed",
                "condition", "order", "samples", "errors", "cleanup")
  if (!is.list(shard) || !all(required %in% names(shard))) plan123_stop("invalid shard schema")
  if (!identical(as.integer(shard$schemaVersion), PLAN123_PROTOCOL_VERSION) ||
      !identical(as.character(shard$kind), "plan123-performance-shard")) {
    plan123_stop("unsupported shard schema")
  }
  rebuilt <- plan123_new_shard(
    as.character(shard$fingerprint), as.character(shard$mode), shard$start, shard$count,
    shard$seed, shard$samples, shard$errors, shard$cleanup
  )
  if (!identical(rebuilt$condition, shard$condition)) plan123_stop("shard condition contract mismatch")
  invisible(TRUE)
}

plan123_collect_mode <- function(shards, mode) {
  selected <- Filter(function(shard) identical(as.character(shard$mode), mode), shards)
  indices <- unlist(lapply(selected, function(shard) {
    vapply(shard$samples, function(sample) as.integer(sample$index), integer(1))
  }), use.names = FALSE)
  if (anyDuplicated(indices)) plan123_stop("shard overlap detected for mode ", mode)
  samples <- unlist(lapply(selected, `[[`, "samples"), recursive = FALSE)
  if (length(samples)) samples <- samples[order(indices)]
  indices <- sort(indices)
  missing <- setdiff(seq_len(PLAN123_TOTAL_UNITS), indices)
  extra <- setdiff(indices, seq_len(PLAN123_TOTAL_UNITS))
  list(samples = samples, indices = indices, count = as.integer(length(indices)),
       missing = as.integer(missing), extra = as.integer(extra), complete = !length(missing) && !length(extra))
}

plan123_pair_statistics <- function(samples) {
  deltas <- function(field) vapply(samples, function(sample) {
    plan123_number(sample$candidate, field) - plan123_number(sample$control, field)
  }, numeric(1))
  frame_p95 <- deltas("frameP95Ms")
  frame_max <- deltas("frameMaxMs")
  jank <- deltas("jankCount")
  callback <- deltas("callbackToDomMs")
  integrity <- all(vapply(samples, function(sample) {
    isTRUE(sample$integrity) && plan123_flag(sample$control, "schedulerOk") &&
      plan123_flag(sample$candidate, "schedulerOk")
  }, logical(1)))
  list(
    frame = list(
      deltasMs = frame_p95,
      medianDeltaMs = plan123_nearest_rank(frame_p95, 0.5),
      p95DeltaMs = plan123_nearest_rank(frame_p95, 0.95),
      maxDeltaMs = max(frame_max),
      jankP95Delta = plan123_nearest_rank(jank, 0.95)
    ),
    callback = list(
      deltasMs = callback,
      p95DeltaMs = plan123_nearest_rank(callback, 0.95)
    ),
    integrity = integrity
  )
}

plan123_heap_statistics <- function(samples) {
  indices <- vapply(samples, function(sample) as.integer(sample$index), integer(1))
  side_statistics <- function(side) {
    baseline <- vapply(samples, function(sample) {
      plan123_number(sample[[side]], "baselineBytes")
    }, numeric(1))
    terminal <- vapply(samples, function(sample) {
      plan123_number(sample[[side]], "usedBytes")
    }, numeric(1))
    growth <- terminal - baseline
    settled <- all(vapply(samples, function(sample) {
      isTRUE(sample$integrity) && plan123_flag(sample[[side]], "settled")
    }, logical(1)))
    list(
      baselineBytes = baseline,
      terminalBytes = terminal,
      growthBytes = growth,
      p95GrowthBytes = plan123_nearest_rank(growth, 0.95),
      endGrowthBytes = growth[[length(growth)]],
      maxGrowthBytes = max(growth),
      slopeBytesPerCycle = plan123_least_squares_slope(indices, terminal),
      settled = settled
    )
  }
  control <- side_statistics("control")
  candidate <- side_statistics("candidate")
  treatment_delta <- candidate$growthBytes - control$growthBytes
  list(
    control = control,
    candidate = candidate,
    treatmentControl = list(
      growthDeltaBytes = treatment_delta,
      p95GrowthDeltaBytes = plan123_nearest_rank(treatment_delta, 0.95),
      endGrowthDeltaBytes = treatment_delta[[length(treatment_delta)]]
    )
  )
}

plan123_markdown_statistics <- function(samples) {
  raw <- function(side, field) vapply(samples, function(sample) {
    plan123_number(sample[[side]], field)
  }, numeric(1))
  control_pre <- raw("control", "preprocessMs")
  candidate_pre <- raw("candidate", "preprocessMs")
  control_dom <- raw("control", "domMilestoneMs")
  candidate_dom <- raw("candidate", "domMilestoneMs")
  control_p95 <- plan123_nearest_rank(control_pre, 0.95)
  candidate_p95 <- plan123_nearest_rank(candidate_pre, 0.95)
  semantic_quiet <- all(vapply(samples, function(sample) {
    sides <- list(sample$control, sample$candidate)
    isTRUE(sample$integrity) && all(vapply(sides, function(side) {
      plan123_flag(side, "semanticHashMatch") &&
        plan123_number(side, "quietFrames") >= 2 && plan123_number(side, "quietMs") >= 100
    }, logical(1)))
  }, logical(1)))
  list(
    preprocess = list(
      controlRawMs = control_pre,
      candidateRawMs = candidate_pre,
      controlP95Ms = control_p95,
      candidateP95Ms = candidate_p95,
      pairedP95DeltaMs = candidate_p95 - control_p95,
      toleranceMs = max(control_p95 * 0.05, 1)
    ),
    dom = list(
      controlRawMs = control_dom,
      candidateRawMs = candidate_dom,
      controlP95Ms = plan123_nearest_rank(control_dom, 0.95),
      candidateP95Ms = plan123_nearest_rank(candidate_dom, 0.95),
      pairedP95DeltaMs = plan123_nearest_rank(candidate_dom, 0.95) -
        plan123_nearest_rank(control_dom, 0.95)
    ),
    semanticQuiet = semantic_quiet
  )
}

plan123_aggregate_shards <- function(shards) {
  if (!is.list(shards) || !length(shards)) plan123_stop("at least one shard is required")
  invisible(lapply(shards, plan123_validate_shard))
  fingerprints <- unique(vapply(shards, function(shard) as.character(shard$fingerprint), character(1)))
  if (length(fingerprints) != 1L) plan123_stop("all shards must use one fingerprint")
  seeds <- unique(vapply(shards, function(shard) as.integer(shard$seed), integer(1)))
  if (length(seeds) != 1L) plan123_stop("all shards must use one seed")

  coverage_raw <- lapply(PLAN123_MODES, function(mode) plan123_collect_mode(shards, mode))
  names(coverage_raw) <- PLAN123_MODES
  coverage <- lapply(coverage_raw, function(item) item[c("count", "missing", "extra", "complete")])
  errors_zero <- all(vapply(shards, function(shard) length(shard$errors) == 0L, logical(1)))
  cleanup_complete <- all(vapply(shards, function(shard) plan123_cleanup_ok(shard$cleanup), logical(1)))
  complete <- all(vapply(coverage_raw, `[[`, logical(1), "complete"))
  ready <- complete && errors_zero && cleanup_complete
  result <- list(
    schemaVersion = PLAN123_PROTOCOL_VERSION,
    kind = "plan123-performance-aggregate",
    fingerprint = fingerprints[[1L]],
    seed = seeds[[1L]],
    coverage = coverage,
    integrity = list(errorsZero = errors_zero, cleanupComplete = cleanup_complete),
    ready = ready,
    statistics = NULL,
    verdict = NULL
  )
  if (!ready) return(result)

  statistics <- list(
    D = plan123_pair_statistics(coverage_raw$D$samples),
    O = plan123_pair_statistics(coverage_raw$O$samples),
    heap = plan123_heap_statistics(coverage_raw$heap$samples),
    markdown = plan123_markdown_statistics(coverage_raw$markdown$samples)
  )
  pair_verdict <- function(stats) {
    isTRUE(stats$integrity) && stats$frame$p95DeltaMs <= 2 &&
      stats$frame$maxDeltaMs <= 8 && stats$frame$jankP95Delta <= 1 &&
      stats$callback$p95DeltaMs <= 5
  }
  verdict <- list(
    D = pair_verdict(statistics$D),
    O = pair_verdict(statistics$O),
    heap = isTRUE(statistics$heap$control$settled) &&
      isTRUE(statistics$heap$candidate$settled) &&
      statistics$heap$control$endGrowthBytes <= 8 * PLAN123_MIB &&
      statistics$heap$candidate$endGrowthBytes <= 8 * PLAN123_MIB &&
      statistics$heap$control$slopeBytesPerCycle <= 0.25 * PLAN123_MIB &&
      statistics$heap$candidate$slopeBytesPerCycle <= 0.25 * PLAN123_MIB &&
      statistics$heap$treatmentControl$endGrowthDeltaBytes <= 4 * PLAN123_MIB,
    markdown = isTRUE(statistics$markdown$semanticQuiet) &&
      statistics$markdown$preprocess$pairedP95DeltaMs <= statistics$markdown$preprocess$toleranceMs &&
      statistics$markdown$dom$pairedP95DeltaMs <= 5
  )
  verdict$overall <- all(unlist(verdict, use.names = FALSE))
  result$statistics <- statistics
  result$verdict <- verdict
  result
}
