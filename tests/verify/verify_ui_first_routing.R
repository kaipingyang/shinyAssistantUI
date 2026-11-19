#!/usr/bin/env Rscript
# Real-CLI routing probe for the UI-first guidance (Plan 167 revision): which card
# does Claude open first for each prompt? Each prompt runs in a fresh thread of the
# installed addin loaded from AUI_LIB (default: the Home library).
suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
source("tests/verify/owned_process_cleanup.R"); register_owned_process_cleanup()
`%||%` <- function(x, y) if (is.null(x)) y else x

main <- function() {
  root <- normalizePath(".", winslash = "/", mustWork = TRUE)
  lib <- Sys.getenv("AUI_LIB", .libPaths()[[1]])
  out <- Sys.getenv("AUI_ROUTING_OUT", file.path(root, ".kiro/verification-evidence",
    paste0("ui-routing-", format(Sys.time(), "%Y%m%d-%H%M%S"))))
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  cases <- list(
    list(id = "single-confirm", expect = "AskUserQuestion",
         prompt = "I want to rename the folder data/ to raw_data/. Before anything else, ask me to confirm yes or no. Do not use any other tool."),
    list(id = "analysis-params", expect = "AskUserForm",
         prompt = "I want to fit a regression on mtcars. Ask me for the response variable, the predictors, and whether to log-transform, then stop."),
    list(id = "book-categories", expect = "AskUserForm", needs_multi_and_many = TRUE,
         prompt = "\u7ed9\u6211\u4e00\u4e9b\u9009\u62e9\u9009\u51fa\u4e66\u7c4d\u4f5c\u8005\u56fd\u5bb6\u7b49\u5206\u7c7b")
  )
  temp_home <- file.path(tempdir(), "routing-home"); dir.create(temp_home, showWarnings = FALSE)
  real_home <- Sys.getenv("HOME")
  port <- httpuv::randomPort()
  logs <- c(file.path(out, "app-stdout.log"), file.path(out, "app-stderr.log"))
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app, character())
  on.exit(cleanup(), add = TRUE)
  app <- callr::r_bg(function(root) { setwd(root); source("tests/verify/plugin_acceptance_app.R", local = new.env()) },
    args = list(root = root),
    env = c(callr::rcmd_safe_env(), AUI_LIB = lib, AUI_PROJECT = file.path(tempdir(), "routing-proj"),
            AUI_PORT = as.character(port), R_LIBS_USER = "/nonexistent", HOME = temp_home, AUI_HOME = temp_home,
            AUI_RENVIRON = file.path(real_home, ".Renviron"), CLAUDE_CONFIG_DIR = file.path(real_home, ".claude"),
            PATH = paste(file.path(real_home, ".local/bin"), Sys.getenv("PATH"), sep = ":")),
    stdout = logs[[1]], stderr = logs[[2]], user_profile = FALSE, system_profile = FALSE)
  for (i in 1:300) { if (!app$is_alive() || any(grepl("Listening on", readLines(logs[[2]], warn = FALSE)))) break; Sys.sleep(0.1) }
  stopifnot(app$is_alive())
  cat(grep("^PLUGIN_LIB", readLines(logs[[1]], warn = FALSE), value = TRUE), "\n")

  chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
  browser <- ChromoteSession$new(width = 1200, height = 1000)
  console_errors <- list()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) console_errors[[length(console_errors) + 1L]] <<- event$args
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    console_errors[[length(console_errors) + 1L]] <<- event$exceptionDetails$text
  })
  value <- function(code) {
    r <- browser$Runtime$evaluate(code, returnByValue = TRUE, awaitPromise = TRUE)
    if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text, call. = FALSE)
    r$result$value
  }
  safe <- function(code, default = NULL) tryCatch(value(code), error = function(e) default)
  key <- function(k, code, vk) {
    browser$Input$dispatchKeyEvent(type = "keyDown", key = k, code = code, windowsVirtualKeyCode = vk)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = k, code = code, windowsVirtualKeyCode = vk)
  }
  click <- function(js) {
    p <- safe(sprintf("(()=>{const e=%s;if(!e)return null;e.scrollIntoView({block:'center',behavior:'instant'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()", js))
    if (is.null(p)) return(FALSE)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L)
    TRUE
  }
  running <- function() isTRUE(safe("!!document.querySelector('.aui-composer-cancel')", FALSE))
  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
  for (i in 1:300) { if (isTRUE(safe("!!document.querySelector('.aui-lexical-input[contenteditable=true]')", FALSE))) break; Sys.sleep(0.2) }
  Sys.sleep(3)

  results <- list()
  for (case in cases) {
    if (length(results)) {
      stopifnot(click("[...document.querySelectorAll('button')].find(b=>(b.innerText||'').trim()==='New Thread')"))
      fresh <- FALSE
      for (i in 1:50) {
        fresh <- isTRUE(safe("document.querySelectorAll('[data-role=user]').length===0 && !document.querySelector('.aui-composer-cancel')", FALSE))
        if (fresh) break
        Sys.sleep(0.2)
      }
      if (!fresh) stop("New Thread did not open an empty thread before case ", case$id)
    }
    stopifnot(click("document.querySelector('.aui-lexical-input[contenteditable=true]')"))
    browser$Input$insertText(text = case$prompt); Sys.sleep(0.2); key("Enter", "Enter", 13L)
    # The first send on a fresh page can be dropped while the runtime is still
    # wiring up; resend while the text is still in the composer.
    users_before <- safe("document.querySelectorAll('[data-role=user]').length", 0L)
    for (attempt in 1:4) {
      t_wait <- Sys.time() + 15
      while (Sys.time() < t_wait && !running() &&
             safe("document.querySelectorAll('[data-role=user]').length", 0L) <= users_before) Sys.sleep(0.3)
      if (running() || safe("document.querySelectorAll('[data-role=user]').length", 0L) > users_before) break
      click("document.querySelector('.aui-lexical-input[contenteditable=true]')"); key("Enter", "Enter", 13L)
    }
    first <- "none"; detail <- ""; shape <- list()
    deadline <- Sys.time() + 180; started <- FALSE; idle <- NULL
    repeat {
      if (running()) { started <- TRUE; idle <- NULL }
      if (identical(first, "none")) {
        if (isTRUE(safe("!!document.querySelector('[data-slot=ask-user-question]')", FALSE))) {
          first <- "AskUserQuestion"
          detail <- safe("[...document.querySelectorAll('[data-slot=ask-user-question] fieldset')].map(f=>f.querySelectorAll('input').length).join(',')", "")
          browser$screenshot(file.path(out, paste0(case$id, ".png")), show = FALSE)
          click("[...document.querySelectorAll('[data-slot=ask-user-question] button')].find(b=>/skip|cancel|dismiss/i.test(b.innerText))") ||
            click("document.querySelector('.aui-composer-cancel')")
        } else if (isTRUE(safe("[...document.querySelectorAll('[data-slot=aui_a2ui_surface]')].some(s=>s.querySelector('button')&&!/Submitted\\.|Cancelled\\./.test(s.innerText))", FALSE))) {
          first <- "AskUserForm"
          shape <- safe("(()=>{const s=[...document.querySelectorAll('[data-slot=aui_a2ui_surface]')].at(-1);const counts={};for(const i of s.querySelectorAll('input[type=checkbox],input[type=radio]')){const k=i.getAttribute('data-aui-field-name')||i.name||'';if(k)counts[k]=(counts[k]||0)+1};const largest=Math.max(0,...Object.values(counts));return {inputs:s.querySelectorAll('input,textarea,select').length,checkboxes:s.querySelectorAll('input[type=checkbox]').length,largest}})()", list())
          detail <- sprintf("%s inputs, %s checkboxes, largest group %s", shape$inputs %||% 0, shape$checkboxes %||% 0, shape$largest %||% 0)
          browser$screenshot(file.path(out, paste0(case$id, ".png")), show = FALSE)
          click("[...[...document.querySelectorAll('[data-slot=aui_a2ui_surface]')].at(-1).querySelectorAll('button')].find(b=>b.innerText.trim()==='Cancel')")
        }
      }
      if (started && !running()) { idle <- idle %||% Sys.time(); if (difftime(Sys.time(), idle, units = "secs") > 2) break }
      if (Sys.time() > deadline) { click("document.querySelector('.aui-composer-cancel')"); break }
      Sys.sleep(0.4)
    }
    open_card <- isTRUE(safe("!!document.querySelector('[data-slot=ask-user-question] [data-ask-submit]') || [...document.querySelectorAll('[data-slot=aui_a2ui_surface]')].some(s=>s.querySelector('button')&&!/Submitted\\.|Cancelled\\./.test(s.innerText))", FALSE))
    if (open_card) stop("A card was still open after case ", case$id)
    tools <- safe("[...document.querySelectorAll('[data-role=assistant]')].at(-1)?.innerText.match(/(Used|Running) tool: [^\\n(]+/g)?.join(' | ') ?? ''", "")
    reply <- safe("[...document.querySelectorAll('[data-role=assistant]')].at(-1)?.innerText ?? ''", "")
    tools <- paste(tools, "| reply:", substr(gsub("\\s+", " ", reply), 1, 160))
    pass <- identical(first, case$expect)
    if (isTRUE(case$needs_multi_and_many) && identical(first, "AskUserForm")) {
      pass <- pass && (shape$checkboxes %||% 0) > 1 && (shape$largest %||% 0) > 4
    }
    results[[case$id]] <- list(expect = case$expect, first = first, detail = detail, tools = tools, pass = pass)
    cat(sprintf("[%s] %-16s expect=%-15s first=%-15s %s | %s\n", if (pass) "PASS" else "FAIL", case$id, case$expect, first, detail, tools))
  }
  writeLines(toJSON(results, auto_unbox = TRUE, pretty = TRUE), file.path(out, "routing.json"))
  failed <- names(Filter(function(r) !isTRUE(r$pass), results))
  cat("CONSOLE_ERRORS", length(console_errors), "\n")
  cat("ROUTING_DONE pass=", sum(vapply(results, `[[`, TRUE, "pass")), "/", length(results), " evidence=", out, "\n", sep = "")
  if (length(failed) || length(console_errors)) {
    stop("UI routing probe failed: ", paste(c(failed, if (length(console_errors)) "console errors"), collapse = ", "))
  }
}
main()
