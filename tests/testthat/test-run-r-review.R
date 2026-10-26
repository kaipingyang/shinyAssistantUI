# Plan 163 batch 2: user review of run_r output before it is returned to Claude.

manual_scheduler <- function() {
  jobs <- new.env(parent = emptyenv())
  jobs$items <- list()
  list(
    schedule = function(callback, delay) {
      id <- length(jobs$items) + 1L
      jobs$items[[id]] <- list(callback = callback, delay = delay, active = TRUE)
      function() jobs$items[[id]]$active <- FALSE
    },
    fire_all = function() {
      for (id in seq_along(jobs$items)) {
        job <- jobs$items[[id]]
        if (isTRUE(job$active)) {
          jobs$items[[id]]$active <- FALSE
          job$callback()
        }
      }
    },
    delays = function() vapply(jobs$items, `[[`, numeric(1), "delay")
  )
}

review_request <- function(thread_id = "t1", text = "[1] 1", is_error = FALSE,
                           request_id = "req-1") {
  list(type = "run_r_output_review", version = 1L, request_id = request_id,
       thread_id = thread_id, code = "print(1)", text = text, is_error = is_error)
}

new_service <- function(enabled = TRUE, scheduler = manual_scheduler(), timeout = 600) {
  ids <- 0L
  service <- shinyAssistantUI:::.new_run_r_review_service(
    enabled = function() enabled,
    timeout = timeout,
    schedule = scheduler$schedule,
    id_factory = function() { ids <<- ids + 1L; paste0("review-", ids) }
  )
  list(service = service, scheduler = scheduler)
}

recording_sink <- function() {
  log <- new.env(parent = emptyenv())
  log$shown <- list()
  log$dismissed <- list()
  list(
    log = log,
    show = function(review) log$shown[[length(log$shown) + 1L]] <- review,
    dismiss = function(id, outcome) {
      log$dismissed[[length(log$dismissed) + 1L]] <- list(id = id, outcome = outcome)
    }
  )
}

capture_response <- function() {
  box <- new.env(parent = emptyenv())
  box$calls <- 0L
  list(
    box = box,
    respond = function(response) {
      box$calls <- box$calls + 1L
      box$response <- response
    }
  )
}

test_that("review disabled returns the original output without showing anything", {
  s <- new_service(enabled = FALSE)
  sink <- recording_sink()
  s$service$add_sink("a", sink$show, sink$dismiss)
  r <- capture_response()
  s$service$request(review_request(text = "secret"), r$respond)
  expect_identical(r$box$calls, 1L)
  expect_identical(r$box$response$decision, "approve")
  expect_identical(r$box$response$text, "secret")
  expect_length(sink$log$shown, 0L)
})

test_that("without a connected reviewer the output is rejected immediately", {
  s <- new_service()
  r <- capture_response()
  s$service$request(review_request(), r$respond)
  expect_identical(r$box$response$decision, "reject")
  expect_identical(r$box$response$reason, "no_reviewer")
  expect_null(r$box$response$text)
})

test_that("malformed requests are rejected without showing them", {
  s <- new_service()
  sink <- recording_sink()
  s$service$add_sink("a", sink$show, sink$dismiss)
  extra <- review_request(); extra$unexpected <- TRUE
  missing_id <- review_request(); missing_id$request_id <- NULL
  for (bad in list(NULL, "x", list(type = "other"), modifyList(review_request(), list(text = 1)),
                   modifyList(review_request(), list(thread_id = NA_character_)),
                   modifyList(review_request(), list(version = 2L)), extra, missing_id)) {
    r <- capture_response()
    s$service$request(bad, r$respond)
    expect_identical(r$box$response$decision, "reject")
    expect_identical(r$box$response$reason, "invalid_request")
  }
  expect_length(sink$log$shown, 0L)
})

