test_that("production handler profile executes the real handler path", {
  skip_if_not_installed("ClaudeAgentSDK")
  skip_if_not_installed("coro")
  skip_if_not_installed("later")
  skip_if_not_installed("processx")

  script <- normalizePath(
    testthat::test_path("..", "verify", "profile_plan119_layers.R"),
    winslash = "/", mustWork = TRUE
  )
  out_dir <- tempfile("production-handler-profile-contract-")
  dir.create(out_dir, recursive = TRUE)
  on.exit(unlink(out_dir, recursive = TRUE, force = TRUE), add = TRUE)

  run <- processx::run(
    file.path(R.home("bin"), "Rscript"), script,
    env = c(
      AUI_PROFILE_LAYER = "production-handler",
      AUI_PROFILE_PASS = "pss",
      AUI_PROFILE_ARM = "true",
      AUI_PROFILE_TOOLS = "2",
      AUI_PROFILE_PAYLOAD_BYTES = "128",
      AUI_PROFILE_DEADLINE_S = "30",
      AUI_PROFILE_CGROUP_HEADROOM_BYTES = "0",
      AUI_PROFILE_OUT_DIR = out_dir
    ),
    timeout = 45000,
    error_on_status = FALSE,
    echo = FALSE
  )

  expect_identical(run$status, 0L, info = paste(c(run$stdout, run$stderr), collapse = "\n"))
  summary_path <- file.path(out_dir, "summary.json")
  expect_true(file.exists(summary_path))
  summary <- jsonlite::fromJSON(summary_path, simplifyVector = FALSE)
  key <- "production-handler|pss|tools=2|payload=128"
  expect_true(key %in% names(summary$runs))
  arm <- summary$runs[[key]]$arms[[1L]]

  expect_true(isTRUE(arm$ok))
  expect_identical(arm$handler_scope, "production make_claude_handler end-to-end")
  expect_identical(arm$identity$handler_factory_calls, 1L)
  expect_identical(arm$identity$fake_client_creations, 1L)
  expect_identical(arm$identity$client_connects, 1L)
  expect_identical(arm$identity$client_sends, 1L)
  expect_identical(arm$identity$client_disconnects, 1L)
  expect_gt(arm$coordinator$messages_seen, 0L)
  expect_identical(arm$terminal$done, 1L)
  expect_identical(arm$terminal$errors, 0L)
  expect_true(isTRUE(arm$terminal$promise_settled))
  expect_true(isTRUE(arm$cleanup$quiescent))
  expect_true(isTRUE(arm$cleanup$no_late_callbacks))
  expect_true(isTRUE(arm$process$cleanup_confirmed))
})
