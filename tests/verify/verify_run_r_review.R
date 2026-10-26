#!/usr/bin/env Rscript
# Plan 163 browser gate: run_r output review.
# Real pieces: installed package, run_r MCP stdio subprocess, nanonext console server
# (main-session stand-in), review endpoint + session binding inside a Shiny app,
# headless Chromium. Claude itself is replaced by this script speaking JSON-RPC.
suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

main <- function() {
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  home_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  stopifnot(identical(normalizePath(.libPaths()[1], winslash = "/"), home_lib))
  evidence <- Sys.getenv("AUI_RUN_R_REVIEW_OUT",
    file.path(project, ".kiro/verification-evidence",
              paste0("run-r-review-", format(Sys.time(), "%Y%m%d-%H%M%S"))))
  dir.create(evidence, recursive = TRUE, showWarnings = FALSE)
  fake_home <- tempfile("run-r-review-home-")
  dir.create(fake_home)
  console_url <- paste0("ipc://", tempfile("rr-console-", fileext = ".sock"))
  review_url <- paste0("ipc://", tempfile("rr-review-", fileext = ".sock"))
  thread_file <- tempfile("rr-thread-")
  port <- httpuv::randomPort()
  logs <- c(tempfile("rr-app-out-"), tempfile("rr-app-err-"))
  app <- browser <- console <- NULL
  mcps <- list()
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit({
    for (p in mcps) try(if (p$is_alive()) p$kill_tree(), silent = TRUE)
    try(if (!is.null(console) && console$is_alive()) console$kill_tree(), silent = TRUE)
    cleanup()
    unlink(fake_home, recursive = TRUE)
  }, add = TRUE)

  # Main-session stand-in: the real console capture behind the real socket.
  console <- callr::r_bg(function(url, home_lib) {
    library(shinyAssistantUI, lib.loc = home_lib)
    sock <- nanonext::socket("rep", listen = url)
    repeat shinyAssistantUI:::.addin_console_service_once(sock, timeout = 100)
  }, args = list(url = console_url, home_lib = home_lib),
  user_profile = FALSE, system_profile = FALSE)

  app <- callr::r_bg(function(project, home_lib, port) {
    .libPaths(c(home_lib, .libPaths()))
    setwd(project)
    library(shinyAssistantUI, lib.loc = home_lib)
    stopifnot(identical(normalizePath(find.package("shinyAssistantUI")),
                        file.path(home_lib, "shinyAssistantUI")))
    shiny::runApp("tests/verify/run_r_review_app.R", host = "127.0.0.1",
                  port = port, launch.browser = FALSE)
  }, args = list(project = project, home_lib = home_lib, port = port),
  env = c(callr::rcmd_safe_env(), HOME = fake_home, AUI_REVIEW_URL = review_url,
          AUI_THREAD_FILE = thread_file, R_LIBS_USER = home_lib),
  stdout = logs[[1]], stderr = logs[[2]], user_profile = FALSE, system_profile = FALSE)
  for (i in seq_len(200L)) {
    if (!app$is_alive()) break
    if (file.exists(logs[[2]]) && any(grepl("Listening on", readLines(logs[[2]], warn = FALSE), fixed = TRUE))) break
    Sys.sleep(0.1)
  }
  if (!app$is_alive()) stop(paste(tail(readLines(logs[[2]], warn = FALSE), 30), collapse = "\n"))

  # ── MCP subprocess helpers (exactly what the Claude CLI would launch) ─────────
  script <- system.file("mcp", "run_r_server.R", package = "shinyAssistantUI", lib.loc = home_lib)
  start_mcp <- function(thread_id, timeout_ms = "630000") {
    env <- c(Sys.getenv(), CLAUDE_ADDIN_CONSOLE_URL = console_url,
             CLAUDE_ADDIN_REVIEW_URL = review_url, CLAUDE_ADDIN_THREAD_ID = thread_id,
             CLAUDE_ADDIN_REVIEW_TIMEOUT_MS = timeout_ms,
             R_LIBS = paste(.libPaths(), collapse = ":"))
    p <- processx::process$new(file.path(R.home("bin"), "Rscript"), c("--vanilla", script),
                               stdin = "|", stdout = "|", stderr = "|", env = env)
    mcps[[length(mcps) + 1L]] <<- p
    p
  }
  buffers <- new.env()
  send_rpc <- function(p, x) p$write_input(paste0(toJSON(x, auto_unbox = TRUE), "\n"))
  poll_rpc <- function(p, id) {
    key <- as.character(p$get_pid())
    lines <- c(get0(key, envir = buffers, ifnotfound = character()),
               tryCatch(p$read_output_lines(), error = function(e) character()))
    for (i in seq_along(lines)) {
      msg <- tryCatch(fromJSON(lines[[i]], simplifyVector = FALSE), error = function(e) NULL)
      if (is.list(msg) && !is.null(msg$id) && as.numeric(msg$id) == id) {
        assign(key, lines[-i], envir = buffers)
        return(msg)
      }
    }
    assign(key, lines, envir = buffers)
    NULL
  }
  await_rpc <- function(p, id, timeout = 30) {
    deadline <- Sys.time() + timeout
    repeat {
      msg <- poll_rpc(p, id)
      if (!is.null(msg)) return(msg)
      if (Sys.time() >= deadline) {
        if (file.exists(logs[[2]])) cat("APP_STDERR ", tail(readLines(logs[[2]], warn = FALSE), 25), sep = "\n")
        cat("BODY_AT_TIMEOUT ", tryCatch(value("document.body.innerText.slice(-600)"), error = function(e) "?"), "\n")
        stop("MCP timeout waiting for id ", id, call. = FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  init_mcp <- function(p) {
    send_rpc(p, list(jsonrpc = "2.0", id = 1, method = "initialize",
                     params = list(protocolVersion = "2024-11-05", capabilities = list(),
                                   clientInfo = list(name = "verify", version = "0"))))
    await_rpc(p, 1, 30)
  }
  call_id <- 10L
  call_run_r <- function(p, code) {
    call_id <<- call_id + 1L
    send_rpc(p, list(jsonrpc = "2.0", id = call_id, method = "tools/call",
                     params = list(name = "run_r", arguments = list(code = code))))
    call_id
  }
  result_text <- function(msg) msg$result$content[[1]]$text

  # ── Browser ───────────────────────────────────────────────────────────────────
  chromote::set_chrome_args(unique(c(chromote::default_chrome_args(),
    "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
  browser <- ChromoteSession$new(width = 1100, height = 900)
  stage <- "boot"
  window_errors <- capture_browser_window_errors(browser, function() stage)
  console_errors <- runtime_errors <- list()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) console_errors[[length(console_errors) + 1L]] <<- event
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    runtime_errors[[length(runtime_errors) + 1L]] <<- event
  })
  review_frames <- character()
  browser$Network$enable()
  browser$Network$webSocketFrameReceived(callback_ = function(e) {
    if (grepl("run-r-review", e$response$payloadData, fixed = TRUE))
      review_frames <<- c(review_frames, substr(e$response$payloadData, 1, 200))
  })
  value <- function(code) {
    result <- browser$Runtime$evaluate(code, returnByValue = TRUE, awaitPromise = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
    result$result$value
  }
  wait <- function(code, timeout = 20) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(tryCatch(value(code), error = function(error) FALSE))) return(invisible(TRUE))
      if (!app$is_alive() || Sys.time() >= deadline) {
        cat("RUN_R_REVIEW_BODY ", tryCatch(value("document.body.innerText"), error = function(e) "?"), "\n")
        if (file.exists(logs[[2]])) cat(tail(readLines(logs[[2]], warn = FALSE), 30), sep = "\n")
        cat("PANEL_AT_FAIL ", tryCatch(value("JSON.stringify({panel:document.querySelector('[data-slot=aui_run_r_review_panel]')?.outerHTML?.slice(0,300)??null,footer:!!document.querySelector('[data-slot=aui_thread-viewport-footer]'),cards:document.querySelectorAll('[data-run-r-review]').length})"), error=function(e) conditionMessage(e)), "\n")
        cat("FRAMES_AT_FAIL ", tail(review_frames, 2), sep = "\n")
        for (p in mcps) cat("MCP_STDERR ", tryCatch(p$read_error_lines(), error = function(e) "?"), "\n")
        stop("Timed out at stage ", stage, ": ", code, call. = FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  q <- function(selector) toJSON(selector, auto_unbox = TRUE)
  click <- function(selector) {
    point <- value(sprintf("(()=>{const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()", q(selector)))
    if (is.null(point)) stop("Missing element ", selector, call. = FALSE)
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y, button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y, button = "left", clickCount = 1L)
  }
  key <- function(key, code, vk, modifiers = 0L) {
    browser$Input$dispatchKeyEvent(type = "keyDown", key = key, code = code,
      windowsVirtualKeyCode = vk, modifiers = modifiers)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = key, code = code,
      windowsVirtualKeyCode = vk, modifiers = modifiers)
  }
  shots <- character()
  shot <- function(name) {
    Sys.sleep(0.25)
    path <- file.path(evidence, sprintf("%02d-%s.png", length(shots) + 1L, name))
    browser$screenshot(path, show = FALSE)
    shots <<- c(shots, path)
  }
  in_viewport <- function(selector) value(sprintf(
    "(()=>{const e=document.querySelector(%s);if(!e)return false;const r=e.getBoundingClientRect();return r.top>=0&&r.left>=0&&r.bottom<=innerHeight&&r.right<=innerWidth&&r.height>0})()",
    q(selector)))
  send_chat <- function(text) {
    click(".aui-lexical-input[contenteditable=true]")
    browser$Input$insertText(text = text)
    key("Enter", "Enter", 13L)
  }
  review_text <- function() value("document.querySelector('[data-run-r-review-text]')?.value ?? null")
  replace_review_text <- function(text) {
    click("[data-run-r-review-text]")
    key("a", "KeyA", 65L, 2L)
    browser$Input$insertText(text = text)
  }
  no_panel <- "!document.querySelector('[data-run-r-review]')"

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  wait("!!document.querySelector('.aui-lexical-input[contenteditable=true]')")

  stage <- "thread-id"
  send_chat("hello")
  wait("document.body.innerText.includes('echo: hello')")
  thread_id <- readLines(thread_file, warn = FALSE)[[1L]]
  stopifnot(nzchar(thread_id))
  mcp <- start_mcp(thread_id)
  init_mcp(mcp)
  checks <- list()

  # 1) Approve: every intermediate value is shown, then returned unchanged.
  stage <- "approve"
  id <- call_run_r(mcp, "a = 1\na\nb = 2\nprint(b)")
  wait("!!document.querySelector('[data-run-r-review-source=server]')")
  stopifnot(identical(review_text(), "[1] 1\n[1] 2"), isTRUE(in_viewport("[data-run-r-review]")))
  stopifnot(is.null(poll_rpc(mcp, id)))       # nothing returned before the decision
  shot("approve-pending")
  click("[data-run-r-review-action=approve]")
  msg <- await_rpc(mcp, id)
  stopifnot(identical(result_text(msg), "[1] 1\n[1] 2"), !isTRUE(msg$result$isError))
  wait(no_panel)
  checks$approve <- TRUE
  cat("ORIGIN after approve ", value("performance.timeOrigin"), "\n")

  # 2) Edit: only the edited text is returned.
  stage <- "edit"
  id <- call_run_r(mcp, "cat('user: alice\\npassword: hunter2\\n')")
  wait("!!document.querySelector('[data-run-r-review]')")
  stopifnot(identical(review_text(), "user: alice\npassword: hunter2"))
  replace_review_text("user: alice\npassword: <redacted>")
  wait("!!document.querySelector('[data-run-r-review-action=edit]')")
  shot("edit-before-send")
  click("[data-run-r-review-action=edit]")
  msg <- await_rpc(mcp, id)
  stopifnot(grepl("password: <redacted>", result_text(msg), fixed = TRUE),
            grepl("edited", result_text(msg), fixed = TRUE),
            !grepl("hunter2", result_text(msg), fixed = TRUE))
  wait(no_panel)
  checks$edit <- TRUE
  cat("ORIGIN after edit ", value("performance.timeOrigin"), "\n")

  # 3) Reject: the output never leaves; error output is reviewed too.
  stage <- "reject"
  id <- call_run_r(mcp, "print('secret-token')\nprin(1)")
  wait("!!document.querySelector('[data-run-r-review]')")
  stopifnot(grepl("secret-token", review_text(), fixed = TRUE),
            grepl("line 2", review_text(), fixed = TRUE))
  shot("reject-error-output")
  click("[data-run-r-review-action=reject]")
  msg <- await_rpc(mcp, id)
  stopifnot(isTRUE(msg$result$isError), !grepl("secret-token", result_text(msg), fixed = TRUE),
            grepl("did not approve", result_text(msg), fixed = TRUE))
  wait(no_panel)
  checks$reject <- TRUE
  cat("ORIGIN after reject ", value("performance.timeOrigin"), "\n")

  # 4) Stop declines the pending review of that thread.
  stage <- "stop"
  send_chat("wait")
  wait("!!document.querySelector('.aui-composer-cancel')")
  id <- call_run_r(mcp, "print('stop-secret')")
  wait("!!document.querySelector('[data-run-r-review]')")
  stopifnot(is.null(poll_rpc(mcp, id)))
  # Real pointer click on Stop (no screenshot right before it: CDP screenshots can
  # reflow the right-edge composer buttons in headless Chrome).
  click(".aui-composer-cancel")
  wait("!document.querySelector('.aui-composer-cancel')", 10)
  msg <- await_rpc(mcp, id)
  stopifnot(isTRUE(msg$result$isError), grepl("run was stopped", result_text(msg), fixed = TRUE),
            !grepl("stop-secret", result_text(msg), fixed = TRUE))
  wait(no_panel)
  shot("stop-declined")
  checks$stop <- TRUE
  cat("ORIGIN after stop ", value("performance.timeOrigin"), "\n")

  # 5) Run in Console: reviewed locally before it becomes a chat message.
  stage <- "run-in-console"
  send_chat("code")
  wait("!!document.querySelector('[data-run-in-console]')")
  click("[data-run-in-console]")
  wait("!!document.querySelector('[data-run-r-review-source=local]')")
  stopifnot(grepl("secret-token", review_text(), fixed = TRUE))
  replace_review_text("[1] 42")
  shot("console-local-review")
  click("[data-run-r-review-action=edit]")
  wait("document.body.innerText.includes('I ran this in my R console')")
  body <- value("document.body.innerText")
  stopifnot(!grepl("secret-token\"\n", body, fixed = TRUE),
            !grepl("[1] \"secret-token\"", body, fixed = TRUE))
  wait(no_panel)
  checks$run_in_console <- TRUE
  cat("ORIGIN after run_in_console ", value("performance.timeOrigin"), "\n")

  # 6) Another thread's review is summarised and survives a page reload.
  stage <- "other-thread"
  mcp2 <- start_mcp("other-thread", timeout_ms = "8000")
  init_mcp(mcp2)
  id2 <- call_run_r(mcp2, "print('elsewhere')")
  wait("!!document.querySelector('[data-run-r-review-elsewhere]')")
  stopifnot(is.null(value("document.querySelector('[data-run-r-review]')")))
  browser$Page$reload()
  browser$Page$loadEventFired()
  wait("!!document.querySelector('[data-run-r-review-elsewhere]')")
  shot("other-thread-after-reload")
  msg <- await_rpc(mcp2, id2, 20)   # the subprocess gives up → declined, never leaked
  stopifnot(isTRUE(msg$result$isError), !grepl("elsewhere'", result_text(msg), fixed = TRUE))
  checks$other_thread_reload <- TRUE
  cat("ORIGIN after other_thread_reload ", value("performance.timeOrigin"), "\n")

  # 7) Turning review off shares immediately and persists the choice.
  stage <- "toggle-off"
  click("button[aria-label=Settings][aria-expanded]")
  wait("!!document.querySelector('[data-slot=aui_run_r_review_toggle] input')")
  stopifnot(isTRUE(value("document.querySelector('[data-slot=aui_run_r_review_toggle] input').checked")))
  click("[data-slot=aui_run_r_review_toggle] input")
  wait("document.querySelector('[data-slot=aui_run_r_review_toggle] input').checked === false")
  settings_file <- file.path(fake_home, ".claude_addin", "run_r_output_review.json")
  deadline <- Sys.time() + 10
  while (!file.exists(settings_file) && Sys.time() < deadline) Sys.sleep(0.1)
  stopifnot(identical(fromJSON(settings_file)$enabled, FALSE))
  shot("settings-review-off")
  id <- call_run_r(mcp, "print('shared directly')")
  msg <- await_rpc(mcp, id, 15)
  stopifnot(identical(result_text(msg), "[1] \"shared directly\""))
  stopifnot(is.null(value("document.querySelector('[data-run-r-review]')")))
  checks$toggle_off <- TRUE
  cat("ORIGIN after toggle_off ", value("performance.timeOrigin"), "\n")

  stage <- "final"
  bad <- Filter(function(e) grepl("Minified React error|not valid as a React child",
                                  paste(unlist(e), collapse = " ")), c(console_errors, runtime_errors))
  stopifnot(length(runtime_errors) == 0L, length(bad) == 0L, length(window_errors()) == 0L)
  writeLines(c(
    "# run_r output review — headless Chromium acceptance",
    paste0("- package: ", as.character(packageVersion("shinyAssistantUI", lib.loc = home_lib))),
    paste0("- checks passed: ", paste(names(checks), collapse = ", ")),
    paste0("- console errors: ", length(console_errors), "; runtime exceptions: ",
           length(runtime_errors), "; window errors: ", length(window_errors())),
    "- screenshots:", paste0("  - ", basename(shots))
  ), file.path(evidence, "ACCEPTANCE.md"))
  cat("RUN_R_REVIEW_DONE checks=", paste(names(checks), collapse = ","),
      " console_errors=", length(console_errors), " evidence=", evidence, "\n", sep = "")
}

main()
