#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
`%||%` <- function(x, y) if (is.null(x)) y else x

args_all <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", args_all, value = TRUE)
script_path <- if (length(file_arg)) {
  normalizePath(sub("^--file=", "", file_arg[[1L]]))
} else {
  normalizePath("tests/verify/verify_claude_reasoning_terminal.R")
}
PROJ <- normalizePath(file.path(dirname(script_path), "../.."))
HOME_LIBRARY <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
EXPECTED_VERSION <- unname(read.dcf(file.path(PROJ, "DESCRIPTION"), fields = "Version")[[1L]])
PORT <- httpuv::randomPort()
LOG_OUT <- tempfile(paste0("claude-reasoning-terminal-", Sys.getpid(), "-"), fileext = ".out")
LOG_ERR <- tempfile(paste0("claude-reasoning-terminal-", Sys.getpid(), "-"), fileext = ".err")
on.exit(unlink(c(LOG_OUT, LOG_ERR)), add = TRUE)

proc <- callr::r_bg(function(proj, port, home_library) {
  .libPaths(c(home_library, .libPaths()))
  suppressMessages({ library(shiny); library(shinyAssistantUI) })
  cat("installed=", find.package("shinyAssistantUI"), "\n", sep = "")
  cat("installed_version=", as.character(packageVersion("shinyAssistantUI")), "\n", sep = "")
  app <- source(
    file.path(proj, "tests/verify/claude_reasoning_terminal_app.R"),
    local = new.env()
  )$value
  shiny::runApp(app, host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = PORT, home_library = HOME_LIBRARY), stdout = LOG_OUT, stderr = LOG_ERR)
on.exit(try(proc$kill(), silent = TRUE), add = TRUE)

for (i in seq_len(120L)) {
  if (!proc$is_alive()) break
  if (file.exists(LOG_ERR) &&
      any(grepl("Listening on", readLines(LOG_ERR, warn = FALSE)))) break
  Sys.sleep(0.1)
}
if (!proc$is_alive()) {
  cat("BOOT FAIL\n")
  if (file.exists(LOG_ERR)) cat(tail(readLines(LOG_ERR, warn = FALSE), 30), sep = "\n")
  quit(status = 1)
}

chromote::set_chrome_args(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
))
browser <- chromote::ChromoteSession$new()
on.exit(try(browser$close(), silent = TRUE), add = TRUE)
errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) {
    errors <<- c(errors, paste(vapply(message$args, function(arg) {
      as.character(arg$value %||% arg$description %||% "")
    }, character(1)), collapse = " "))
  }
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  details <- message$exceptionDetails
  errors <<- c(
    errors,
    paste("EXC:", details$exception$description %||% details$text %||% "")
  )
})

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT))
browser$Page$loadEventFired()
ev <- function(js) browser$Runtime$evaluate(js)$result$value
wait_until <- function(js, timeout = 10) {
  deadline <- Sys.time() + timeout
  repeat {
    value <- tryCatch(ev(js), error = function(e) FALSE)
    if (isTRUE(value)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.1)
  }
}
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-48s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) stop(name, call. = FALSE)
}
send_text <- function(text) {
  focused <- ev(paste0(
    "(function(){const e=document.querySelector('#chat .aui-lexical-input",
    "[contenteditable=\\\"true\\\"]');if(!e)return false;e.focus();return true})()"
  ))
  check(paste("composer focused for", text), focused)
  browser$Input$insertText(text = text)
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
}

check(
  "installed package composer mounted",
  wait_until("!!document.querySelector('#chat .aui-lexical-input[contenteditable=true]')")
)
send_text("trigger missing final")
check(
  "Reasoning DOM remains visible",
  wait_until("!!document.querySelector('#chat [data-slot=aui_chain-of-thought]')")
)
check(
  "generic continuation is a visible user bubble",
  wait_until(paste0(
    "Array.from(document.querySelectorAll('#chat [data-role=user]'))",
    ".some(e=>e.innerText.includes('Please provide the final user-visible response now.'))"
  ))
)
check(
  "thinking-only turn recovers final visible text",
  wait_until(paste0(
    "Array.from(document.querySelectorAll('#chat [data-role=assistant]'))",
    ".at(-1)?.innerText.includes('Recovered final answer.')"
  ))
)
check(
  "thinking-only recovery shows no terminal error",
  isTRUE(ev("!document.querySelector('#chat').innerText.includes('⚠ Error:')"))
)
check(
  "recovered turn leaves running state",
  wait_until(paste0(
    "!!document.querySelector('#chat .aui-composer-send') && ",
    "!document.querySelector('#chat .aui-composer-cancel') && ",
    "document.querySelector('#chat .aui-lexical-input')?.getAttribute('contenteditable')==='true'"
  ))
)

send_text("control final")
check(
  "composer accepts a normal message after recovery",
  wait_until(paste0(
    "Array.from(document.querySelectorAll('#chat [data-role=user]'))",
    ".some(e=>e.innerText.includes('control final'))"
  ))
)
check(
  "control turn renders normal final text",
  wait_until(paste0(
    "Array.from(document.querySelectorAll('#chat [data-role=assistant]'))",
    ".at(-1)?.innerText.includes('Recovered final answer.')"
  ))
)
check(
  "control turn also settles running state",
  wait_until(paste0(
    "!!document.querySelector('#chat .aui-composer-send') && ",
    "!document.querySelector('#chat .aui-composer-cancel')"
  ))
)
logs <- if (file.exists(LOG_OUT)) readLines(LOG_OUT, warn = FALSE) else character()
installed_path <- sub("^installed=", "", grep("^installed=", logs, value = TRUE))
installed_version <- sub(
  "^installed_version=", "", grep("^installed_version=", logs, value = TRUE)
)
check(
  "fixture uses Home installed package",
  length(installed_path) == 1L &&
    identical(installed_path[[1L]], file.path(HOME_LIBRARY, "shinyAssistantUI")),
  paste(installed_path, collapse = " | ")
)
check(
  "installed package version matches source",
  length(installed_version) == 1L && identical(installed_version[[1L]], EXPECTED_VERSION),
  paste("expected=", EXPECTED_VERSION, "installed=", paste(installed_version, collapse = " | "))
)
Sys.sleep(0.5)
check(
  "zero browser console/runtime errors",
  length(errors) == 0L,
  if (length(errors)) paste(unique(errors), collapse = " | ") else ""
)

cat("CLAUDE_REASONING_TERMINAL_VERIFY_DONE\n")
try(browser$close(), silent = TRUE)
try(proc$kill(), silent = TRUE)
try(chromote::default_chromote_object()$get_browser()$get_process()$kill(), silent = TRUE)
unlink(c(LOG_OUT, LOG_ERR))