test_that("approve returns the original text and dismisses the review everywhere", {
  s <- new_service()
  a <- recording_sink(); b <- recording_sink()
  s$service$add_sink("a", a$show, a$dismiss)
  s$service$add_sink("b", b$show, b$dismiss)
  r <- capture_response()
  s$service$request(review_request(text = "[1] 1\n[1] 2"), r$respond)
  expect_identical(r$box$calls, 0L)
  expect_length(a$log$shown, 1L)
  shown <- a$log$shown[[1L]]
  expect_identical(shown$id, "review-1")
  expect_identical(shown$threadId, "t1")
  expect_identical(shown$code, "print(1)")
  expect_identical(shown$text, "[1] 1\n[1] 2")
  expect_false(shown$isError)
  expect_length(b$log$shown, 1L)

  expect_true(s$service$decide("review-1", "approve", text = "ignored"))
  expect_identical(r$box$response$decision, "approve")
  expect_identical(r$box$response$text, "[1] 1\n[1] 2")
  expect_identical(a$log$dismissed[[1L]], list(id = "review-1", outcome = "approve"))
  expect_identical(b$log$dismissed[[1L]], list(id = "review-1", outcome = "approve"))
  # a second decision (e.g. from another tab) is ignored
  expect_false(s$service$decide("review-1", "reject"))
  expect_identical(r$box$calls, 1L)
  expect_length(s$service$pending(), 0L)
})

test_that("edit returns only the edited text and validates it", {
  s <- new_service()
  sink <- recording_sink()
  s$service$add_sink("a", sink$show, sink$dismiss)
  r <- capture_response()
  s$service$request(review_request(text = "name: Alice\nsalary: 100"), r$respond)
  expect_false(s$service$decide("review-1", "edit", text = 5))
  expect_false(s$service$decide("review-1", "edit", text = strrep("x", 200001L)))
  expect_false(s$service$decide("review-1", "maybe"))
  expect_identical(r$box$calls, 0L)
  expect_true(s$service$decide("review-1", "edit", text = "name: <redacted>"))
  expect_identical(r$box$response$decision, "edit")
  expect_identical(r$box$response$text, "name: <redacted>")
})

test_that("reject never returns the output", {
  s <- new_service()
  sink <- recording_sink()
  s$service$add_sink("a", sink$show, sink$dismiss)
  r <- capture_response()
  s$service$request(review_request(text = "secret"), r$respond)
  expect_true(s$service$decide("review-1", "reject", text = "secret"))
  expect_identical(r$box$response$decision, "reject")
  expect_identical(r$box$response$reason, "user")
  expect_null(r$box$response$text)
})

test_that("timeout, Stop and shutdown reject pending reviews", {
  s <- new_service(timeout = 30)
  sink <- recording_sink()
  s$service$add_sink("a", sink$show, sink$dismiss)
  r1 <- capture_response(); r2 <- capture_response(); r3 <- capture_response()
  s$service$request(review_request(thread_id = "t1"), r1$respond)
  s$service$request(review_request(thread_id = "t2"), r2$respond)
  expect_identical(s$scheduler$delays(), c(30, 30))

  s$service$cancel_thread("t2")
  expect_identical(r2$box$response$reason, "stopped")
  expect_identical(r1$box$calls, 0L)

  s$scheduler$fire_all()
  expect_identical(r1$box$response$decision, "reject")
  expect_identical(r1$box$response$reason, "timeout")
  expect_identical(r2$box$calls, 1L)

  r4 <- capture_response()
  s$service$request(review_request(), r4$respond)
  s$service$request(review_request(), r3$respond)
  s$service$close()
  expect_identical(r3$box$response$reason, "shutdown")
  expect_identical(r4$box$response$reason, "shutdown")
})

test_that("a reconnecting browser receives reviews that are still pending", {
  s <- new_service()
  first <- recording_sink()
  remove_first <- s$service$add_sink("a", first$show, first$dismiss)
  r <- capture_response()
  s$service$request(review_request(), r$respond)
  remove_first()
  expect_identical(r$box$calls, 0L)          # a reload does not reject
  second <- recording_sink()
  s$service$add_sink("b", second$show, second$dismiss)
  expect_identical(second$log$shown[[1L]]$id, "review-1")
  expect_true(s$service$decide("review-1", "approve"))
  expect_identical(r$box$response$decision, "approve")
})

