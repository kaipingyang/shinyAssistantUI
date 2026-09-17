#!/usr/bin/env Rscript

source_files <- Filter(Negate(is.null), lapply(sys.frames(), function(frame) frame$ofile))
source_file <- if (length(source_files)) tail(source_files, 1L)[[1L]] else NULL
script_argument <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
script_path <- if (!is.null(source_file) && nzchar(source_file)) {
  source_file
} else if (length(script_argument)) {
  sub("^--file=", "", script_argument[[1L]])
} else {
  "tests/verify/aggregate_plan123_performance_shards.R"
}
candidate_dirs <- unique(c(
  dirname(script_path),
  file.path(getwd(), "tests", "verify"),
  file.path(getwd(), "..", "verify"),
  file.path(getwd(), "..", "..", "tests", "verify")
))
valid_dirs <- candidate_dirs[file.exists(file.path(candidate_dirs, "plan123_benchmark_pure.R"))]
if (!length(valid_dirs)) stop("cannot locate tests/verify/plan123_benchmark_pure.R", call. = FALSE)
script_dir <- normalizePath(valid_dirs[[1L]], winslash = "/")
source(file.path(script_dir, "plan123_benchmark_pure.R"), local = TRUE)

plan123_find_shards <- function(inputs) {
  paths <- unlist(lapply(inputs, function(input) {
    if (dir.exists(input)) {
      list.files(input, pattern = "\\.json$", full.names = TRUE, recursive = TRUE)
    } else {
      input
    }
  }), use.names = FALSE)
  paths <- unique(paths[file.exists(paths)])
  if (!length(paths)) plan123_stop("no shard JSON files found")
  paths
}

plan123_read_shards <- function(paths) {
  lapply(paths, function(path) {
    value <- jsonlite::fromJSON(path, simplifyVector = FALSE)
    if (!identical(value$kind, "plan123-performance-shard")) {
      plan123_stop("not a Plan123 raw shard: ", basename(path))
    }
    value
  })
}

plan123_write_json_atomic <- function(value, path) {
  parent <- dirname(path)
  if (!dir.exists(parent)) dir.create(parent, recursive = TRUE, mode = "0700")
  temporary <- tempfile(paste0(basename(path), "."), tmpdir = parent)
  on.exit(unlink(temporary, force = TRUE), add = TRUE)
  jsonlite::write_json(value, temporary, auto_unbox = TRUE, pretty = TRUE,
                       null = "null", digits = NA)
  if (!file.rename(temporary, path)) plan123_stop("could not publish aggregate artifact")
  invisible(normalizePath(path, winslash = "/"))
}

run_plan123_aggregate <- function(args = commandArgs(trailingOnly = TRUE)) {
  if (length(args) < 2L) {
    plan123_stop("usage: <aggregate-artifact.json> <shard.json-or-directory> [...]")
  }
  output <- args[[1L]]
  paths <- setdiff(plan123_find_shards(args[-1L]), output)
  shards <- plan123_read_shards(paths)
  aggregate <- plan123_aggregate_shards(shards)
  aggregate$sourceShardCount <- as.integer(length(shards))
  plan123_write_json_atomic(aggregate, output)
  cat("PLAN123_AGGREGATE_ARTIFACT=", normalizePath(output, winslash = "/"), "\n", sep = "")
  for (mode in PLAN123_MODES) {
    item <- aggregate$coverage[[mode]]
    cat(sprintf("PLAN123_COVERAGE mode=%s count=%d missing=%d complete=%s\n",
                mode, item$count, length(item$missing), tolower(as.character(item$complete))))
  }
  cat("PLAN123_AGGREGATE_READY=", tolower(as.character(aggregate$ready)), "\n", sep = "")
  if (isTRUE(aggregate$ready)) {
    cat("PLAN123_AGGREGATE_VERDICT=", tolower(as.character(aggregate$verdict$overall)), "\n", sep = "")
  } else {
    cat("PLAN123_AGGREGATE_VERDICT=withheld\n")
  }
  invisible(aggregate)
}

if (sys.nframe() == 0L) run_plan123_aggregate()
