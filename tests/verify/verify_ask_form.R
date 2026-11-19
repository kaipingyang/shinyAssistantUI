#!/usr/bin/env Rscript
`%||%` <- function(x, y) if (is.null(x)) y else x
# Plan 166 browser gate: AskUserForm rendered and answered through real A2UI.
# Real pieces: installed package, AskUserForm stdio MCP subprocess, nanonext form
# endpoint, A2UI authority/transport/renderer, A2UI actions, headless Chromium.
suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
source("tests/verify/owned_process_cleanup.R")
source("tests/verify/window_error_capture.R")

main <- function() {
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  home_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  stopifnot(identical(normalizePath(.libPaths()[1], winslash = "/"), home_lib))
  evidence <- Sys.getenv("AUI_ASK_FORM_OUT", file.path(project, ".kiro/verification-evidence",
    paste0("ask-form-", format(Sys.time(), "%Y%m%d-%H%M%S"))))
  dir.create(evidence, recursive = TRUE, showWarnings = FALSE)
  form_url <- paste0("ipc://", tempfile("askform-", fileext = ".sock"))
  thread_file <- tempfile("askform-thread-")
  done_flag <- tempfile("askform-done-")
  port <- httpuv::randomPort()
  logs <- c(tempfile("askform-out-"), tempfile("askform-err-"))
  app <- browser <- NULL
  mcps <- list()
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit({
    for (p in mcps) try(if (p$is_alive()) p$kill_tree(), silent = TRUE)
    cleanup()
  }, add = TRUE)

  app <- callr::r_bg(function(project, home_lib, port) {
    .libPaths(c(home_lib, .libPaths()))
    setwd(project)
    library(shinyAssistantUI, lib.loc = home_lib)
    shiny::runApp("tests/verify/ask_form_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project = project, home_lib = home_lib, port = port),
  env = c(callr::rcmd_safe_env(), AUI_FORM_URL = form_url, AUI_THREAD_FILE = thread_file,
          AUI_DONE_FLAG = done_flag, R_LIBS_USER = home_lib),
  stdout = logs[[1]], stderr = logs[[2]], user_profile = FALSE, system_profile = FALSE)
  for (i in seq_len(200L)) {
    if (!app$is_alive()) break
    if (file.exists(logs[[2]]) && any(grepl("Listening on", readLines(logs[[2]], warn = FALSE), fixed = TRUE))) break
    Sys.sleep(0.1)
  }
  if (!app$is_alive()) stop(paste(tail(readLines(logs[[2]], warn = FALSE), 30), collapse = "\n"))

  script <- system.file("mcp", "ask_form_server.R", package = "shinyAssistantUI", lib.loc = home_lib)
  start_mcp <- function(thread_id) {
    env <- c(Sys.getenv(), CLAUDE_ADDIN_FORM_URL = form_url, CLAUDE_ADDIN_THREAD_ID = thread_id,
             CLAUDE_ADDIN_FORM_TIMEOUT_MS = "120000", R_LIBS = paste(.libPaths(), collapse = ":"))
    p <- processx::process$new(file.path(R.home("bin"), "Rscript"), c("--vanilla", script),
                               stdin = "|", stdout = "|", stderr = "|", env = env)
    mcps[[length(mcps) + 1L]] <<- p
    p
  }
  buffers <- new.env()
  send_rpc <- function(p, x) p$write_input(paste0(toJSON(x, auto_unbox = TRUE, null = "null"), "\n"))
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
    force(id)  # `id` may be the ask() call itself; send it before polling
    deadline <- Sys.time() + timeout
    repeat {
      msg <- poll_rpc(p, id)
      if (!is.null(msg)) return(msg)
      if (Sys.time() >= deadline) {
        cat("MCP_STDERR ", tryCatch(p$read_error_lines(), error = function(e) "?"), "\n")
        for (f in logs) if (file.exists(f)) cat("APP_LOG ", tail(readLines(f, warn = FALSE), 25), sep = "\n")
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
  ask <- function(p, args) {
    call_id <<- call_id + 1L
    send_rpc(p, list(jsonrpc = "2.0", id = call_id, method = "tools/call",
                     params = list(name = "AskUserForm", arguments = args)))
    call_id
  }
  result_json <- function(msg) fromJSON(msg$result$content[[1]]$text, simplifyVector = FALSE)

  chromote::set_chrome_args(unique(c(chromote::default_chrome_args(),
    "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
  browser <- ChromoteSession$new(width = 1000, height = 1000)
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
    if (!is.null(result$exceptionDetails)) {
      detail <- result$exceptionDetails$exception$description %||% result$exceptionDetails$text
      dump <- browser$Runtime$evaluate(
        "document.querySelector('[data-slot=aui_a2ui_surface]')?.outerHTML?.slice(0,4000) ?? 'no surface'",
        returnByValue = TRUE)$result$value
      stop("JS error at stage ", stage, ": ", detail, "\nSURFACE: ", dump, "\nCODE: ", substr(code, 1, 300),
           call. = FALSE)
    }
    result$result$value
  }
  wait <- function(code, timeout = 20) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(tryCatch(value(code), error = function(error) FALSE))) return(invisible(TRUE))
      if (!app$is_alive() || Sys.time() >= deadline) {
        cat("ASK_FORM_BODY ", tryCatch(value("document.body.innerText.slice(-1500)"), error = function(e) "?"), "\n")
        cat("ASK_FORM_SURFACE ", tryCatch(value("document.querySelector('[data-slot=aui_a2ui_surface]')?.outerHTML?.slice(0,3000)"), error = function(e) "?"), "\n")
        if (file.exists(logs[[2]])) cat(tail(readLines(logs[[2]], warn = FALSE), 25), sep = "\n")
        stop("Timed out at stage ", stage, ": ", code, call. = FALSE)
      }
      Sys.sleep(0.05)
    }
  }
  q <- function(x) toJSON(x, auto_unbox = TRUE)
  point_of <- function(js_element) value(sprintf(
    "(()=>{const e=%s;if(!e)return null;e.scrollIntoView({block:'center',behavior:'instant'});const r=e.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()",
    js_element))
  mouse_click <- function(js_element) {
    p <- point_of(js_element)
    if (is.null(p)) stop("Missing element at stage ", stage, ": ", js_element, call. = FALSE)
    Sys.sleep(0.1)
    p <- point_of(js_element)
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = p$x, y = p$y)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L)
  }
  key <- function(key, code, vk, modifiers = 0L) {
    browser$Input$dispatchKeyEvent(type = "keyDown", key = key, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = key, code = code, windowsVirtualKeyCode = vk, modifiers = modifiers)
  }
  # Element helpers scoped to the newest form surface.
  surf <- "[...document.querySelectorAll('[data-slot=aui_a2ui_surface]')].at(-1)"
  control <- function(name) sprintf(
    "(%s)?.querySelector('[name=\"/values/%s\"],textarea[name=\"/values/%s\"]')", surf, name, name)
  option <- function(name, value) sprintf(
    "(%s)?.querySelector('input[data-aui-field-name=\"/values/%s\"][value=\"%s\"],input[name=\"/values/%s\"][value=\"%s\"]')",
    surf, name, value, name, value)
  button <- function(text) sprintf(
    "[...(%s)?.querySelectorAll('button')??[]].find(b=>(b.innerText||'').trim()===%s)", surf, q(text))
  type_into <- function(js_element, text) {
    mouse_click(js_element)
    key("a", "KeyA", 65L, 2L)
    browser$Input$insertText(text = text)
  }
  shots <- character()
  shot <- function(name) {
    Sys.sleep(0.3)
    path <- file.path(evidence, sprintf("%02d-%s.png", length(shots) + 1L, name))
    browser$screenshot(path, show = FALSE)
    shots <<- c(shots, path)
  }
  checks <- character()

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  wait("!!document.querySelector('.aui-lexical-input[contenteditable=true]')")
  start_turn <- function(text) {
    unlink(thread_file)
    mouse_click("document.querySelector('.aui-lexical-input[contenteditable=true]')")
    browser$Input$insertText(text = text)
    key("Enter", "Enter", 13L)
    wait("document.body.innerText.includes('Let me ask you a few things.')")
    deadline <- Sys.time() + 10
    while (Sys.time() < deadline) {
      ids <- if (file.exists(thread_file)) readLines(thread_file, warn = FALSE) else character()
      if (length(ids) == 2L) return(ids[[1L]])
      Sys.sleep(0.05)
    }
    stop("thread id not written")
  }
  finish_turn <- function() {
    writeLines("done", done_flag)
    wait("!document.querySelector('.aui-composer-cancel')", 15)
  }

  form_args <- list(
    title = "Analysis settings",
    fields = list(
      list(name = "dataset", label = "Dataset", type = "select", choices = list("iris", "mtcars"),
           default = "mtcars", required = TRUE),
      list(name = "n", label = "Rows", type = "number", default = "10"),
      list(name = "cols", label = "Columns", type = "multiselect", choices = list("mpg", "cyl", "hp"),
           default = "mpg"),
      list(name = "note", label = "Note", type = "textarea", help = "Anything else?"),
      list(name = "plot", label = "Plot it", type = "checkbox", default = "false"),
      list(name = "since", label = "Since", type = "date", default = "2026-01-31"),
      list(name = "who", label = "Analyst", type = "text", required = TRUE)
    ),
    submit_label = "Run analysis"
  )

  # 1) Render, validation error, submit with typed values, read-only summary.
  stage <- "submit"
  thread_id <- start_turn("settings please")
  mcp <- start_mcp(thread_id)
  init_mcp(mcp)
  id <- ask(mcp, form_args)
  wait(sprintf("!!%s && (%s).innerText.includes('Analysis settings') && !!%s", surf, surf, button("Run analysis")))
  stopifnot(is.null(poll_rpc(mcp, id)))
  stopifnot(isTRUE(value(sprintf("(%s).value==='10'", control("n")))))
  checks <- c(checks, "renders_all_field_types")
  shot("form-pending")

  mouse_click(button("Run analysis"))                       # Analyst is required and empty
  wait(sprintf("(%s).innerText.includes('Please fill in Analyst')", surf))
  stopifnot(is.null(poll_rpc(mcp, id)))
  checks <- c(checks, "required_field_blocks_submit")
  shot("form-required-error")

  type_into(control("who"), "Ada")
  type_into(control("n"), "25")
  type_into(control("note"), "Use the clean version")
  mouse_click(option("cols", "hp"))
  mouse_click(control("plot"))
  mouse_click(option("dataset", "iris"))
  mouse_click(button("Run analysis"))
  msg <- await_rpc(mcp, id, 20)
  result <- result_json(msg)
  stopifnot(isTRUE(result$submitted), identical(result$values$who, "Ada"),
            identical(result$values$n, 25L) || identical(result$values$n, 25),
            identical(result$values$dataset, "iris"),
            setequal(unlist(result$values$cols), c("mpg", "hp")),
            isTRUE(result$values$plot), identical(result$values$note, "Use the clean version"),
            identical(result$values$since, "2026-01-31"))
  wait(sprintf("(%s).innerText.includes('Submitted.') && (%s).innerText.includes('Analyst: Ada') && !(%s)",
               surf, surf, button("Run analysis")))
  checks <- c(checks, "submits_typed_values_and_shows_summary")
  shot("form-submitted")

  # 1b) Field options: placeholder, pattern, number bounds, dropdown, other value.
  stage <- "field-options"
  countries <- c("China", "Japan", "USA", "UK", "France", "Germany", "Italy", "Spain", "India", "Brazil")
  id <- ask(mcp, list(title = "Study options", submit_label = "Save", fields = list(
    list(name = "study", label = "Study id", type = "text", required = TRUE, placeholder = "bgb_xxxx_101",
         pattern = "^[a-z0-9_]+$", pattern_hint = "lowercase letters, digits and _"),
    list(name = "cycle", label = "Cycle days", type = "number", min = 7, max = 56, step = 7),
    list(name = "country", label = "Country", type = "select", choices = as.list(countries), default = "Japan"),
    list(name = "hemo", label = "Tumour type", type = "select", choices = list("IO-Solid", "Solid", "Hemo"),
         allow_other = TRUE)
  )))
  wait(sprintf("(%s)?.innerText.includes('Study options') && !!%s", surf, button("Save")))
  stopifnot(isTRUE(value(sprintf("(%s).getAttribute('placeholder')==='bgb_xxxx_101'", control("study")))))
  stopifnot(isTRUE(value(sprintf("(%s).tagName==='SELECT' && (%s).value==='Japan'", control("country"), control("country")))))
  stopifnot(isTRUE(value(sprintf("!!(%s).querySelector('[name=\"/other/hemo\"]')", surf))))
  type_into(control("study"), "BGB X")
  type_into(control("cycle"), "30")
  mouse_click(button("Save"))
  wait(sprintf("(%s).innerText.includes('lowercase letters, digits and _') && (%s).innerText.includes('multiple of 7')", surf, surf))
  stopifnot(is.null(poll_rpc(mcp, id)))
  checks <- c(checks, "pattern_and_step_errors_block_submit")
  shot("form-field-option-errors")
  type_into(control("study"), "bgb_x_101")
  type_into(control("cycle"), "28")
  mouse_click(control("country"))
  value(sprintf("(()=>{const s=%s;s.value='India';s.dispatchEvent(new Event('change',{bubbles:true}));return true})()", control("country")))
  key("Escape", "Escape", 27L)
  type_into(sprintf("(%s).querySelector('[name=\"/other/hemo\"]')", surf), "Lymphoma")
  mouse_click(button("Save"))
  msg <- await_rpc(mcp, id, 20)
  result <- result_json(msg)
  stopifnot(isTRUE(result$submitted), identical(result$values$study, "bgb_x_101"),
            identical(as.numeric(result$values$cycle), 28), identical(result$values$country, "India"),
            identical(result$values$hemo, "Lymphoma"))
  checks <- c(checks, "dropdown_and_other_value_submit")
  shot("form-field-options-submitted")

  # 2) Cancel button.
  stage <- "cancel"
  id <- ask(mcp, list(title = "Confirm delete", fields = list(list(name = "ok", type = "checkbox"))))
  wait(sprintf("(%s)?.innerText.includes('Confirm delete') && !!%s", surf, button("Cancel")))
  mouse_click(button("Cancel"))
  result <- result_json(await_rpc(mcp, id, 20))
  stopifnot(isFALSE(result$submitted), identical(result$reason, "user"))
  wait(sprintf("(%s).innerText.includes('Cancelled.')", surf))
  checks <- c(checks, "cancel_button_cancels")

  # 3) Invalid spec is reported to Claude without showing anything.
  stage <- "invalid"
  surfaces_before <- value("document.querySelectorAll('[data-slot=aui_a2ui_surface]').length")
  msg <- await_rpc(mcp, ask(mcp, list(title = "Bad", fields = list(list(name = "x", type = "select")))), 20)
  stopifnot(isTRUE(msg$result$isError), grepl("choices", msg$result$content[[1]]$text, fixed = TRUE),
            identical(value("document.querySelectorAll('[data-slot=aui_a2ui_surface]').length"), surfaces_before))
  checks <- c(checks, "invalid_spec_reported")
  finish_turn()

  # 4) Without an active run the form is unavailable.
  stage <- "no-run"
  result <- result_json(await_rpc(mcp, ask(mcp, form_args), 20))
  stopifnot(isFALSE(result$submitted), identical(result$reason, "unavailable"))
  checks <- c(checks, "no_active_run_unavailable")

  # 5) Stop cancels a pending form.
  stage <- "stop"
  start_turn("second turn")
  id <- ask(mcp, list(title = "Stop me", fields = list(list(name = "x", type = "text"))))
  wait(sprintf("(%s)?.innerText.includes('Stop me') && !!%s", surf, button("Submit")))
  mouse_click("document.querySelector('.aui-composer-cancel')")
  result <- result_json(await_rpc(mcp, id, 20))
  stopifnot(isFALSE(result$submitted), identical(result$reason, "stopped"))
  wait(sprintf("(%s).innerText.includes('Stopped before the form was submitted.')", surf))
  checks <- c(checks, "stop_cancels_pending_form")
  shot("form-stopped")

  stage <- "final"
  stopifnot(length(console_errors) == 0L, length(runtime_errors) == 0L, length(window_errors()) == 0L)
  writeLines(c(
    "# AskUserForm over A2UI — headless Chromium acceptance",
    paste0("- package: ", as.character(packageVersion("shinyAssistantUI", lib.loc = home_lib))),
    paste0("- checks passed: ", paste(checks, collapse = ", ")),
    paste0("- console errors: ", length(console_errors), "; runtime exceptions: ", length(runtime_errors)),
    "- screenshots:", paste0("  - ", basename(shots))
  ), file.path(evidence, "ACCEPTANCE.md"))
  cat("ASK_FORM_DONE checks=", paste(checks, collapse = ","), " console_errors=", length(console_errors),
      " evidence=", evidence, "\n", sep = "")
}

main()