test_that("a throwing sink or responder does not break the service", {
  s <- new_service()
  s$service$add_sink("bad", function(review) stop("boom"), function(id, outcome) stop("boom"))
  good <- recording_sink()
  s$service$add_sink("good", good$show, good$dismiss)
  s$service$request(review_request(), function(response) stop("responder failed"))
  expect_length(good$log$shown, 1L)
  expect_true(s$service$decide("review-1", "approve"))
  expect_length(s$service$pending(), 0L)
})

test_that("review setting file defaults to enabled and fails closed", {
  path <- withr::local_tempfile(fileext = ".json")
  expect_true(shinyAssistantUI:::.read_run_r_output_review_enabled(path))
  writeLines("not json", path)
  expect_true(shinyAssistantUI:::.read_run_r_output_review_enabled(path))
  writeLines('{"enabled":"no"}', path)
  expect_true(shinyAssistantUI:::.read_run_r_output_review_enabled(path))
  expect_true(shinyAssistantUI:::.write_run_r_output_review_enabled(FALSE, path))
  expect_false(shinyAssistantUI:::.read_run_r_output_review_enabled(path))
  expect_true(shinyAssistantUI:::.write_run_r_output_review_enabled(TRUE, path))
  expect_true(shinyAssistantUI:::.read_run_r_output_review_enabled(path))
  expect_false(shinyAssistantUI:::.write_run_r_output_review_enabled(NA, path))
  expect_identical(file.info(path)$mode, as.octmode("600"))
  for (bad in c('{"enabled":false,"enabled":false}', '{"enabled":false,"x":1}', '[false]')) {
    writeLines(bad, path)
    expect_true(shinyAssistantUI:::.read_run_r_output_review_enabled(path))
  }
})

test_that("a symlinked review setting is ignored and never written through", {
  skip_on_os("windows")
  dir <- withr::local_tempdir()
  target <- file.path(dir, "target.json")
  writeLines('{"enabled":false}', target)
  link <- file.path(dir, "run_r_output_review.json")
  file.symlink(target, link)
  expect_true(shinyAssistantUI:::.read_run_r_output_review_enabled(link))
  expect_false(shinyAssistantUI:::.write_run_r_output_review_enabled(FALSE, link))
  expect_identical(readLines(target), '{"enabled":false}')
})

test_that("concurrent requests each receive their own decision", {
  skip_if_not_installed("nanonext")
  skip_if_not_installed("later")
  url <- paste0("ipc://", tempfile("review-concurrent-", fileext = ".sock"))
  sink <- recording_sink()
  service <- shinyAssistantUI:::.new_run_r_review_service(enabled = function() TRUE)
  service$add_sink("a", sink$show, sink$dismiss)
  server <- shinyAssistantUI:::.start_run_r_review_server(url, service)
  on.exit(server$close(), add = TRUE)
  ask <- function(id, text) {
    sock <- nanonext::socket("req", dial = url)
    list(sock = sock, aio = nanonext::request(nanonext::context(sock),
      data = review_request(thread_id = id, text = text, request_id = id), timeout = 10000))
  }
  one <- ask("id-1", "first"); two <- ask("id-2", "second")
  on.exit({ close(one$sock); close(two$sock) }, add = TRUE)
  deadline <- Sys.time() + 5
  while (length(sink$log$shown) < 2L && Sys.time() < deadline) later::run_now(0.05)
  expect_length(sink$log$shown, 2L)
  by_thread <- setNames(vapply(sink$log$shown, `[[`, character(1), "id"),
                        vapply(sink$log$shown, `[[`, character(1), "threadId"))
  expect_true(service$decide(by_thread[["id-1"]], "approve"))
  expect_true(service$decide(by_thread[["id-2"]], "reject"))
  nanonext::call_aio(one$aio); nanonext::call_aio(two$aio)
  expect_identical(one$aio$data$request_id, "id-1")
  expect_identical(one$aio$data$decision, "approve")
  expect_identical(one$aio$data$text, "first")
  expect_identical(two$aio$data$request_id, "id-2")
  expect_identical(two$aio$data$decision, "reject")
  expect_null(two$aio$data$text)
})

