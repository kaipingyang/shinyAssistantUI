local({
  source <- normalizePath(Sys.getenv("AUI_CODEAGENT_SOURCE", "../codeagent"), mustWork = TRUE)
  files <- c("test-codeagent-stream.R", "test-backend-contract.R",
             "test-web-citations.R", "test-stream-lifecycle.R")
  stopifnot(all(file.exists(file.path(source, "tests/testthat", files))))
  home <- tempfile("codeagent-source-tests-")
  dir.create(home, mode = "0700")
  on.exit(unlink(home, recursive = TRUE), add = TRUE)
  withr::local_envvar(c(
    HOME = home, CODEAGENT_HOME = file.path(home, "settings"),
    CODEAGENT_MODEL = "gpt-4.1", CODEAGENT_BASE_URL = "http://127.0.0.1",
    CODEAGENT_API_KEY = "local-fixture"
  ))
  cat("CODEAGENT_SOURCE ", source, "\n", sep = "")
  print(tools::md5sum(file.path(source, c("R/stream.R", "R/async_agent.R"))))
  withr::with_dir(source, {
    devtools::load_all(".", quiet = TRUE)
    failures <- passed <- skipped <- 0L
    for (file in files) {
      cat("\n[UPSTREAM TEST] ", file, "\n", sep = "")
      result <- as.data.frame(testthat::test_file(
        file.path("tests/testthat", file), reporter = "summary"
      ))
      failures <- failures + sum(result$failed) + sum(result$error)
      passed <- passed + sum(result$passed)
      skipped <- skipped + sum(result$skipped)
    }
    cat(sprintf("CODEAGENT_RESULT files=%d passed=%d failed=%d skipped=%d\n",
                length(files), passed, failures, skipped))
    if (failures > 0L) stop("Codeagent source regressions failed", call. = FALSE)
  })
})
