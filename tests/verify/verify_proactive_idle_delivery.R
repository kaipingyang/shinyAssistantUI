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
log_file <- tempfile("plan91-proactive-", fileext = ".out")
err_file <- tempfile("plan91-proactive-", fileext = ".err")
on.exit(unlink(c(log_file, err_file)), add = TRUE)

failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(
  function(project, port, home_library) {
    setwd(project)
    .libPaths(c(home_library, .Library))
    Sys.setenv(PLAN91_HOME_LIBRARY = home_library)
    suppressPackageStartupMessages(library(shinyAssistantUI))
    cat("installed_path=", find.package("shinyAssistantUI"), "\n", sep = "")
    cat("installed_version=", as.character(packageVersion("shinyAssistantUI")), "\n", sep = "")
    shiny::runApp(
      "tests/verify/proactive_idle_fixture_app.R",
      host = "127.0.0.1",
      port = port,
      launch.browser = FALSE
    )
  },
  args = list(project = project, port = port, home_library = home_library),
  stdout = log_file,
  stderr = err_file
)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)

started <- FALSE
for (i in seq_len(240L)) {
  if (!app$is_alive()) break
  lines <- if (file.exists(err_file)) readLines(err_file, warn = FALSE) else character()
  if (any(grepl("Listening on", lines, fixed = TRUE))) {
    started <- TRUE
    break
  }
  Sys.sleep(0.1)
}
if (!started) {
  cat(tail(readLines(err_file, warn = FALSE), 30L), sep = "\n")
  stop("Plan 91 fixture failed to start", call. = FALSE)
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
wait_for <- function(script, timeout = 30, interval = 0.1) {
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
  ready <- wait_for("!!document.querySelector('.aui-lexical-input')", 20)
  check("composer ready", ready)
  value("document.querySelector('.aui-lexical-input').focus(); true")
  browser$Input$insertText(text = text)
  press_enter()
}
viewport_text <- function() {
  value("document.querySelector('[data-slot=aui_thread-viewport]')?.innerText || ''")
}
click_thread <- function(label) {
  script <- sprintf(
    paste0(
      "(()=>{const item=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')]",
      ".find(x=>(x.innerText||'').includes(%s));",
      "const trigger=item?.querySelector('[data-slot=aui_thread-list-item-trigger]');",
      "if(!trigger)return false;trigger.click();return true})()"
    ),
    jsonlite::toJSON(label, auto_unbox = TRUE)
  )
  wait_for(script, 20)
}
local_target_state <- function() {
  value(paste0(
    "(()=>{for(const key of Object.keys(localStorage)){",
    "if(!key.includes(':msgs:'))continue;const raw=localStorage.getItem(key)||'';",
    "if(raw.includes('PLAN91_TARGET_SETUP'))return JSON.stringify({key,raw});}",
    "return ''})()"
  ))
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("widget mounted", wait_for("!!document.querySelector('.aui-root')", 30))

send_text("PLAN91_TARGET_SETUP")
check(
  "target foreground completed",
  wait_for("document.querySelector('[data-slot=aui_thread-viewport]')?.innerText.includes('TARGET_INITIAL_LIVE')", 30)
)
check(
  "revision 1 pending tool snapshot applied",
  wait_for("(()=>{for(const k of Object.keys(localStorage)){const x=localStorage.getItem(k)||'';if(k.includes(':msgs:')&&x.includes('PLAN91_TARGET_SETUP')&&x.includes('PENDING_TOOL_RESULT'))return true;}return false})()", 30)
)

check(
  "new control thread created",
  isTRUE(value("(()=>{const x=document.querySelector('[data-slot=aui_thread-list-new]');if(!x)return false;x.click();return true})()"))
)
Sys.sleep(0.3)
send_text("PLAN91_CONTROL_SETUP")
check(
  "control thread selected and completed",
  wait_for("document.querySelector('[data-slot=aui_thread-viewport]')?.innerText.includes('CONTROL_SELECTED')", 30)
)

check(
  "unsolicited revision 2 persisted to inactive target",
  wait_for("(()=>{for(const k of Object.keys(localStorage)){const x=localStorage.getItem(k)||'';if(k.includes(':msgs:')&&x.includes('PLAN91_TARGET_SETUP')&&x.includes('COMPLETED_TOOL_RESULT')&&x.includes('UNSOLICITED_CRON_REPORT')&&!x.includes('PENDING_TOOL_RESULT'))return true;}return false})()", 30)
)
control_text <- viewport_text()
check("inactive update did not switch selected thread",
      grepl("CONTROL_SELECTED", control_text, fixed = TRUE) &&
        !grepl("UNSOLICITED_CRON_REPORT", control_text, fixed = TRUE),
      substr(control_text, 1L, 240L))

state_json <- local_target_state()
state <- if (nzchar(state_json)) jsonlite::fromJSON(state_json) else list(raw = "")
message_state <- jsonlite::fromJSON(state$raw, simplifyVector = FALSE)
ids <- vapply(message_state, function(message) as.character(message$id %||% ""), character(1))
check("same-ID tool result replaced without duplication", sum(ids == "h-tool") == 1L)

check("target thread selectable after inactive update", click_thread("PLAN91_TARGET_SETUP"))
report_visible <- wait_for(
  "(()=>{const t=document.querySelector('[data-slot=aui_thread-viewport]')?.innerText||'';return (t.match(/UNSOLICITED_CRON_REPORT/g)||[]).length===1&&!t.includes('PENDING_TOOL_RESULT')})()",
  30
)
target_text <- viewport_text()
check(
  "authoritative report visible exactly once",
  report_visible,
  substr(target_text, 1L, 600L)
)

browser$Page$reload()
browser$Page$loadEventFired()
check("widget remounted after reload", wait_for("!!document.querySelector('.aui-root')", 30))
if (!grepl("UNSOLICITED_CRON_REPORT", viewport_text(), fixed = TRUE)) {
  click_thread("PLAN91_TARGET_SETUP")
}
reload_visible <- wait_for(
  "(()=>{const t=document.querySelector('[data-slot=aui_thread-viewport]')?.innerText||'';return (t.match(/UNSOLICITED_CRON_REPORT/g)||[]).length===1})()",
  30
)
reload_text <- viewport_text()
check(
  "proactive snapshot restored after reload",
  reload_visible,
  substr(reload_text, 1L, 600L)
)

logs <- if (file.exists(log_file)) readLines(log_file, warn = FALSE) else character()
check(
  "fixture used Home installed package",
  any(grepl(
    paste0("installed_path=", home_library, "/shinyAssistantUI"),
    logs,
    fixed = TRUE
  )),
  paste(tail(logs, 5L), collapse = " | ")
)
check(
  "zero browser console errors or runtime exceptions",
  length(browser_errors) == 0L,
  if (length(browser_errors)) paste(unique(browser_errors), collapse = " | ") else "0 errors"
)

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) {
  stop("Plan 91 proactive fixture failed: ", paste(failures, collapse = ", "), call. = FALSE)
}
cat("PLAN91_PROACTIVE_IDLE_VERIFY_DONE\n")