test_that("each thread's run_r server receives its own thread id", {
  servers <- list(
    r_session = list(type = "stdio", command = "Rscript",
                     env = list(CLAUDE_ADDIN_CONSOLE_URL = "ipc:///tmp/c",
                                CLAUDE_ADDIN_REVIEW_URL = "ipc:///tmp/r")),
    other = list(type = "stdio", command = "x")
  )
  a <- shinyAssistantUI:::.filter_run_r_mcp(servers, TRUE, thread_id = "thread-A")
  b <- shinyAssistantUI:::.filter_run_r_mcp(servers, TRUE, thread_id = "thread-B")
  expect_identical(a$r_session$env$CLAUDE_ADDIN_THREAD_ID, "thread-A")
  expect_identical(b$r_session$env$CLAUDE_ADDIN_THREAD_ID, "thread-B")
  expect_identical(a$r_session$env$CLAUDE_ADDIN_CONSOLE_URL, "ipc:///tmp/c")
  expect_null(a$other$env)
  expect_null(servers$r_session$env$CLAUDE_ADDIN_THREAD_ID)
  expect_null(shinyAssistantUI:::.filter_run_r_mcp(servers, FALSE, thread_id = "x")$r_session)
  expect_identical(shinyAssistantUI:::.filter_run_r_mcp(servers, TRUE), servers)
  # A user-supplied server that merely shares the name is not modified.
  user <- list(r_session = list(type = "stdio", command = "x", env = c(A = "1")))
  expect_silent(out <- shinyAssistantUI:::.filter_run_r_mcp(user, TRUE, thread_id = "t"))
  expect_identical(out, user)
  # Character-vector env from the addin keeps its representation.
  chr <- list(r_session = list(type = "stdio", command = "x",
                               env = c(CLAUDE_ADDIN_REVIEW_URL = "ipc:///tmp/r")))
  expect_silent(out <- shinyAssistantUI:::.filter_run_r_mcp(chr, TRUE, thread_id = "t"))
  expect_identical(out$r_session$env,
                   c(CLAUDE_ADDIN_REVIEW_URL = "ipc:///tmp/r", CLAUDE_ADDIN_THREAD_ID = "t"))
})

test_that("review server answers over nanonext after the user decides", {
  skip_if_not_installed("nanonext")
  skip_if_not_installed("later")
  url <- paste0("ipc://", tempfile("review-test-", fileext = ".sock"))
  sink <- recording_sink()
  service <- shinyAssistantUI:::.new_run_r_review_service(enabled = function() TRUE)
  service$add_sink("a", sink$show, sink$dismiss)
  server <- shinyAssistantUI:::.start_run_r_review_server(url, service)
  expect_false(is.null(server))
  on.exit(server$close(), add = TRUE)

  req <- nanonext::socket("req", dial = url)
  on.exit(close(req), add = TRUE)
  aio <- nanonext::request(nanonext::context(req), data = review_request(text = "out"),
                           timeout = 10000)
  deadline <- Sys.time() + 5
  while (!length(sink$log$shown) && Sys.time() < deadline) later::run_now(0.05)
  expect_length(sink$log$shown, 1L)
  expect_true(nanonext::unresolved(aio))
  expect_true(service$decide(sink$log$shown[[1L]]$id, "edit", text = "redacted"))
  nanonext::call_aio(aio)
  expect_identical(aio$data$decision, "edit")
  expect_identical(aio$data$text, "redacted")
})

test_that("a browser sync request resends every pending review and the setting", {
  s <- new_service()
  sent <- list()
  r <- capture_response()
  shiny::testServer(function(input, output, session) {
    binding <- shinyAssistantUI:::.bind_run_r_review(
      s$service, session, "chat_input",
      read_enabled = function() TRUE,
      send = function(payload) sent[[length(sent) + 1L]] <<- payload
    )
    expect_identical(binding$config, list(version = 1L, enabled = TRUE))
  }, {
    session$flushReact()
    s$service$request(review_request(text = "pending"), r$respond)
    sent <<- list()
    session$setInputs(chat_input_run_r_review = list(type = "sync", nonce = "1"))
    types <- vapply(sent, `[[`, character(1), "type")
    expect_identical(types, c("show", "settings"))
    expect_identical(sent[[1L]]$review$text, "pending")
    session$setInputs(chat_input_cancel = list(threadId = "t1"))
    expect_identical(r$box$response$reason, "stopped")
  })
})
