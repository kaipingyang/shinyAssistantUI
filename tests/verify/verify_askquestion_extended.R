#!/usr/bin/env Rscript
# Plan 165 browser gate: Claude Code 2.1.3xx AskUserQuestion extended kinds.
suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

main <- function() {
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  home <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  stopifnot(identical(normalizePath(.libPaths()[1], winslash = "/"), home))
  evidence <- Sys.getenv("AUI_ASK_EXT_OUT", file.path(project, ".kiro/verification-evidence",
    paste0("askquestion-extended-", format(Sys.time(), "%Y%m%d-%H%M%S"))))
  dir.create(evidence, recursive = TRUE, showWarnings = FALSE)
  port <- httpuv::randomPort()
  logs <- c(tempfile("ask-ext-out-"), tempfile("ask-ext-err-"))
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit(cleanup(), add = TRUE)

  app <- callr::r_bg(function(project, home, port) {
    .libPaths(c(home, .libPaths()))
    setwd(project)
    library(shinyAssistantUI, lib.loc = home)
    shiny::runApp("tests/verify/askquestion_extended_app.R", host = "127.0.0.1",
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
  browser <- ChromoteSession$new(width = 900, height = 900)
  stage <- "boot"
  window_errors <- capture_browser_window_errors(browser, function() stage)
  console_errors <- runtime_errors <- list()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) console_errors[[length(console_errors) + 1L]] <<- event
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    runtime_errors[[length(runtime_errors) + 1L]] <<- event
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
        cat("ASK_EXT_BODY ", tryCatch(value("document.body.innerText.slice(0,1500)"), error = function(e) "?"), "\n")
        if (file.exists(logs[[2]])) cat(tail(readLines(logs[[2]], warn = FALSE), 20), sep = "\n")
        stop("Timed out at ", stage, ": ", code, call. = FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  q <- function(x) toJSON(x, auto_unbox = TRUE)
  click <- function(selector) {
    point <- value(sprintf("(()=>{const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()", q(selector)))
    if (is.null(point)) stop("Missing element ", selector, call. = FALSE)
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y, button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y, button = "left", clickCount = 1L)
  }
  key <- function(key, code, vk, modifiers = 0L) {
    browser$Input$dispatchKeyEvent(type = "keyDown", key = key, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = key, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
  }
  type_into <- function(selector, text) {
    click(selector)
    key("a", "KeyA", 65L, 2L)
    browser$Input$insertText(text = text)
  }
  shots <- character()
  shot <- function(name) {
    Sys.sleep(0.25)
    path <- file.path(evidence, sprintf("%02d-%s.png", length(shots) + 1L, name))
    browser$screenshot(path, show = FALSE)
    shots <<- c(shots, path)
  }
  checks <- character()

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  wait("!!document.querySelector('.aui-lexical-input[contenteditable=true]')")
  value("window.__invalidSeen=false;new MutationObserver(()=>{if(document.querySelector('[data-ask-questions-invalid]'))window.__invalidSeen=true}).observe(document.documentElement,{childList:true,subtree:true});true")

  stage <- "live"
  click(".aui-lexical-input[contenteditable=true]")
  browser$Input$insertText(text = "deck")
  key("Enter", "Enter", 13L)
  wait("!!document.querySelector('[data-slot=ask-user-question] [data-ask-number]')")
  stopifnot(
    isTRUE(value("document.querySelector('[data-ask-title]')?.innerText==='Before I build your deck'")),
    isTRUE(value("document.querySelector('[data-ask-text]')?.getAttribute('placeholder')==='e.g. Q3 results'")),
    isTRUE(value("(()=>{const n=document.querySelector('[data-ask-number]');return n.value==='8'&&n.min==='3'&&n.max==='20'})()")),
    isTRUE(value("document.body.innerText.includes('One sentence is enough.') && document.body.innerText.includes('slides')")),
    isTRUE(value("!document.querySelector('[data-ask-questions-invalid]')"))
  )
  checks <- c(checks, "renders_text_number_choice_title")
  shot("pending-extended")

  type_into("[data-ask-number]", "42")
  wait("!!document.querySelector('[data-ask-number][aria-invalid=true]')")
  stopifnot(isTRUE(value("document.querySelector('[data-ask-submit]').disabled===true")))
  checks <- c(checks, "number_range_blocks_submit")
  shot("number-out-of-range")

  type_into("[data-ask-number]", "12")
  type_into("[data-ask-text]", "Q3 results")
  click("[data-ask-option=Bold] input")
  wait("document.querySelector('[data-ask-submit]').disabled===false")
  click("[data-ask-submit]")
  wait("(document.getElementById('decision')?.textContent||'').includes('How many slides?')", 12)
  decision <- fromJSON(value("document.getElementById('decision').textContent"))
  stopifnot(identical(decision[["What is the deck about?"]], "Q3 results"),
            identical(decision[["How many slides?"]], "12"),
            identical(decision[["Which style?"]], "Bold"))
  checks <- c(checks, "answers_round_trip_as_strings")
  wait("document.body.innerText.includes('done')")

  stage <- "history"
  point <- value("(()=>{const e=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(x=>(x.innerText||'').includes('Deck history'));if(!e)return null;const r=e.getBoundingClientRect();return {x:r.left+20,y:r.top+r.height/2}})()")
  stopifnot(!is.null(point))
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y, button = "left", clickCount = 1L)
  wait("document.body.innerText.includes('Historical deck answers restored')")
  value("(()=>{const e=document.querySelector('[data-slot=tool-fallback-trigger]');if(e&&e.getAttribute('aria-expanded')!=='true')e.click();return true})()")
  wait("!!document.querySelector('[data-arg-view=questions]')")
  stopifnot(
    isTRUE(value("[...document.querySelectorAll('[data-question-kind]')].map(e=>e.dataset.questionKind).join(',')==='text,number,single'")),
    isTRUE(value("(()=>{const v=document.querySelector('[data-arg-view=questions]').innerText;return v.includes('Number 3 – 20 slides')&&v.includes('Text answer')&&v.includes('Board update')&&v.includes('6')})()")),
    isTRUE(value("!document.querySelector('[data-slot=ask-user-question]')"))
  )
  checks <- c(checks, "history_restores_extended_summary")
  shot("history-extended")

  stage <- "final"
  bad <- Filter(function(e) grepl("Minified React error|not valid as a React child",
    paste(unlist(e), collapse = " ")), c(console_errors, runtime_errors))
  stopifnot(length(console_errors) == 0L, length(runtime_errors) == 0L, length(bad) == 0L,
            length(window_errors()) == 0L,
            isTRUE(value("window.__invalidSeen===false")))
  writeLines(c(
    "# AskUserQuestion extended kinds — headless Chromium acceptance",
    paste0("- package: ", as.character(packageVersion("shinyAssistantUI", lib.loc = home))),
    paste0("- checks passed: ", paste(checks, collapse = ", ")),
    paste0("- console errors: ", length(console_errors), "; runtime exceptions: ", length(runtime_errors)),
    "- screenshots:", paste0("  - ", basename(shots))
  ), file.path(evidence, "ACCEPTANCE.md"))
  cat("ASK_EXT_DONE checks=", paste(checks, collapse = ","), " console_errors=", length(console_errors),
      " evidence=", evidence, "\n", sep = "")
}

main()
