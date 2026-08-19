#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
package_project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
arguments <- commandArgs(trailingOnly = TRUE)
permission_mode <- if (length(arguments)) arguments[[1L]] else "bypassPermissions"
valid_modes <- c("default", "acceptEdits", "bypassPermissions", "yolo")
if (!permission_mode %in% valid_modes) {
  stop("Unknown permission mode: ", permission_mode)
}
mode_index <- match(permission_mode, valid_modes)
port <- 9630L + mode_index
mode_slug <- gsub("[^A-Za-z0-9]+", "-", permission_mode)
stdout_path <- paste0("/tmp/claude-auto-edit-line-", mode_slug, ".out")
stderr_path <- paste0("/tmp/claude-auto-edit-line-", mode_slug, ".err")
unlink(c(stdout_path, stderr_path))
cat("VERIFY_PERMISSION_MODE=", permission_mode, "\n", sep = "")

edit_project <- tempfile("claude-auto-edit-line-")
dir.create(edit_project)
on.exit(unlink(edit_project, recursive = TRUE), add = TRUE)
target <- file.path(edit_project, "edit_auto_target.R")
writeLines(c(
  "# line 1",
  "# line 2",
  "# line 3",
  "target <- old",
  "# line 5"
), target)

failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-62s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(
  function(package_project, edit_project, port, home_library, permission_mode) {
    .libPaths(c(home_library, .libPaths()))
    setwd(package_project)
    Sys.setenv(
      AUI_PACKAGE_PROJECT = package_project,
      AUI_EDIT_PROJECT = edit_project,
      AUI_PERMISSION_MODE = permission_mode,
      AUI_PORT = port
    )
    source("tests/verify/claude_auto_edit_line_app.R", local = new.env())
  },
  args = list(
    package_project = package_project,
    edit_project = edit_project,
    port = port,
    home_library = home_library,
    permission_mode = permission_mode
  ),
  stdout = stdout_path,
  stderr = stderr_path
)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (index in seq_len(240L)) {
  if (!app$is_alive()) break
  logs <- if (file.exists(stderr_path)) readLines(stderr_path, warn = FALSE) else character()
  if (any(grepl("Listening on", logs, fixed = TRUE))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) {
  if (file.exists(stderr_path)) cat(tail(readLines(stderr_path, warn = FALSE), 30), sep = "\n")
  stop("Claude Auto-edit line fixture failed to start")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 900, height = 900)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)

console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (!identical(message$type, "error")) return()
  text <- paste(vapply(message$args %||% list(), function(arg) {
    as.character(arg$value %||% arg$description %||% "")
  }, character(1)), collapse = " ")
  console_errors <<- c(console_errors, paste0("console: ", text))
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  detail <- message$exceptionDetails
  text <- detail$exception$description %||% detail$text %||% "unknown exception"
  console_errors <<- c(console_errors, paste0("exception: ", text))
})

