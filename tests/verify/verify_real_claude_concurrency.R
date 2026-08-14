#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
MAP <- tempfile("plan67-real-map-", fileext = ".rds")
INFO <- tempfile("plan67-real-info-", fileext = ".rds")
LOG <- tempfile("plan67-real-", fileext = ".out")
ERR <- tempfile("plan67-real-", fileext = ".err")
on.exit(unlink(c(MAP, INFO, LOG, ERR)), add = TRUE)

chromote::set_chrome_args(c(chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"))
errors <- character()
start_app <- function(phase, port) {
  callr::r_bg(function(proj, map, info, phase, port, log_marker) {
    setwd(proj)
    if (file.exists(".Renviron")) readRenviron(".Renviron")
    Sys.setenv(PLAN67_REAL_PROJECT = proj, PLAN67_REAL_MAP = map,
               PLAN67_REAL_INFO = info, PLAN67_REAL_PHASE = phase)
    suppressMessages({ library(shiny); library(shinyAssistantUI); library(ClaudeAgentSDK) })
    cat("installed=", find.package("shinyAssistantUI"), "\n", sep = "")
    shiny::runApp("tests/verify/real_claude_concurrency_app.R",
                  host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(proj = PROJ, map = MAP, info = INFO, phase = phase,
                 port = port, log_marker = phase), stdout = LOG, stderr = ERR)
}
wait_app <- function(proc) {
  for (i in seq_len(240L)) {
    if (!proc$is_alive()) {
      cat(tail(readLines(ERR, warn = FALSE), 30), sep = "\n")
      stop("real Claude app exited")
    }
    if (file.exists(ERR) && any(grepl("Listening on", readLines(ERR, warn = FALSE), fixed = TRUE))) return()
    Sys.sleep(0.25)
  }
  stop("real Claude app startup timeout")
}
new_browser <- function(port) {
  b <- ChromoteSession$new()
  b$Runtime$enable()
  b$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) errors <<- c(errors, paste(vapply(event$args, function(x)
      as.character(x$value %||% x$description %||% ""), character(1)), collapse = " "))
  })
  b$Runtime$exceptionThrown(callback_ = function(event) {
    errors <<- c(errors, paste0("EXC: ", event$exceptionDetails$exception$description %||%
      event$exceptionDetails$text %||% "unknown"))
  })
  b$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); b$Page$loadEventFired()
  b
}
ev <- function(b, js) b$Runtime$evaluate(js)$result$value
wait_until <- function(b, js, timeout = 90, interval = 0.2) {
  deadline <- Sys.time() + timeout
  repeat {
    value <- tryCatch(ev(b, js), error = function(e) FALSE)
    if (isTRUE(value)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
check <- function(name, condition, detail = "") {
  cat(sprintf("[%s] %-42s %s\n", if (isTRUE(condition)) "PASS" else "FAIL", name, detail))
  if (!isTRUE(condition)) stop(name, call. = FALSE)
}
send_text <- function(b, text) {
  check("real composer ready", wait_until(b, "!!document.querySelector('.aui-composer-send')", 20))
  ev(b, "document.querySelector('[contenteditable=true]').focus()")
  b$Input$insertText(text = text)
  b$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  b$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
}
click_new <- function(b) {
  check("create second setup thread", isTRUE(ev(b, "(()=>{const x=document.querySelector('[data-slot=aui_thread-list-new]');if(!x)return false;x.click();return true})()")))
  Sys.sleep(0.5)
}
click_thread <- function(b, label) {
  js <- sprintf("(()=>{const x=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(e=>e.innerText.includes(%s));const t=x?.querySelector('[data-slot=aui_thread-list-item-trigger]');if(!t)return false;t.click();return true})()",
                jsonlite::toJSON(label, auto_unbox = TRUE))
  check(paste("select", label), wait_until(b, js, 20))
  Sys.sleep(0.5)
}

# Phase 1: create two dedicated real Claude sessions; no existing history is touched.
port1 <- httpuv::randomPort(); proc1 <- start_app("setup", port1); on.exit(try(proc1$kill(), silent=TRUE), add=TRUE)
wait_app(proc1); b1 <- new_browser(port1); on.exit(try(b1$close(), silent=TRUE), add=TRUE)
check("setup widget mounted", wait_until(b1, "!!document.querySelector('.aui-root')", 20))
send_text(b1, "Reply with exactly PLAN67_SETUP_A and no other text.")
check("real setup A completed", wait_until(b1, "[...document.querySelectorAll('[data-role=assistant]')].some(e=>e.innerText.includes('PLAN67_SETUP_A')) && !!document.querySelector('[data-slot=aui_usage_footer]')", 120))
click_new(b1)
send_text(b1, "Reply with exactly PLAN67_SETUP_B and no other text.")
check("real setup B completed", wait_until(b1, "[...document.querySelectorAll('[data-role=assistant]')].some(e=>e.innerText.includes('PLAN67_SETUP_B')) && !!document.querySelector('[data-slot=aui_usage_footer]')", 120))
Sys.sleep(1); b1$close(); proc1$kill(); Sys.sleep(1)
map <- readRDS(MAP)
sids <- unique(unname(unlist(map, use.names = FALSE)))
check("two dedicated real session ids", length(sids) >= 2L)
saveRDS(sids[1:2], INFO)

# Reset logs so startup detection applies to the history process.
unlink(c(LOG, ERR))
port2 <- httpuv::randomPort(); proc2 <- start_app("history", port2); on.exit(try(proc2$kill(), silent=TRUE), add=TRUE)
wait_app(proc2); b2 <- new_browser(port2); on.exit(try(b2$close(), silent=TRUE), add=TRUE)
check("two real historical sessions listed", wait_until(b2, "document.querySelectorAll('[data-slot=aui_thread-list-item]').length>=2", 30))

# Open both histories and wait for their real resumed clients to finish warmup.
click_thread(b2, "Real Alpha")
check("Alpha history restored", wait_until(b2, "document.body.innerText.includes('PLAN67_SETUP')", 30))
check("Alpha warmed", wait_until(b2, "!document.querySelector('[data-slot=aui_warming]') && !!document.querySelector('.aui-composer-send')", 120))
click_thread(b2, "Real Beta")
check("Beta history restored", wait_until(b2, "document.body.innerText.includes('PLAN67_SETUP')", 30))
check("Beta warmed", wait_until(b2, "!document.querySelector('[data-slot=aui_warming]') && !!document.querySelector('.aui-composer-send')", 120))

prompt_a <- paste(
  "Begin with PLAN67_REAL_A_PROGRESS.",
  "Use the Read tool to read DESCRIPTION in the current project, summarize its Package field,",
  "then end with PLAN67_REAL_A_DONE."
)
prompt_b <- paste(
  "Begin with PLAN67_REAL_B_PROGRESS. Write 30 numbered one-sentence facts about the R language,",
  "then end with PLAN67_REAL_B_DONE. Do not use tools."
)
click_thread(b2, "Real Alpha"); send_text(b2, prompt_a)
click_thread(b2, "Real Beta"); send_text(b2, prompt_b)
concurrent_js <- "(()=>{const xs=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')];const run=n=>!!xs.find(e=>e.innerText.includes(n))?.querySelector('[data-run-phase=running]');return run('Real Alpha')&&run('Real Beta')})()"
check("both real sessions running concurrently", wait_until(b2, concurrent_js, 30))
click_thread(b2, "Real Alpha")
check("real A progress before terminal", wait_until(b2, "[...document.querySelectorAll('[data-role=assistant]')].some(e=>e.innerText.includes('PLAN67_REAL_A_PROGRESS'))", 60))
check("real A tool card rendered", wait_until(b2, "document.body.innerText.includes('DESCRIPTION') && document.body.innerText.includes('Read')", 60))
check("real A final", wait_until(b2, "[...document.querySelectorAll('[data-role=assistant]')].some(e=>e.innerText.includes('PLAN67_REAL_A_DONE')) && !!document.querySelector('[data-slot=aui_usage_footer]')", 180))
click_thread(b2, "Real Beta")
check("real B progress/final", wait_until(b2, "[...document.querySelectorAll('[data-role=assistant]')].some(e=>e.innerText.includes('PLAN67_REAL_B_PROGRESS') && e.innerText.includes('PLAN67_REAL_B_DONE'))", 180))
check("real B usage visible", wait_until(b2, "!!document.querySelector('[data-slot=aui_usage_footer]')", 30))

# Fresh browser reload exercises persisted real Claude history and must show both finals.
b2$Page$reload(); b2$Page$loadEventFired(); Sys.sleep(2)
click_thread(b2, "Real Alpha")
check("real A final restored from history", wait_until(b2, "[...document.querySelectorAll('[data-role=assistant]')].some(e=>e.innerText.includes('PLAN67_REAL_A_DONE'))", 60))
click_thread(b2, "Real Beta")
check("real B final restored from history", wait_until(b2, "[...document.querySelectorAll('[data-role=assistant]')].some(e=>e.innerText.includes('PLAN67_REAL_B_DONE'))", 60))
check("real smoke zero console/runtime errors", length(errors) == 0L,
      if (length(errors)) paste(unique(errors), collapse = " | ") else "")
check("real smoke used Home install", any(grepl("installed=/home/kaiping.yang/R/", readLines(LOG, warn=FALSE), fixed=TRUE)))
cat("PLAN67_REAL_CLAUDE_DONE\n")
