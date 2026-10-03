#!/usr/bin/env Rscript
suppressPackageStartupMessages({ library(callr); library(chromote) })
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

main <- function() {
  project <- normalizePath(".")
  home <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  port <- httpuv::randomPort()
  logs <- c(tempfile("a2ui-out-"), tempfile("a2ui-err-"))
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit(cleanup(), add = TRUE)
  app <- callr::r_bg(function(project, home, port) {
    .libPaths(c(home, .libPaths())); setwd(project)
    library(shinyAssistantUI, lib.loc = home)
    stopifnot(packageVersion("shinyAssistantUI") == "0.5.7.9016")
    shiny::runApp("tests/verify/a2ui_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project = project, home = home, port = port),
  stdout = logs[[1]], stderr = logs[[2]], user_profile = FALSE, system_profile = FALSE)
  for (i in seq_len(160L)) {
    if (!app$is_alive()) break
    if (file.exists(logs[[2]]) && any(grepl("Listening on", readLines(logs[[2]], warn = FALSE), fixed = TRUE))) break
    Sys.sleep(0.1)
  }
  if (!app$is_alive()) stop(paste(tail(readLines(logs[[2]], warn = FALSE), 30), collapse = "\n"))

  chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
  browser <- ChromoteSession$new(width = 900, height = 820)
  stage <- "boot"
  window_errors <- capture_browser_window_errors(browser, function() stage)
  console_errors <- runtime_errors <- network_errors <- list()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) if (identical(event$type, "error")) console_errors[[length(console_errors)+1L]] <<- event)
  browser$Runtime$exceptionThrown(callback_ = function(event) runtime_errors[[length(runtime_errors)+1L]] <<- event)
  browser$Network$loadingFailed(callback_ = function(event) if (!isTRUE(event$canceled)) network_errors[[length(network_errors)+1L]] <<- event)
  value <- function(code) {
    result <- browser$Runtime$evaluate(code, returnByValue = TRUE, awaitPromise = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
    result$result$value
  }
  wait <- function(code, timeout = 15) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(tryCatch(value(code), error = function(e) FALSE))) return(invisible(TRUE))
      if (!app$is_alive() || Sys.time() >= deadline) {
        if (file.exists(logs[[2]])) cat(tail(readLines(logs[[2]], warn = FALSE), 30), sep = "\n")
        stop("Timed out: ", code, call. = FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  click <- function(selector) {
    point <- value(sprintf("(()=>{const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()", jsonlite::toJSON(selector, auto_unbox = TRUE)))
    stopifnot(!is.null(point))
    browser$Input$dispatchMouseEvent(type="mousePressed", x=point$x, y=point$y, button="left", clickCount=1L)
    browser$Input$dispatchMouseEvent(type="mouseReleased", x=point$x, y=point$y, button="left", clickCount=1L)
  }
  key <- function() {
    browser$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
    browser$Input$dispatchKeyEvent(type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
  }

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
  wait("!!document.querySelector('.aui-lexical-input[contenteditable=true]')")
  stage <- "create"
  click(".aui-lexical-input[contenteditable=true]")
  browser$Input$insertText(text = "show a2ui")
  key()
  wait("document.querySelector('[data-slot=aui_a2ui_surface]')?.dataset.surfaceRevision==='1'")
  wait("document.querySelector('[data-aui=button]')?.textContent.includes('Confirm A2UI')")
  stopifnot(value("document.querySelectorAll('[data-slot=aui_a2ui_surface]').length") == 1)

  stage <- "action-update"
  click("[data-aui=button]")
  wait("document.querySelector('[data-slot=aui_a2ui_surface]')?.dataset.surfaceRevision==='2'")
  wait("document.querySelector('[data-aui=button]')?.textContent.includes('Updated A2UI')")
  wait("document.getElementById('actions').textContent.trim()==='1'")

  stage <- "action-delete"
  click("[data-aui=button]")
  wait("!document.querySelector('[data-slot=aui_a2ui_surface]')")
  wait("document.getElementById('actions').textContent.trim()==='2'")
  stopifnot(length(console_errors)==0L, length(runtime_errors)==0L,
            length(window_errors())==0L, length(network_errors)==0L)
  cat("A2UI_BROWSER_DONE create=1 update=2 delete=3 actions=2 console=0 runtime=0 window=0 network=0\n")
  cleanup()
}
main()
