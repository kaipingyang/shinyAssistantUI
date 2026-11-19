#!/usr/bin/env Rscript
# Headless acceptance of the installed addin (real Claude CLI) from a chosen library.
#   AUI_LIB  library root to load shinyAssistantUI/ClaudeAgentSDK from (e.g. Dev Shared)
# Each scenario drives the real composer and answers the cards the model produces.
suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
source("tests/verify/owned_process_cleanup.R"); register_owned_process_cleanup()
source("tests/verify/window_error_capture.R")
`%||%` <- function(x, y) if (is.null(x)) y else x

main <- function() {
  project_root <- normalizePath(".", winslash = "/", mustWork = TRUE)
  lib <- Sys.getenv("AUI_LIB", "/usrfiles/shared-projects/users/kaiping_yang/Rlibs/rstudio-addins_dev/R-4.4")
  evidence <- Sys.getenv("AUI_PLUGIN_OUT", file.path(project_root, ".kiro/verification-evidence",
    paste0("plugin-acceptance-", format(Sys.time(), "%Y%m%d-%H%M%S"))))
  dir.create(evidence, recursive = TRUE, showWarnings = FALSE)
  proj <- file.path(tempdir(), paste0("plugin-proj-", as.integer(Sys.time())))
  port <- httpuv::randomPort()
  temp_home <- file.path(tempdir(), "plugin-home")
  dir.create(temp_home, showWarnings = FALSE)
  real_home <- Sys.getenv("HOME")
  logs <- c(file.path(evidence, "app-stdout.log"), file.path(evidence, "app-stderr.log"))
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app, character())
  on.exit(cleanup(), add = TRUE)

  app <- callr::r_bg(function(root) {
    setwd(root); source("tests/verify/plugin_acceptance_app.R", local = new.env())
  }, args = list(root = project_root),
  env = c(callr::rcmd_safe_env(), AUI_LIB = lib, AUI_PROJECT = proj, AUI_PORT = as.character(port),
          R_LIBS_USER = "/nonexistent", HOME = temp_home, AUI_HOME = temp_home,
          AUI_RENVIRON = file.path(real_home, ".Renviron"),
          CLAUDE_CONFIG_DIR = file.path(real_home, ".claude"),
          PATH = paste(file.path(real_home, ".local/bin"), Sys.getenv("PATH"), sep = ":")),
  stdout = logs[[1]], stderr = logs[[2]], user_profile = FALSE, system_profile = FALSE)
  for (i in seq_len(300L)) {
    if (!app$is_alive()) break
    if (file.exists(logs[[2]]) && any(grepl("Listening on", readLines(logs[[2]], warn = FALSE), fixed = TRUE))) break
    Sys.sleep(0.1)
  }
  if (!app$is_alive()) stop(paste(tail(readLines(logs[[2]], warn = FALSE), 30), collapse = "\n"))
  libline <- grep("^PLUGIN_LIB", readLines(logs[[1]], warn = FALSE), value = TRUE)
  cat(libline, "\n")

  chromote::set_chrome_args(unique(c(chromote::default_chrome_args(),
    "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
  browser <- ChromoteSession$new(width = 1200, height = 1000)
  stage <- "boot"
  window_errors <- capture_browser_window_errors(browser, function() stage)
  console_errors <- runtime_errors <- list()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) console_errors[[length(console_errors) + 1L]] <<- list(stage = stage, args = event$args)
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    runtime_errors[[length(runtime_errors) + 1L]] <<- list(stage = stage, text = event$exceptionDetails$text)
  })
  value <- function(code) {
    r <- browser$Runtime$evaluate(code, returnByValue = TRUE, awaitPromise = TRUE)
    if (!is.null(r$exceptionDetails)) stop("JS error at ", stage, ": ", r$exceptionDetails$text, call. = FALSE)
    r$result$value
  }
  safe <- function(code, default = NULL) tryCatch(value(code), error = function(e) default)
  q <- function(x) toJSON(x, auto_unbox = TRUE)
  key <- function(k, code, vk, modifiers = 0L) {
    browser$Input$dispatchKeyEvent(type = "keyDown", key = k, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = k, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
  }
  click_xy <- function(js_el) {
    p <- safe(sprintf("(()=>{const e=%s;if(!e)return null;e.scrollIntoView({block:'center',behavior:'instant'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()", js_el))
    if (is.null(p)) return(FALSE)
    Sys.sleep(0.15)
    p <- safe(sprintf("(()=>{const r=(%s).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()", js_el))
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L)
    TRUE
  }
  js_click <- function(js_el) isTRUE(safe(sprintf("(()=>{const e=%s;if(!e)return false;e.click();return true})()", js_el), FALSE))
  type_into <- function(js_el, text) {
    if (!click_xy(js_el)) return(FALSE)
    key("a", "KeyA", 65L, 2L); browser$Input$insertText(text = text); TRUE
  }
  shots <- character()
  shot <- function(name) {
    Sys.sleep(0.3)
    path <- file.path(evidence, sprintf("%02d-%s.png", length(shots) + 1L, name))
    try(browser$screenshot(path, show = FALSE), silent = TRUE)
    shots <<- c(shots, path)
  }
  running <- function() isTRUE(safe("!!document.querySelector('.aui-composer-cancel')", FALSE))
  last_assistant <- function() safe("(()=>{const a=[...document.querySelectorAll('[data-role=assistant]')];return a.length?a.at(-1).innerText:''})()", "")
  send <- function(text) {
    stopifnot(click_xy("document.querySelector('.aui-lexical-input[contenteditable=true]')"))
    browser$Input$insertText(text = text)
    Sys.sleep(0.2); key("Enter", "Enter", 13L)
    deadline <- Sys.time() + 20
    while (!running() && Sys.time() < deadline) Sys.sleep(0.2)
  }
  approve_tool_cards <- function() {
    js_click("[...document.querySelectorAll('.aui-shiny-approval button')].find(b=>(b.innerText||'').trim()==='Approve')")
  }
  # Drive one turn: call `on_tick()` until the run ends and `done()` holds.
  drive <- function(on_tick, done = function() TRUE, timeout = 240) {
    deadline <- Sys.time() + timeout
    idle_since <- NULL
    repeat {
      on_tick()
      if (!running()) {
        idle_since <- idle_since %||% Sys.time()
        if (isTRUE(done()) && difftime(Sys.time(), idle_since, units = "secs") > 2) return(TRUE)
      } else idle_since <- NULL
      if (Sys.time() >= deadline) return(FALSE)
      Sys.sleep(0.5)
    }
  }
  results <- list()
  record <- function(name, pass, detail = "") {
    results[[name]] <<- list(pass = isTRUE(pass), detail = detail)
    cat(sprintf("[%s] %-48s %s\n", if (isTRUE(pass)) "PASS" else "FAIL", name, detail))
  }

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  ok <- tryCatch({ for (i in 1:300) { if (isTRUE(safe("!!document.querySelector('.aui-lexical-input[contenteditable=true]')", FALSE))) break; Sys.sleep(0.2) }; TRUE }, error = function(e) FALSE)
  record("addin mounted from Dev Shared", grepl("sau=0.5.7.9017", libline) && grepl("sdk=0.2.5.9002", libline), libline)

  # 1) run_r returns every intermediate result, reviewed before Claude sees it.
  stage <- "run_r"
  review <- NULL
  send(paste(
    "Call the run_r tool exactly once with this R code (keep the line breaks):",
    "x <- 41\nx + 1\nprint(\"middle\")\nx * 2",
    "Then reply with one short sentence listing the values you saw. Use no other tools."))
  finished <- drive(function() {
    approve_tool_cards()
    if (is.null(review) && isTRUE(safe("!!document.querySelector('[data-run-r-review]')", FALSE))) {
      review <<- safe("document.querySelector('[data-run-r-review-text]').value", "")
      shot("run-r-review-card")
      js_click("document.querySelector('[data-run-r-review-action=approve]')")
    }
  }, done = function() !is.null(review))
  record("run_r review card shown before sharing", !is.null(review), if (is.null(review)) "no review card" else "")
  record("review shows all intermediate results",
         !is.null(review) && all(vapply(c("[1] 42", "middle", "[1] 82"), grepl, TRUE, x = review, fixed = TRUE)),
         gsub("\n", " | ", review %||% ""))
  reply <- last_assistant()
  record("Claude received the approved output", finished && grepl("82", reply), substr(gsub("\n", " ", reply), 1, 120))
  shot("run-r-reply")

  # 2) AskUserForm rendered through A2UI and answered in the chat.
  stage <- "ask_form"
  form_seen <- FALSE; form_submitted <- FALSE
  send(paste(
    "Call the AskUserForm tool once with title \"Analysis settings\", submit_label \"Run\" and two fields:",
    "name \"dataset\" (type text, label \"Dataset\", required true) and",
    "name \"rows\" (type number, label \"Rows\", default \"5\").",
    "After it returns, reply with exactly: DATASET=<dataset> ROWS=<rows>. Use no other tools."))
  finished <- drive(function() {
    approve_tool_cards()
    has_form <- isTRUE(safe("!!document.querySelector('[data-slot=aui_a2ui_surface] [name=\"/values/dataset\"]')", FALSE))
    if (has_form && !form_submitted) {
      form_seen <<- TRUE
      shot("ask-form-card")
      type_into("document.querySelector('[data-slot=aui_a2ui_surface] [name=\"/values/dataset\"]')", "mtcars")
      type_into("document.querySelector('[data-slot=aui_a2ui_surface] [name=\"/values/rows\"]')", "12")
      js_click("[...document.querySelectorAll('[data-slot=aui_a2ui_surface] button')].find(b=>(b.innerText||'').trim()==='Run')")
      form_submitted <<- TRUE
    }
  }, done = function() form_submitted)
  record("AskUserForm card rendered (A2UI)", form_seen)
  summary_ok <- isTRUE(safe("[...document.querySelectorAll('[data-slot=aui_a2ui_surface]')].some(s=>s.innerText.includes('Submitted.')&&s.innerText.includes('Dataset: mtcars'))", FALSE))
  record("form became a read-only summary", summary_ok)
  reply <- last_assistant()
  record("Claude received typed form values", finished && grepl("mtcars", reply) && grepl("12", reply), substr(gsub("\n", " ", reply), 1, 120))
  shot("ask-form-reply")

  # 3) AskUserQuestion with the CLI's newer text / number kinds.
  stage <- "ask_question"
  q_seen <- FALSE; q_kinds <- character(); q_invalid <- FALSE; q_done <- FALSE
  send(paste(
    "Call the AskUserQuestion tool once with title \"Report setup\" and two questions:",
    "question \"How many plots?\" header \"Plots\" kind \"number\" min 1 max 5 defaultValue 2, and",
    "question \"What is the report title?\" header \"Title\" kind \"text\".",
    "Use the kind field exactly as given; if your AskUserQuestion schema has no kind field, say NO_KIND_FIELD in your reply.",
    "Then reply with exactly: ANSWERS=<the answers you received>. Use no other tools."))
  finished <- drive(function() {
    if (!q_done && isTRUE(safe("!!document.querySelector('[data-slot=ask-user-question]')", FALSE))) {
      q_seen <<- TRUE
      q_invalid <<- isTRUE(safe("!!document.querySelector('[data-ask-questions-invalid]')", FALSE))
      q_kinds <<- unlist(safe("[...document.querySelectorAll('[data-ask-kind]')].map(e=>e.dataset.askKind)", list()))
      shot("ask-question-card")
      if (isTRUE(safe("!!document.querySelector('[data-ask-number]')", FALSE)))
        type_into("document.querySelector('[data-ask-number]')", "3")
      if (isTRUE(safe("!!document.querySelector('[data-ask-text]')", FALSE)))
        type_into("document.querySelector('[data-ask-text]')", "Quarterly review")
      safe("(()=>{for(const g of document.querySelectorAll('[data-ask-kind=choice]')){const i=g.querySelector('input[type=radio],input[type=checkbox]');if(i&&!i.checked)i.click()}return true})()")
      Sys.sleep(0.3)
      js_click("document.querySelector('[data-ask-submit]')")
      q_done <<- TRUE
    }
    approve_tool_cards()
  }, done = function() q_done || !running())
  record("AskUserQuestion card rendered without fallback", q_seen && !q_invalid, paste("kinds:", paste(q_kinds, collapse = ",")))
  reply <- last_assistant()
  # CLI 2.1.328 does not expose `kind` to the model; the renderer for those kinds is
  # covered by fixture tests, so only a CLI that offers the field must render it.
  no_kind <- grepl("NO_KIND_FIELD", reply, fixed = TRUE)
  record("newer text/number kinds rendered (when the CLI offers them)",
         no_kind || all(c("number", "text") %in% q_kinds),
         if (no_kind) "not offered by this CLI" else paste("kinds:", paste(q_kinds, collapse = ",")))
  record("Claude received the answers", finished && q_done && nzchar(reply), substr(gsub("\n", " ", reply), 1, 120))
  shot("ask-question-reply")

  # 4) UI-first: an open decision should come back as a card, not a text question.
  stage <- "ui_first"
  card <- "none"
  send(paste(
    "For my quarterly report charts, should I use ggplot2, base graphics or plotly?",
    "I want to decide this together with you before anything is written."))
  finished <- drive(function() {
    approve_tool_cards()
    if (identical(card, "none")) {
      if (isTRUE(safe("!!document.querySelector('[data-slot=ask-user-question]')", FALSE))) {
        card <<- "AskUserQuestion"; shot("ui-first-card")
        safe("(()=>{const i=document.querySelector('[data-slot=ask-user-question] input[type=radio]');if(i)i.click();return true})()")
        Sys.sleep(0.3); js_click("document.querySelector('[data-ask-submit]')")
      } else if (isTRUE(safe("[...document.querySelectorAll('[data-slot=aui_a2ui_surface]')].some(s=>!s.innerText.includes('Submitted.')&&!s.innerText.includes('Cancelled.')&&s.querySelector('button'))", FALSE))) {
        card <<- "AskUserForm"; shot("ui-first-card")
        js_click("[...document.querySelectorAll('[data-slot=aui_a2ui_surface]')].at(-1).querySelector('button')")
      }
    }
  }, done = function() TRUE, timeout = 240)
  record("open decision asked through a UI card", !identical(card, "none"), paste("card:", card))
  shot("ui-first-reply")

  # 5) App-owned scroll-to-bottom button follows the native bottom rule.
  stage <- "scroll"
  safe("(()=>{const v=document.querySelector('[data-slot=aui_thread-viewport]');v.scrollTop=0;v.dispatchEvent(new Event('scroll'));return true})()")
  Sys.sleep(0.6)
  shown <- isTRUE(safe("(()=>{const b=document.querySelector('.aui-thread-scroll-to-bottom');return !!b&&!b.disabled})()", FALSE))
  js_click("document.querySelector('.aui-thread-scroll-to-bottom')")
  Sys.sleep(1)
  at_bottom <- isTRUE(safe("(()=>{const v=document.querySelector('[data-slot=aui_thread-viewport]');return v.scrollHeight-v.clientHeight-v.scrollTop<=8})()", FALSE))
  record("scroll-to-bottom shows when away and returns to bottom", shown && at_bottom, sprintf("shown=%s bottom=%s", shown, at_bottom))

  stage <- "final"
  bad_console <- Filter(function(e) !grepl("favicon", paste(unlist(e$args), collapse = " ")), console_errors)
  record("no console/runtime/window errors",
         length(bad_console) == 0L && length(runtime_errors) == 0L && length(window_errors()) == 0L,
         sprintf("console=%d runtime=%d window=%d", length(bad_console), length(runtime_errors), length(window_errors())))
  writeLines(c(
    "# Plugin acceptance (real addin, real Claude CLI)",
    paste0("- ", libline),
    vapply(names(results), function(n) sprintf("- [%s] %s %s", if (results[[n]]$pass) "x" else " ", n, results[[n]]$detail), ""),
    "- screenshots:", paste0("  - ", basename(shots))
  ), file.path(evidence, "ACCEPTANCE.md"))
  failed <- names(Filter(function(r) !r$pass, results))
  cat("PLUGIN_ACCEPTANCE_DONE pass=", length(results) - length(failed), "/", length(results),
      " failed=", paste(failed, collapse = ";"), " evidence=", evidence, "\n", sep = "")
}

main()
