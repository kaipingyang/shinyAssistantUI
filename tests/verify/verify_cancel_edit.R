#!/usr/bin/env Rscript
suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

main <- function() {
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  home <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  stopifnot(identical(normalizePath(.libPaths()[1], winslash = "/"), home))
  port <- httpuv::randomPort()
  logs <- c(tempfile("cancel-edit-out-"), tempfile("cancel-edit-err-"))
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit(cleanup(), add = TRUE)

  app <- callr::r_bg(function(project, home, port) {
    .libPaths(c(home, .libPaths()))
    setwd(project)
    library(shinyAssistantUI, lib.loc = home)
    stopifnot(identical(normalizePath(find.package("shinyAssistantUI")),
                        file.path(home, "shinyAssistantUI")))
    shiny::runApp("tests/verify/cancel_edit_app.R", host = "127.0.0.1",
                  port = port, launch.browser = FALSE)
  }, args = list(project = project, home = home, port = port),
  stdout = logs[[1]], stderr = logs[[2]], user_profile = FALSE, system_profile = FALSE)
  for (i in seq_len(160L)) {
    if (!app$is_alive()) break
    if (file.exists(logs[[2]]) && any(grepl("Listening on", readLines(logs[[2]], warn = FALSE), fixed = TRUE))) break
    Sys.sleep(0.1)
  }
  if (!app$is_alive()) stop(paste(tail(readLines(logs[[2]], warn = FALSE), 30), collapse = "\n"))

  chromote::set_chrome_args(unique(c(chromote::default_chrome_args(),
    "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
  browser <- ChromoteSession$new(width = 900, height = 820)
  stage <- "boot"
  window_errors <- capture_browser_window_errors(browser, function() stage)
  console_errors <- runtime_errors <- network_errors <- list()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) console_errors[[length(console_errors) + 1L]] <<- event
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    runtime_errors[[length(runtime_errors) + 1L]] <<- event
  })
  browser$Network$loadingFailed(callback_ = function(event) {
    if (!isTRUE(event$canceled)) network_errors[[length(network_errors) + 1L]] <<- event
  })
  value <- function(code) {
    result <- browser$Runtime$evaluate(code, returnByValue = TRUE, awaitPromise = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
    result$result$value
  }
  wait <- function(code, timeout = 15) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(tryCatch(value(code), error = function(error) FALSE))) return(invisible(TRUE))
      if (!app$is_alive() || Sys.time() >= deadline) {
        cat("CANCEL_EDIT_BODY ", tryCatch(value("document.body.innerText"), error = function(error) "<unavailable>"), "\n", sep = "")
        if (file.exists(logs[[2]])) cat(tail(readLines(logs[[2]], warn = FALSE), 30), sep = "\n")
        stop("Timed out: ", code, call. = FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  click <- function(selector) {
    point <- value(sprintf("(()=>{const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()",
      toJSON(selector, auto_unbox = TRUE)))
    stopifnot(!is.null(point))
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

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  wait("!!document.querySelector('.aui-lexical-input[contenteditable=true]')")
  stage <- "first-send"
  click(".aui-lexical-input[contenteditable=true]")
  browser$Input$insertText(text = "cancel then edit")
  key("Enter", "Enter", 13L)
  wait("document.body.innerText.includes('partial answer before cancellation')")
  wait("!!document.querySelector('.aui-composer-cancel')")

  stage <- "cancel-and-edit"
  click(".aui-composer-cancel")
  wait("!document.querySelector('.aui-composer-cancel')")
  point <- value("(()=>{const e=document.querySelector('[data-role=user] .aui-user-message-content');const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()")
  browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
  wait("!!document.querySelector('.aui-user-action-edit')")
  click(".aui-user-action-edit")
  wait("!!document.querySelector('.aui-edit-composer-input')")
  click(".aui-edit-composer-input")
  key("a", "KeyA", 65L, 2L)
  browser$Input$insertText(text = "edited after cancel")
  click(".aui-edit-composer-root button:last-child")

  # The old backend turn is still inside its deterministic two-second drain.
  stopifnot(identical(fromJSON(value("document.getElementById('received').textContent")),
                      "cancel then edit"))
  stage <- "terminal-and-resend"
  wait("document.body.innerText.includes('echo: edited after cancel')", 12)
  received <- fromJSON(value("document.getElementById('received').textContent"))
  stopifnot(identical(as.character(received), c("cancel then edit", "edited after cancel")))
  wait("document.querySelectorAll('[data-role=user]').length===1 && document.querySelectorAll('[data-role=assistant]').length===1")
  body <- value("document.body.innerText")
  stopifnot(grepl("edited after cancel", body, fixed = TRUE))
  stopifnot(grepl("echo: edited after cancel", body, fixed = TRUE))
  stopifnot(!grepl("partial answer before cancellation", body, fixed = TRUE))
  stopifnot(length(console_errors) == 0L, length(runtime_errors) == 0L,
            length(window_errors()) == 0L, length(network_errors) == 0L)
  cat("CANCEL_EDIT_DONE version=", as.character(packageVersion("shinyAssistantUI", lib.loc = home)),
      " requests=", length(received), " console=0 runtime=0 window=0 network=0\n", sep = "")
  cleanup()
}

main()
