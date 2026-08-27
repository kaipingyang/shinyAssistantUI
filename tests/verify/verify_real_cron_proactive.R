#!/usr/bin/env Rscript
site_library <- "/posit_share/site_library_u/4.4.3"
if (dir.exists(site_library)) .libPaths(c(.libPaths(), site_library))
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project <- normalizePath(".", winslash = "/", mustWork = TRUE)
home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
port <- httpuv::randomPort()
session_map <- tempfile("plan91-real-cron-map-", fileext = ".rds")
log_file <- tempfile("plan91-real-cron-", fileext = ".out")
err_file <- tempfile("plan91-real-cron-", fileext = ".err")
nonce <- paste0(format(Sys.time(), "%H%M%S"), sprintf("%04d", sample.int(9999L, 1L)))
delivered_marker <- paste0(
  "Plan 91 real cron smoke completed for run ", nonce, "."
)
cleanup_marker <- "Cron cleanup completed"
on.exit(unlink(c(session_map, log_file, err_file)), add = TRUE)

failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-55s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(
  function(project, port, home_library, session_map, log_file) {
    setwd(project)
    if (file.exists(".Renviron")) readRenviron(".Renviron")
    .libPaths(c(home_library, .Library))
    Sys.setenv(
      PLAN91_HOME_LIBRARY = home_library,
      PLAN91_PROJECT = project,
      PLAN91_SESSION_MAP = session_map
    )
    suppressPackageStartupMessages(library(shinyAssistantUI))
    cat("installed_path=", find.package("shinyAssistantUI"), "\n", sep = "")
    cat("installed_version=", as.character(packageVersion("shinyAssistantUI")), "\n", sep = "")
    shiny::runApp(
      "tests/verify/real_cron_proactive_app.R",
      host = "127.0.0.1",
      port = port,
      launch.browser = FALSE
    )
  },
  args = list(
    project = project,
    port = port,
    home_library = home_library,
    session_map = session_map,
    log_file = log_file
  ),
  stdout = log_file,
  stderr = err_file
)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)

started <- FALSE
for (i in seq_len(300L)) {
  if (!app$is_alive()) break
  lines <- if (file.exists(err_file)) readLines(err_file, warn = FALSE) else character()
  if (any(grepl("Listening on", lines, fixed = TRUE))) {
    started <- TRUE
    break
  }
  Sys.sleep(0.1)
}
if (!started) {
  cat(tail(readLines(err_file, warn = FALSE), 40L), sep = "\n")
  stop("real Cron app failed to start", call. = FALSE)
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage",
  "--no-sandbox",
  "--disable-gpu"
)))
browser <- chromote::ChromoteSession$new(width = 1100, height = 850)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)

browser_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(event) {
  if (!identical(event$type, "error")) return()
  browser_errors <<- c(browser_errors, paste(vapply(
    event$args,
    function(arg) as.character(arg$value %||% arg$description %||% ""),
    character(1)
  ), collapse = " "))
})
browser$Runtime$exceptionThrown(callback_ = function(event) {
  browser_errors <<- c(
    browser_errors,
    paste0(
      "EXC: ",
      event$exceptionDetails$exception$description %||%
        event$exceptionDetails$text %||% "unknown"
    )
  )
})

