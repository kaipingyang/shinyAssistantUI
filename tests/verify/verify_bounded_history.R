suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- httpuv::randomPort()
failures <- character()
source("tests/verify/owned_process_cleanup.R", local = TRUE)
log_paths <- c("/tmp/aui-bounded-history.out", "/tmp/aui-bounded-history.err")
unlink(log_paths)

check <- function(name, condition, detail = "") {
  passed <- isTRUE(condition)
  cat(sprintf("[%s] %-46s %s\n", if (passed) "PASS" else "FAIL", name, detail))
  if (!passed) failures <<- c(failures, name)
  invisible(passed)
}

app <- callr::r_bg(
  function(project, port) {
    setwd(project)
    suppressPackageStartupMessages(library(shiny))
    shiny::runApp(
      "tests/verify/bounded_history_app.R",
      host = "127.0.0.1", port = port, launch.browser = FALSE
    )
  },
  args = list(project = project, port = port),
  stdout = log_paths[[1L]], stderr = log_paths[[2L]]
)
cleanup <- make_verification_cleanup(
  browser_session = function() if (exists("browser", inherits = FALSE)) browser else NULL,
  app_process = function() app,
  paths = log_paths
)
on.exit(cleanup(), add = TRUE)

for (i in seq_len(80L)) {
  if (!app$is_alive()) break
  if (file.exists(log_paths[[2L]]) &&
      any(grepl("Listening on", readLines(log_paths[[2L]], warn = FALSE)))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) {
  cat(tail(readLines(log_paths[[2L]], warn = FALSE), 30L), sep = "\n")
  stop("Bounded-history fixture failed to boot")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu",
  "--disable-breakpad", "--disable-crash-reporter", "--no-crash-upload"
)))
browser <- ChromoteSession$new()
console_errors <- character()
current_stage <- "boot"
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (!identical(message$type, "error")) return()
  text <- paste(vapply(message$args, function(arg) {
    as.character(arg$value %||% arg$description %||% "")
  }, character(1)), collapse = " ")
  console_errors <<- c(console_errors, paste(current_stage, "console:", text))
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  detail <- message$exceptionDetails
  console_errors <<- c(console_errors, paste(
    current_stage, "exception:",
    detail$exception$description %||% detail$text %||% "unknown"
  ))
})

value <- function(script) {
  response <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(response$exceptionDetails)) stop(response$exceptionDetails$text)
  response$result$value
}
wait_for <- function(script, timeout = 10, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    answer <- tryCatch(value(script), error = function(error) FALSE)
    if (isTRUE(answer)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
request_count <- function() as.integer(value(
  "Number((document.getElementById('history-request-count')?.textContent||'0').trim())"
))

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("installed widget mounts", wait_for("!!document.querySelector('.aui-root')", 15))
check("history thread appears", wait_for(
  "Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).some(e=>(e.innerText||'').includes('Bounded History Fixture'))",
  10
))

current_stage <- "open-history"
value("(()=>{const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(e=>(e.innerText||'').includes('Bounded History Fixture'));const b=e?.querySelector('[data-slot=aui_thread-list-item-trigger]')||e;b?.click();return !!b})()")
check("newest page loads", wait_for(
  "document.body.innerText.includes('BOUNDED_ASSISTANT_160') && Number((document.getElementById('history-request-count')?.textContent||'0').trim())===1",
  12
))
check("initial page excludes oldest turn", !isTRUE(value(
  "document.body.innerText.includes('BOUNDED_USER_001')"
)))

current_stage <- "load-to-window-limit"
stored_count <- function() as.integer(value(
  "(()=>{for(const k of Object.keys(localStorage)){if(!k.includes(':msgs:'))continue;let xs=[];try{xs=JSON.parse(localStorage.getItem(k)||'[]')}catch{};if(JSON.stringify(xs).includes('BOUNDED_ASSISTANT_160'))return xs.length}return 0})()"
))
for (attempt in seq_len(10L)) {
  before_stored <- stored_count()
  if (before_stored >= 240L) break
  if (!wait_for("!!document.querySelector('[data-slot=aui_load_older]')", 5)) break
  before <- request_count()
  action <- value("(()=>{const b=document.querySelector('[data-slot=aui_load_older]');if(!b)return false;b.click();return true})()")
  ok <- isTRUE(action) && wait_for(sprintf(
    "Number((document.getElementById('history-request-count')?.textContent||'0').trim())>%d && (()=>{for(const k of Object.keys(localStorage)){if(!k.includes(':msgs:'))continue;let xs=[];try{xs=JSON.parse(localStorage.getItem(k)||'[]')}catch{};if(JSON.stringify(xs).includes('BOUNDED_ASSISTANT_160'))return xs.length>%d}return false})()",
    before, before_stored
  ), 12)
  check(sprintf("older page %d settles", attempt), ok)
  if (!ok) break
}

requests <- request_count()
dom_count <- as.integer(value(
  "document.querySelectorAll('[data-role=user],[data-role=assistant]').length"
))
storage_json <- value("(()=>{for(const k of Object.keys(localStorage)){if(!k.includes(':msgs:'))continue;let xs=[];try{xs=JSON.parse(localStorage.getItem(k)||'[]')}catch{};if(JSON.stringify(xs).includes('BOUNDED_ASSISTANT_160'))return JSON.stringify({key:k,length:xs.length,raw:JSON.stringify(xs)});}return null})()")
storage <- if (is.null(storage_json)) NULL else fromJSON(storage_json)

check("client stops paging when 240 window saturates",
      requests == 5L && !isTRUE(value("!!document.querySelector('[data-slot=aui_load_older]')")),
      sprintf("requests=%d", requests))
check("browser DOM message window is bounded", dom_count <= 240L,
      sprintf("dom_messages=%d", dom_count))
check("complete newest 240-message window is visible",
      dom_count == 240L &&
        isTRUE(value("document.body.innerText.includes('BOUNDED_USER_041')")) &&
        isTRUE(value("document.body.innerText.includes('BOUNDED_ASSISTANT_160')")))
check("window-evicted loaded prefix is absent from DOM",
      !isTRUE(value("document.body.innerText.includes('BOUNDED_USER_036')")))
check("bounded localStorage snapshot exists", !is.null(storage),
      if (is.null(storage)) "no :msgs: entry" else storage$key)
if (!is.null(storage)) {
  check("localStorage message graph is bounded", storage$length <= 240L,
        sprintf("stored_messages=%d", storage$length))
  check("localStorage retains window root and newest tail",
        grepl("BOUNDED_USER_041", storage$raw, fixed = TRUE) &&
          grepl("BOUNDED_ASSISTANT_160", storage$raw, fixed = TRUE))
  check("localStorage evicts loaded out-of-window IDs",
        !grepl("BOUNDED_USER_036", storage$raw, fixed = TRUE))
}
check("no browser console errors or exceptions", length(console_errors) == 0L,
      if (length(console_errors)) paste(unique(console_errors), collapse = " | ") else "0 errors")
check("widget survives bounded paging", isTRUE(value("!!document.querySelector('.aui-root')")))

cleanup()
rm(browser)
invisible(gc())
Sys.sleep(0.3)
if (length(failures)) stop(
  "Bounded-history Chromium verification failed: ", paste(failures, collapse = ", ")
)
cat("BOUNDED_HISTORY_CHROMIUM_DONE\n")
