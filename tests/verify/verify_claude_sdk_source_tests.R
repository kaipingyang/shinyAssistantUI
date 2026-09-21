local({
  source <- normalizePath("../ClaudeAgentSDK", mustWork = TRUE)
  files <- strsplit(Sys.getenv(
    "AUI_SDK_TEST_FILES",
    "test-client-lifecycle.R,test-client-unit.R,test-control-dispatcher.R,test-stream-line-decoder.R"
  ), ",", fixed = TRUE)[[1L]]
  stopifnot(length(files) <= 4L,
            all(grepl("^test-[A-Za-z0-9-]+\\.R$", files)),
            all(file.exists(file.path(source, "tests/testthat", files))))
  home <- tempfile("sdk-source-tests-")
  dir.create(home, mode = "0700")
  on.exit(unlink(home, recursive = TRUE), add = TRUE)
  withr::local_envvar(c(HOME = home, CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK = "1"))
  cat("SDK_SOURCE ", source, "\n", sep = "")
  print(tools::md5sum(file.path(source, c("R/client.R", "R/transport.R"))))
  withr::with_dir(source, {
    devtools::load_all(".", quiet = TRUE)
    failed <- passed <- skipped <- 0L
    for (file in files) {
      cat("\n[SDK TEST] ", file, "\n", sep = "")
      result <- as.data.frame(testthat::test_file(
        file.path("tests/testthat", file), reporter = "summary"
      ))
      failed <- failed + sum(result$failed) + sum(result$error)
      passed <- passed + sum(result$passed)
      skipped <- skipped + sum(result$skipped)
    }
    cat(sprintf("SDK_RESULT files=%d passed=%d failed=%d skipped=%d\n",
                length(files), passed, failed, skipped))
    if (failed > 0L) stop("SDK source regressions failed", call. = FALSE)
  })
})
