#!/usr/bin/env Rscript

home_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
site_lib <- "/posit_share/site_library_u/4.4.3"
.libPaths(c(home_lib, site_lib, .libPaths()))
stopifnot(
  requireNamespace("callr", quietly = TRUE),
  requireNamespace("chromote", quietly = TRUE),
  requireNamespace("jsonlite", quietly = TRUE)
)

app_file <- normalizePath("tests/verify/lazy_tool_ui_app.R", mustWork = TRUE)
port <- 8874L
log_file <- tempfile("lazy-tool-ui-browser-", fileext = ".log")
proc <- callr::r_bg(function(app_file, port, home_lib) {
  .libPaths(c(home_lib, .libPaths()))
  suppressPackageStartupMessages(library(shiny))
  env <- new.env(parent = globalenv())
  sys.source(app_file, envir = env)
  shiny::runApp(env$app, host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(app_file = app_file, port = port, home_lib = home_lib),
stdout = log_file, stderr = log_file)

b <- NULL
on.exit({
  if (!is.null(b)) {
    try(b$close(), silent = TRUE)
    try(b$parent$get_browser()$get_process()$kill(), silent = TRUE)
  }
  try(proc$kill(), silent = TRUE)
}, add = TRUE)

ready <- FALSE
for (i in seq_len(60L)) {
  if (!proc$is_alive()) {
    stop("fixture app exited early:\n", paste(readLines(log_file, warn = FALSE), collapse = "\n"))
  }
  con <- try(url(sprintf("http://127.0.0.1:%d/", port), open = "rb", blocking = TRUE), silent = TRUE)
  if (!inherits(con, "try-error")) {
    try(close(con), silent = TRUE)
    ready <- TRUE
    break
  }
  Sys.sleep(0.25)
}
stopifnot(ready)

chromote::set_chrome_args(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
))
b <- chromote::ChromoteSession$new()
console_errors <- character()
runtime_errors <- character()
network_errors <- character()
`%||%` <- function(x, y) if (is.null(x)) y else x
b$Runtime$enable()
b$Network$enable()
b$Runtime$consoleAPICalled(callback_ = function(m) {
  if (identical(m$type, "error")) {
    console_errors <<- c(console_errors, paste(vapply(
      m$args, function(a) as.character(a$value %||% a$description %||% ""), character(1)
    ), collapse = " "))
  }
})
b$Runtime$exceptionThrown(callback_ = function(m) {
  runtime_errors <<- c(runtime_errors, as.character(
    m$exceptionDetails$exception$description %||% m$exceptionDetails$text %||% "unknown exception"
  ))
})
b$Network$loadingFailed(callback_ = function(m) {
  if (!identical(m$canceled, TRUE)) {
    network_errors <<- c(network_errors, as.character(m$errorText %||% "network failure"))
  }
})

b$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
b$Page$loadEventFired()
ev <- function(js) b$Runtime$evaluate(js, awaitPromise = TRUE, returnByValue = TRUE)$result$value
wait_for <- function(js, timeout = 20, interval = 0.2) {
  deadline <- Sys.time() + timeout
  repeat {
    value <- try(ev(js), silent = TRUE)
    if (!inherits(value, "try-error") && isTRUE(value)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
assert <- function(ok, label) {
  if (!isTRUE(ok)) stop("FAIL: ", label)
  cat("PASS:", label, "\n")
}
trigger_js <- function(text) sprintf(
  "Array.from(document.querySelectorAll('[data-slot=tool-fallback-trigger]')).find(e=>e.textContent.includes(%s))",
  jsonlite::toJSON(text, auto_unbox = TRUE)
)
request_count <- function(id = "lazy_request_count") as.integer(ev(sprintf(
  "Number((document.getElementById(%s)?.textContent||'0').trim())",
  jsonlite::toJSON(id, auto_unbox = TRUE)
)))

assert(wait_for("!!document.querySelector('.aui-root')"), "installed widget mounted")
assert(identical(ev("document.getElementById('installed-version').textContent.trim()"), "0.5.6"),
       "Home installed package version 0.5.6")

# Drive the actual composer so runtime callbacks are registered for this thread.
ev("document.querySelector('[contenteditable=true]').focus(); true")
b$Input$insertText(text = "run lazy fixture")
b$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
b$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
assert(wait_for(sprintf("!!(%s)", trigger_js("Bash(synthetic live result)")), 25), "live tool cards arrived")

live_trigger <- trigger_js("Bash(synthetic live result)")
write_trigger <- trigger_js("Write(report.md)")
ask_trigger <- trigger_js("AskUserQuestion")
assert(identical(ev(sprintf("(%s).getAttribute('aria-expanded')", live_trigger)), "false"),
       "large live tool starts collapsed")
assert(identical(request_count("live_request_count"), 0L), "collapsed live tool sent no chunk request")
assert(!isTRUE(ev("document.body.innerText.includes('LAZY-LIVE-LINE-00001')")),
       "collapsed live body is absent from DOM")
assert(identical(ev(sprintf("(%s).getAttribute('aria-expanded')", write_trigger)), "true"),
       "Write remains default-open")
assert(wait_for(sprintf("(%s).getAttribute('aria-expanded') === 'false'", ask_trigger)),
       "pending AskUserQuestion card is collapsed")
assert(wait_for("!!document.querySelector('[data-slot=ask-user-question]')"),
       "pending AskUserQuestion choices remain visible and operable outside the card")

# Opening causes the first request; scrolling near the bottom causes one next request.
ev(sprintf("(%s).click(); true", live_trigger))
assert(wait_for("!!document.querySelector('[data-lazy-tool-result]') && document.body.innerText.includes('LAZY-LIVE-LINE-00001')"),
       "opening loads first bounded chunk")
assert(wait_for("Number((document.getElementById('live_request_count')?.textContent||'0').trim()) >= 1"),
       "opening emitted one server request")
first_len <- as.integer(ev("document.querySelector('[data-lazy-tool-result]').innerText.length"))
ev("(function(){const e=document.querySelector('[data-slot=tool-result-scroll]');e.scrollTop=e.scrollHeight;e.dispatchEvent(new Event('scroll',{bubbles:true}));return true})()")
assert(wait_for("Number((document.getElementById('live_request_count')?.textContent||'0').trim()) >= 2"),
       "near-bottom scroll requested the next chunk")
assert(wait_for(sprintf("document.querySelector('[data-lazy-tool-result]').innerText.length > %d", first_len)),
       "next chunk extends one continuous scroll view")
assert(!isTRUE(ev("Array.from(document.querySelectorAll('[data-lazy-tool-result] button')).some(b=>/next|previous|page/i.test(b.textContent))")),
       "lazy result has no pagination controls")

# Continue forward until the 512 KiB client window evicts old chunks. The
# released-line spacer must preserve one continuous logical scroll surface.
for (expected_requests in 3:10) {
  assert(wait_for("!document.querySelector('[data-lazy-result-loading]')"),
         sprintf("chunk %d settled", expected_requests - 1L))
  ev("(function(){const e=document.querySelector('[data-slot=tool-result-scroll]');e.scrollTop=e.scrollHeight;e.dispatchEvent(new Event('scroll',{bubbles:true}));return true})()")
  assert(wait_for(sprintf("Number((document.getElementById('live_request_count')?.textContent||'0').trim()) >= %d", expected_requests)),
         sprintf("continuous scroll requested chunk %d", expected_requests))
}
assert(wait_for("!!document.querySelector('[data-lazy-result-spacer]')"),
       "client evicts old chunks after its retained window")
assert(isTRUE(ev("parseFloat(document.querySelector('[data-lazy-result-spacer]').style.height) > 0")),
       "eviction preserves released logical height")
assert(isTRUE(ev("(function(){const e=document.querySelector('[data-slot=tool-result-scroll]');return e.scrollHeight-e.scrollTop-e.clientHeight<=130})()")),
       "forward scrolling remains near the logical bottom after eviction")

# Open the collapsed card manually, then settle Ask locally. Settlement closes
# it once, and another manual reopen must remain effective.
ev(sprintf("(%s).click(); true", ask_trigger))
assert(wait_for(sprintf("(%s).getAttribute('aria-expanded') === 'true'", ask_trigger)),
       "pending AskUserQuestion card can be manually opened")
ev("(function(){const e=document.querySelector('[data-ask-option=\"Yes\"] input');if(!e)return false;e.click();return true})()")
ev("(function(){const b=document.querySelector('[data-ask-submit]');if(!b || b.disabled)return false;b.click();return true})()")
assert(wait_for(sprintf("(%s).getAttribute('aria-expanded') === 'false'", ask_trigger)),
       "answered AskUserQuestion closes once")
ev(sprintf("(%s).click(); true", ask_trigger))
assert(wait_for(sprintf("(%s).getAttribute('aria-expanded') === 'true'", ask_trigger)),
       "answered AskUserQuestion can be manually reopened")

# Restore history and prove its large result is also metadata-only until opened.
ev("(function(){const e=Array.from(document.querySelectorAll('*')).find(x=>x.textContent.trim()==='Lazy history');if(!e)return false;(e.closest('button')||e).click();return true})()")
history_trigger <- trigger_js("Bash(synthetic history result)")
assert(wait_for(sprintf("!!(%s)", history_trigger), 20), "history thread restored")
assert(identical(ev(sprintf("(%s).getAttribute('aria-expanded')", history_trigger)), "false"),
       "historical large tool starts collapsed")
assert(identical(request_count("history_request_count"), 0L), "history restore sent no collapsed chunk request")
assert(!isTRUE(ev("document.body.innerText.includes('LAZY-HISTORY-LINE-00001')")),
       "historical collapsed body is absent")
ev(sprintf("(%s).click(); true", history_trigger))
assert(wait_for("document.body.innerText.includes('LAZY-HISTORY-LINE-00001')"),
       "historical tool loads on demand")
assert(wait_for("Number((document.getElementById('history_request_count')?.textContent||'0').trim()) >= 1"),
       "historical open emitted a server request")

Sys.sleep(1)
all_errors <- c(console_errors, runtime_errors)
assert(length(all_errors) == 0L, "zero console/runtime errors")
assert(length(network_errors) == 0L, "zero network loading failures")
cat("SUMMARY lazy tool UI browser verification: PASS\n")