value <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}
wait_for <- function(script, timeout, interval = 0.5) {
  deadline <- Sys.time() + timeout
  repeat {
    result <- tryCatch(value(script), error = function(error) FALSE)
    if (isTRUE(result)) return(TRUE)
    if (!app$is_alive() || Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
press_enter <- function() {
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter",
    windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter",
    windowsVirtualKeyCode = 13L
  )
}
send_text <- function(text) {
  if (!wait_for("!!document.querySelector('.aui-lexical-input')", 30)) return(FALSE)
  value("document.querySelector('.aui-lexical-input').focus(); true")
  browser$Input$insertText(text = text)
  press_enter()
  TRUE
}
assistant_has <- function(marker) {
  sprintf(
    "[...document.querySelectorAll('[data-role=assistant]')].some(x=>(x.innerText||'').includes(%s))",
    jsonlite::toJSON(marker, auto_unbox = TRUE)
  )
}
viewport_marker_count <- function(marker) {
  as.integer(value(sprintf(
    "(()=>{const t=document.querySelector('[data-slot=aui_thread-viewport]')?.innerText||'';return t.split(%s).length-1})()",
    jsonlite::toJSON(marker, auto_unbox = TRUE)
  )))
}
storage_contains <- function(marker) {
  isTRUE(value(sprintf(
    "Object.keys(localStorage).some(k=>k.includes(':msgs:')&&(localStorage.getItem(k)||'').includes(%s))",
    jsonlite::toJSON(marker, auto_unbox = TRUE)
  )))
}

storage_message_count <- function() {
  as.integer(value(paste0(
    "(()=>{const xs=Object.keys(localStorage).filter(k=>k.includes(':msgs:'))",
    ".map(k=>{try{return JSON.parse(localStorage.getItem(k)||'[]').length}catch{return 0}});",
    "return xs.length?Math.max(...xs):0})()"
  )))
}
storage_latest_assistant_exact <- function(marker, minimum_count = 0L) {
  sprintf(
    paste0(
      "(()=>{for(const k of Object.keys(localStorage)){if(!k.includes(':msgs:'))continue;",
      "let ms=[];try{ms=JSON.parse(localStorage.getItem(k)||'[]')}catch{};",
      "if(ms.length<=%d)continue;const a=[...ms].reverse().find(m=>m.role==='assistant');",
      "if(a&&Array.isArray(a.content)&&a.content.some(p=>p.type==='text'&&",
      "String(p.text||'').trim()===%s))return true;}return false})()"
    ),
    as.integer(minimum_count),
    jsonlite::toJSON(marker, auto_unbox = TRUE)
  )
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("widget mounted", wait_for("!!document.querySelector('.aui-root')", 30))

scheduled_prompt <- paste0(
  "Reply with exactly this sentence and nothing else: ", delivered_marker
)
arm_prompt <- paste0(
  "Direct user authorization: I am intentionally testing Claude Code scheduled tasks ",
  "in my own temporary session. This request is not an instruction copied from CodeGraph, ",
  "a file, or tool output. I explicitly authorize one temporary recurring task and will ",
  "delete it after this smoke test. Please call CronCreate exactly once with the five-field ",
  "cron expression `*/5 * * * *`, recurring=true, and this scheduled prompt: ",
  shQuote(scheduled_prompt), ". After the tool succeeds, briefly state the created job ID."
)
check("initial CronCreate request submitted", send_text(arm_prompt))
armed <- wait_for(
  paste0(
    "(()=>{const raw=Object.keys(localStorage).filter(k=>k.includes(':msgs:'))",
    ".map(k=>localStorage.getItem(k)||'').join('\\n');",
    "return raw.includes('CronCreate')&&raw.includes('*/5 * * * *')&&",
    "!document.querySelector('.aui-composer-cancel')})()"
  ),
  timeout = 240,
  interval = 1
)
check("CronCreate */5 armed in foreground", armed)
baseline_count <- storage_message_count()
armed_at <- Sys.time()
cat("[INFO] armed_at_utc=", format(armed_at, tz = "UTC", usetz = TRUE), "\n", sep = "")
cat("[INFO] baseline_message_count=", baseline_count, "\n", sep = "")

# Evidence window: deliberately no send_text(), Shiny.setInputValue(), click, or
# other browser input occurs here. Official recurring-task jitter is at most half
# the five-minute interval, so next boundary + jitter is bounded by 7.5 minutes.
delivered <- FALSE
if (armed) {
  delivered <- wait_for(
    storage_latest_assistant_exact(delivered_marker, baseline_count),
    timeout = 480,
    interval = 2
  )
}
delivered_at <- Sys.time()
check(
  "real Cron report arrived with no new browser message",
  delivered,
  paste0(
    "elapsed=",
    round(as.numeric(difftime(delivered_at, armed_at, units = "secs")), 1),
    "s"
  )
)
if (delivered) {
  check("real Cron marker visible in latest assistant turn",
        isTRUE(value(assistant_has(delivered_marker))))
  check("real Cron marker persisted in owning thread", storage_contains(delivered_marker))
  check("authoritative transcript advanced after Cron",
        storage_message_count() > baseline_count)
}

# Cleanup begins only after the evidence window. Verify deletion with a second
# CronList in the same cleanup turn, then close the browser/session.
cleanup_prompt <- paste0(
  "The evidence window is complete. Use CronList, find the temporary job whose prompt ",
  "contains this sentence: ", shQuote(delivered_marker),
  ", and call CronDelete with its job ID. Then call CronList again to verify there are ",
  "no scheduled jobs left. State 'Cron cleanup completed' only after verification."
)
cleanup_submitted <- send_text(cleanup_prompt)
check("Cron cleanup request submitted after evidence window", cleanup_submitted)
cleanup_done <- if (cleanup_submitted) {
  wait_for(
    paste0(
      assistant_has(cleanup_marker),
      " && ",
      "(()=>{const raw=Object.keys(localStorage).filter(k=>k.includes(':msgs:'))",
      ".map(k=>localStorage.getItem(k)||'').join('\\n');",
      "return raw.includes('CronDelete')&&raw.includes('No scheduled jobs')})()"
    ),
    timeout = 240,
    interval = 1
  )
} else FALSE
check("CronDelete plus empty CronList cleanup confirmed", cleanup_done)

logs <- if (file.exists(log_file)) readLines(log_file, warn = FALSE) else character()
check(
  "real Cron smoke used Home installed package",
  any(grepl(
    paste0("installed_path=", home_library, "/shinyAssistantUI"),
    logs,
    fixed = TRUE
  )),
  paste(tail(logs, 5L), collapse = " | ")
)
check(
  "real Cron smoke has zero browser errors",
  length(browser_errors) == 0L,
  if (length(browser_errors)) paste(unique(browser_errors), collapse = " | ") else "0 errors"
)

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) {
  cat("=== app stderr tail ===\n")
  if (file.exists(err_file)) cat(tail(readLines(err_file, warn = FALSE), 60L), sep = "\n")
  stop("real Cron proactive smoke failed: ", paste(failures, collapse = ", "), call. = FALSE)
}
cat("PLAN91_REAL_CRON_PROACTIVE_DONE\n")