value <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}
wait_for <- function(script, timeout = 120, interval = 0.1) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(script), error = function(error) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
click_selector <- function(selector) {
  point_json <- value(sprintf(
    "(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2});})()",
    jsonlite::toJSON(selector, auto_unbox = TRUE)
  ))
  if (is.null(point_json)) return(FALSE)
  point <- jsonlite::fromJSON(point_json)
  browser$Input$dispatchMouseEvent(
    type = "mousePressed", x = point$x, y = point$y,
    button = "left", clickCount = 1L
  )
  browser$Input$dispatchMouseEvent(
    type = "mouseReleased", x = point$x, y = point$y,
    button = "left", clickCount = 1L
  )
  TRUE
}
press_enter <- function() {
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
}
card_numbers <- function() {
  encoded <- value("(function(){const cards=Array.from(document.querySelectorAll('.aui-shiny-tool')).filter(c=>c.querySelector('[data-arg-view=\"diff\"]') && (c.textContent||'').includes('edit_auto_target.R'));const card=cards[cards.length-1];if(!card)return null;return JSON.stringify(Array.from(card.querySelectorAll('[data-slot=\"diff-viewer-line-number\"]')).map(e=>(e.textContent||'').trim()).filter(Boolean));})()")
  if (is.null(encoded)) character() else unlist(jsonlite::fromJSON(encoded), use.names = FALSE)
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("widget mounted", wait_for("!!document.querySelector('.aui-root')", 30))
check("composer focused", click_selector(".aui-lexical-input[contenteditable='true']"))
Sys.sleep(0.2)
browser$Input$insertText(text = paste(
  "This is a controlled file-edit test.",
  "You MUST first use the Read tool on edit_auto_target.R, then use the Edit tool exactly once",
  "to replace the exact text `target <- old` with `target <- new`.",
  "Do not use Write or Bash. After the Edit succeeds, reply with exactly EDIT_DONE."
))
press_enter()

if (identical(permission_mode, "default")) {
  check(
    "Manual Edit approval appeared",
    wait_for("Array.from(document.querySelectorAll('button')).some(b=>/^Approve$/i.test((b.textContent||'').trim()))")
  )
  check(
    "Manual Edit card rendered before approval",
    wait_for("Array.from(document.querySelectorAll('.aui-shiny-tool')).some(c=>c.querySelector('[data-arg-view=\"diff\"]') && (c.textContent||'').includes('edit_auto_target.R'))")
  )
  preapproval_numbers <- card_numbers()
  check(
    "Manual pre-approval gutter is exactly line 4",
    length(preapproval_numbers) > 0L && all(preapproval_numbers == "4") &&
      !any(preapproval_numbers == "1"),
    paste(preapproval_numbers, collapse = ",")
  )
  clicked_approve <- value("(function(){const b=Array.from(document.querySelectorAll('button')).find(x=>/^Approve$/i.test((x.textContent||'').trim()));if(!b)return false;b.click();return true;})()")
  check("Manual Approve clicked", clicked_approve)
  check(
    "Manual approval result rendered",
    wait_for("!!document.querySelector('[data-approval-result=approved]')")
  )
}

check(
  "real Claude Edit card rendered",
  wait_for("Array.from(document.querySelectorAll('.aui-shiny-tool')).some(c=>c.querySelector('[data-arg-view=\"diff\"]') && (c.textContent||'').includes('edit_auto_target.R'))")
)
check(
  "real Claude turn completed",
  wait_for("!!document.querySelector('.aui-composer-send') && !document.querySelector('.aui-composer-cancel')")
)
if (!identical(permission_mode, "default")) {
  check(
    paste0(permission_mode, " completed without approval UI"),
    isTRUE(value("!document.querySelector('[data-approval-result]') && !Array.from(document.querySelectorAll('button')).some(b=>/^Approve$/i.test((b.textContent||'').trim()))"))
  )
}
numbers <- card_numbers()
check(
  paste0("real Claude ", permission_mode, " gutter is exactly line 4 and never 1"),
  length(numbers) > 0L && all(numbers == "4") && !any(numbers == "1"),
  paste(numbers, collapse = ",")
)
check(
  "real Claude changed only the intended target line",
  identical(
    readLines(target, warn = FALSE),
    c("# line 1", "# line 2", "# line 3", "target <- new", "# line 5")
  ),
  paste(readLines(target, warn = FALSE), collapse = " | ")
)
stdout_lines <- if (file.exists(stdout_path)) readLines(stdout_path, warn = FALSE) else character()
check(
  "real Claude app used requested permission mode",
  any(grepl(paste0("permission_mode=", permission_mode), stdout_lines, fixed = TRUE)),
  paste(grep("^permission_mode=", stdout_lines, value = TRUE), collapse = " | ")
)
check(
  "real Claude app used Home installed package",
  any(grepl(paste0("installed=", home_library, "/shinyAssistantUI"), stdout_lines, fixed = TRUE)),
  paste(grep("^installed=", stdout_lines, value = TRUE), collapse = " | ")
)
check(
  "zero browser console/runtime errors",
  length(console_errors) == 0L,
  if (length(console_errors)) paste(utils::head(unique(console_errors), 4), collapse = " | ") else "0 errors"
)

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop(
  "Claude Auto-edit line verification failed: ", paste(failures, collapse = ", ")
)
cat("CLAUDE_AUTO_EDIT_LINE_VERIFY_DONE mode=", permission_mode, "\n", sep = "")
