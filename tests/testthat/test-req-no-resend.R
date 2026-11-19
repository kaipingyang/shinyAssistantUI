# nanonext REQ sockets resend an unanswered request every 60 s by default. Our
# requests wait for a person (forms, output review) or for long R code, so a resend
# showed duplicate forms and re-ran run_r code. Every REQ dial must disable it, and
# the services must treat a repeated request_id as the same request.

mcp_script <- function(name) {
  script <- system.file("mcp", name, package = "shinyAssistantUI")
  if (!nzchar(script)) script <- file.path("../../inst/mcp", name)
  skip_if_not(file.exists(script))
  script
}

expect_no_resend <- function(sock) {
  on.exit(try(close(sock), silent = TRUE), add = TRUE)
  expect_s3_class(sock, "nanoSocket")
  expect_identical(as.integer(nanonext::opt(sock, "req:resend-time")), 0L)
}

test_that("package and MCP REQ sockets disable automatic resend", {
  skip_if_not_installed("nanonext")
  url <- paste0("ipc://", tempfile("no-resend-", fileext = ".sock"))
  rep <- nanonext::socket("rep", listen = url)
  on.exit(close(rep), add = TRUE)
  expect_no_resend(shinyAssistantUI:::.addin_req_socket(url))

  skip_if_not(requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
              "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK"))
  withr::local_envvar(SHINY_ASSISTANT_UI_MCP_NO_SERVE = "1",
                      SHINY_ASSISTANT_UI_RUN_R_NO_SERVE = "1")
  for (name in c("ask_form_server.R", "run_r_server.R")) {
    env <- new.env(parent = globalenv())
    sys.source(mcp_script(name), envir = env)
    expect_true(is.function(env$.req_socket), info = name)
    expect_no_resend(env$.req_socket(url))
  }
})

test_that("an unanswered request is delivered once, not every 60 s", {
  skip_on_cran()
  skip_if_not_installed("nanonext")
  skip_if(!identical(Sys.getenv("AUI_SLOW_TESTS"), "1"), "set AUI_SLOW_TESTS=1 (waits 65 s)")
  url <- paste0("ipc://", tempfile("no-resend-live-", fileext = ".sock"))
  rep <- nanonext::socket("rep", listen = url)
  on.exit(close(rep), add = TRUE)
  req <- shinyAssistantUI:::.addin_req_socket(url)
  on.exit(close(req), add = TRUE)
  aio <- nanonext::request(nanonext::context(req), data = 1, timeout = 90000)
  receipts <- 0L
  deadline <- Sys.time() + 65
  while (Sys.time() < deadline) {
    got <- nanonext::recv_aio(nanonext::context(rep), mode = "serial", timeout = 500)
    nanonext::call_aio(got)
    if (!nanonext::is_error_value(got$data)) receipts <- receipts + 1L
  }
  expect_identical(receipts, 1L)
})

test_that("a repeated AskUserForm request_id reuses the open form", {
  emitted <- list()
  emitters <- shinyAssistantUI:::.new_ask_form_emitters()
  emitters$register("t1", "run-1", function(operations, ...) {
    emitted[[length(emitted) + 1L]] <<- operations
  }, owner = "owner")
  ids <- 0L
  service <- shinyAssistantUI:::.new_ask_form_service(
    emitters, schedule = function(callback, delay) function() NULL,
    id_factory = function() { ids <<- ids + 1L; paste0("f", ids) })
  req <- list(type = "ask_user_form", version = 1L, request_id = "same", thread_id = "t1",
              title = "T", fields = list(list(name = "who", type = "text")), submit_label = "Go")
  first <- list(); second <- list()
  service$request(req, function(r) first[[length(first) + 1L]] <<- r)
  service$request(req, function(r) second[[length(second) + 1L]] <<- r)
  creates <- Filter(function(ops) any(vapply(ops, function(op) !is.null(op$createSurface), TRUE)), emitted)
  expect_length(creates, 1L)
  service$handle_action("ask_form.submit", list(formId = "ask-form-f1", values = list(who = "Ada")), "t1", "ask-form-f1",
                        on_error = function(...) NULL, owner = "owner")
  expect_length(first, 0L)
  expect_length(second, 1L)
  expect_identical(second[[1]]$status, "submitted")
  expect_identical(second[[1]]$request_id, "same")
})

test_that("a repeated run_r review request_id reuses the pending review", {
  service <- shinyAssistantUI:::.new_run_r_review_service(
    enabled = function() TRUE, schedule = function(callback, delay) function() NULL,
    id_factory = local({ n <- 0L; function() { n <<- n + 1L; paste0("review-", n) } }))
  shown <- 0L
  service$add_sink("sink", show = function(review) shown <<- shown + 1L, dismiss = function(...) NULL)
  req <- list(type = "run_r_output_review", version = 1L, request_id = "same", thread_id = "t1",
              code = "1", text = "[1] 1", is_error = FALSE)
  first <- list(); second <- list()
  service$request(req, function(r) first[[length(first) + 1L]] <<- r)
  service$request(req, function(r) second[[length(second) + 1L]] <<- r)
  expect_identical(shown, 1L)
  expect_length(service$pending(), 1L)
  service$decide("review-1", "approve")
  expect_length(first, 0L)
  expect_length(second, 1L)
  expect_identical(second[[1]]$decision, "approve")
  expect_identical(second[[1]]$request_id, "same")
})

test_that("a run_r console timeout warns that the code may still be running", {
  skip_if_not(requireNamespace("ClaudeAgentSDK", quietly = TRUE) &&
              "mcp_serve_stdio" %in% getNamespaceExports("ClaudeAgentSDK"))
  skip_if_not_installed("nanonext")
  withr::local_envvar(SHINY_ASSISTANT_UI_RUN_R_NO_SERVE = "1")
  env <- new.env(parent = globalenv())
  sys.source(mcp_script("run_r_server.R"), envir = env)
  url <- paste0("ipc://", tempfile("run-r-timeout-", fileext = ".sock"))
  rep <- nanonext::socket("rep", listen = url)
  on.exit(close(rep), add = TRUE)
  res <- env$.run_remote(url, "1", timeout = 200)
  expect_false(isTRUE(res$ok))
  expect_match(res$error, "may still be running", fixed = TRUE)
  expect_match(res$error, "do not run it again", fixed = TRUE)
})
