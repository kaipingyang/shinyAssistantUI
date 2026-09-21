local({
  subject <- file.path("tests", "verify", "compare_sdk_memory.R")
  stopifnot(file.exists(subject))
  scope <- new.env(parent = globalenv())
  sys.source(subject, envir = scope)
  stopifnot(is.function(scope$run_sdk_memory_comparison))
  result <- scope$run_sdk_memory_comparison(
    arms = c("sdk", "handler"),
    events = 32L,
    output = tempfile("sdk-memory-contract-"),
    timeout = 30
  )
  stopifnot(
    nrow(result) == 2L,
    all(result$done == 1L),
    all(result$chunks == 32L),
    all(result$semantic_ok),
    all(result$cleanup_confirmed),
    all(result$pss_post_gc_bytes > 0)
  )
})
