local({
  scope <- new.env(parent = globalenv())
  sys.source("tests/verify/compare_sdk_memory.R", envir = scope)
  output <- Sys.getenv("AUI_HANDLER_PERFORMANCE_OUT", tempfile("handler-performance-"))
  stopifnot(!identical(Sys.getenv("R_ENABLE_JIT"), "0"))
  small <- scope$run_sdk_memory_comparison(
    arms = c("plugin", "plugin-diagnostics"), events = 1200L,
    output = file.path(output, "1200"), deep_stack = TRUE
  )
  large <- scope$run_sdk_memory_comparison(
    arms = "plugin", events = 2400L,
    output = file.path(output, "2400"), deep_stack = TRUE
  )
  main <- small[small$arm == "plugin", , drop = FALSE]
  diagnostic <- small[small$arm == "plugin-diagnostics", , drop = FALSE]
  stopifnot(
    main$pss_post_gc_bytes < 350 * 1024^2,
    large$pss_post_gc_bytes < 450 * 1024^2,
    large$pss_post_gc_bytes - main$pss_post_gc_bytes < 200 * 1024^2,
    main$first_chunk_seconds < 1.5,
    large$first_chunk_seconds < 1.5,
    main$duration_seconds < 8,
    large$duration_seconds < 12,
    diagnostic$pss_post_gc_bytes < 400 * 1024^2,
    diagnostic$first_chunk_seconds < 2,
    diagnostic$duration_seconds < 10,
    all(small$done == 1L), large$done == 1L,
    all(small$semantic_ok), large$semantic_ok,
    all(small$console_errors == 0L), large$console_errors == 0L,
    all(small$network_errors == 0L), large$network_errors == 0L,
    all(small$cleanup_confirmed), large$cleanup_confirmed
  )
  cat("HANDLER_PERFORMANCE_GATES_PASSED\n")
})
