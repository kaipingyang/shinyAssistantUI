#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
port <- 9622L
stdout_path <- "/tmp/edit-diff-line-numbers.out"
stderr_path <- "/tmp/edit-diff-line-numbers.err"
unlink(c(stdout_path, stderr_path))

failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-58s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(
  function(project, port, home_library) {
    .libPaths(c(home_library, .libPaths()))
    setwd(project)
    suppressPackageStartupMessages(library(shiny))
    shiny::runApp(
      "tests/verify/edit_diff_line_numbers_app.R",
      host = "127.0.0.1", port = port, launch.browser = FALSE
    )
  },
  args = list(project = project, port = port, home_library = home_library),
  stdout = stdout_path,
  stderr = stderr_path
)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(120)) {
  if (!app$is_alive()) break
  logs <- if (file.exists(stderr_path)) readLines(stderr_path, warn = FALSE) else character()
  if (any(grepl("Listening on", logs, fixed = TRUE))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) {
  if (file.exists(stderr_path)) cat(tail(readLines(stderr_path, warn = FALSE), 30), sep = "\n")
  stop("Edit diff line browser fixture failed to start")
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
wait_for <- function(script, timeout = 15, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(script), error = function(e) FALSE))) return(TRUE)
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
  encoded <- value("(function(){const cards=Array.from(document.querySelectorAll('.aui-shiny-tool')).filter(c=>c.querySelector('[data-arg-view=\"diff\"]') && (c.textContent||'').includes('edit_line_target.R'));const card=cards[cards.length-1];if(!card)return null;return JSON.stringify(Array.from(card.querySelectorAll('[data-slot=\"diff-viewer-line-number\"]')).map(e=>(e.textContent||'').trim()).filter(Boolean));})()")
  if (is.null(encoded)) character() else unlist(jsonlite::fromJSON(encoded), use.names = FALSE)
}
click_history <- function() {
  point_json <- value("(function(){const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(x=>(x.textContent||'').includes('History Edit Line'));if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2});})()")
  if (is.null(point_json)) return(FALSE)
  point <- jsonlite::fromJSON(point_json)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y, button = "left", clickCount = 1L)
  TRUE
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("widget mounted", wait_for("!!document.querySelector('.aui-root')"))
check(
  "history session stub visible",
  wait_for("Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).some(e=>(e.textContent||'').includes('History Edit Line'))")
)

check("composer focused", click_selector(".aui-lexical-input[contenteditable='true']"))
Sys.sleep(0.2)
browser$Input$insertText(text = "run live edit")
press_enter()
check(
  "initial Auto-like Edit diff rendered before recovery",
  wait_for("Array.from(document.querySelectorAll('.aui-shiny-tool')).some(c=>c.querySelector('[data-arg-view=\"diff\"]') && (c.textContent||'').includes('edit_line_target.R'))")
)
initial_numbers <- card_numbers()
check(
  "unknown initial line renders no fake gutter",
  length(initial_numbers) == 0L,
  paste(initial_numbers, collapse = ",")
)
check(
  "recovery is delayed until after initial card assertion",
  !isTRUE(value("(document.body.innerText||'').includes('FILE_MUTATED_OLD_ABSENT')"))
)
check(
  "live Edit completed after removing old_string",
  wait_for("(document.body.innerText||'').includes('FILE_MUTATED_OLD_ABSENT')")
)
live_numbers <- card_numbers()
check(
  "live Edit gutter is exactly real line 4 and never 1",
  length(live_numbers) > 0 && all(live_numbers == "4") && !any(live_numbers == "1"),
  paste(live_numbers, collapse = ",")
)

check("history session clicked", click_history())
check(
  "history Edit restored after file was already changed",
  wait_for("(document.body.innerText||'').includes('FILE_MUTATED_OLD_ABSENT') && !(document.body.innerText||'').includes('LIVE_EDIT_COMPLETE')")
)
check(
  "history scoped Edit diff rendered",
  wait_for("Array.from(document.querySelectorAll('.aui-shiny-tool')).some(c=>c.querySelector('[data-arg-view=\"diff\"]') && (c.textContent||'').includes('edit_line_target.R'))")
)
history_numbers <- card_numbers()
check(
  "history Edit gutter remains exactly line 4 and never 1",
  length(history_numbers) > 0 && all(history_numbers == "4") && !any(history_numbers == "1"),
  paste(history_numbers, collapse = ",")
)

stdout_lines <- if (file.exists(stdout_path)) readLines(stdout_path, warn = FALSE) else character()
check(
  "browser app used Home installed package",
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
if (length(failures)) stop("Edit diff line verification failed: ", paste(failures, collapse = ", "))
cat("EDIT_DIFF_LINE_NUMBERS_VERIFY_DONE\n")
