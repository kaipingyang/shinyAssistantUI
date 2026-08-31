suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
verify_lib <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
port <- 9263L
stdout_log <- "/tmp/aui-oom-workdir-compact.out"
stderr_log <- "/tmp/aui-oom-workdir-compact.err"
unlink(c(stdout_log, stderr_log))
failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-66s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(function(project, port, verify_lib) {
  setwd(project)
  .libPaths(c(verify_lib, .libPaths()))
  Sys.setenv(SHINYASSISTANTUI_VERIFY_LIB = verify_lib)
  suppressPackageStartupMessages(library(shiny))
  shiny::runApp(
    "tests/verify/oom_workdir_compact_app.R",
    host = "127.0.0.1", port = port, launch.browser = FALSE
  )
}, args = list(project = project, port = port, verify_lib = verify_lib),
stdout = stdout_log, stderr = stderr_log)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (index in seq_len(120L)) {
  if (!app$is_alive()) break
  if (file.exists(stderr_log) && any(grepl(
    "Listening on", readLines(stderr_log, warn = FALSE), fixed = TRUE
  ))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) {
  if (file.exists(stderr_log)) cat(tail(readLines(stderr_log, warn = FALSE), 30L), sep = "\n")
  stop("fixture app failed to boot")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 1000, height = 720)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)
console_errors <- character()
runtime_errors <- character()
network_errors <- character()
browser$Runtime$enable()
browser$Network$enable()
browser$Runtime$consoleAPICalled(callback_ = function(event) {
  if (identical(event$type, "error")) console_errors <<- c(console_errors, "console.error")
})
browser$Runtime$exceptionThrown(callback_ = function(event) {
  runtime_errors <<- c(runtime_errors, event$exceptionDetails$text %||% "exception")
})
browser$Network$loadingFailed(callback_ = function(event) {
  if (!isTRUE(event$canceled) && !identical(event$errorText, "net::ERR_ABORTED")) {
    network_errors <<- c(network_errors, event$errorText %||% "network failure")
  }
})
`%||%` <- function(x, y) if (is.null(x)) y else x
value <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}
wait_for <- function(script, timeout = 12, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(script), error = function(error) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
key_enter <- function() {
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("installed widget mounted", wait_for("!!document.querySelector('.aui-root')"))
check(
  "fixture uses installed Home package 0.5.6",
  wait_for("document.getElementById('fixture_package')?.textContent==='installed-0.5.6'")
)

# Restore a real server-persistence history payload. The converter receives a
# user wire entry with compact metadata and must publish an assistant message.
check("history session listed", wait_for("document.body.innerText.includes('Compact and large history')"))
value("(()=>{const b=[...document.querySelectorAll('button')].find(x=>x.innerText.includes('Compact and large history'));if(!b)return false;b.click();return true})()")
check("compact summary restored", wait_for("document.body.innerText.includes('BROWSER COMPACT SUMMARY')"))
compact_role <- value("(()=>{const a=[...document.querySelectorAll('[data-slot=aui_assistant-message-root]')].some(x=>x.innerText.includes('BROWSER COMPACT SUMMARY'));const u=[...document.querySelectorAll('.aui-user-message-content')].some(x=>x.innerText.includes('BROWSER COMPACT SUMMARY'));return a&&!u})()")
check("compact summary is assistant DOM, never a user bubble", compact_role)

# Open only collapsed tool cards. Large history results should expose a lazy
# descriptor and first bounded chunk, not pre-materialize the full 1 MiB preview.
value("(()=>{document.querySelectorAll('[data-slot=tool-fallback-trigger]').forEach(x=>{if(x.getAttribute('aria-expanded')==='false')x.click()});return true})()")
check(
  "2 MiB historical tool result uses metadata-first bounded lazy UI",
  wait_for("Array.from(document.querySelectorAll('[data-lazy-tool-result]')).some(e=>/Bounded \\d+-byte preview of \\d+-byte tool result/.test(e.innerText))", 8)
)

# Drive the real Lexical composer through CDP. While this 2-second run is open,
# the native picker button must be disabled and cannot dispatch a Shiny input.
check("composer available", wait_for("!!document.querySelector('.aui-lexical-input[contenteditable=true]')"))
value("document.querySelector('.aui-lexical-input[contenteditable=true]').focus(); true")
browser$Input$insertText(text = "verify running folder guard")
key_enter()
check("run entered active state", wait_for("!!document.querySelector('.aui-composer-cancel')", 6))
check(
  "native folder picker is disabled during run",
  isTRUE(value("(()=>{const b=document.querySelector('[data-slot=aui_working_dir_change]');return b?.disabled===true&&b?.dataset.runningDisabled==='true'&&b?.getAttribute('aria-disabled')==='true'})()"))
)
value("document.querySelector('[data-slot=aui_working_dir_change]').click(); true")
Sys.sleep(0.4)
check("running click dispatches no native picker input", identical(value("document.getElementById('picker_count')?.textContent"), "0"))
check("run completed", wait_for("document.body.innerText.includes('RUN COMPLETED') && !document.querySelector('.aui-composer-cancel')", 8))
check(
  "native folder picker is re-enabled after run",
  isTRUE(value("document.querySelector('[data-slot=aui_working_dir_change]')?.disabled===false"))
)
value("document.querySelector('[data-slot=aui_working_dir_change]').click(); true")
check("idle native picker input dispatches normally", wait_for("document.getElementById('picker_count')?.textContent==='1'", 5))

check(
  "2 MiB live tool result uses a bounded lazy window",
  wait_for("(()=>{const t=Array.from(document.querySelectorAll('[data-slot=tool-fallback-trigger]')).find(x=>x.innerText.includes('synthetic-large-output'));return !!t?.closest('.aui-shiny-tool')?.querySelector('[data-lazy-tool-result]')})()", 8)
)
Sys.sleep(0.5)
check("no browser console errors", length(console_errors) == 0L,
      paste(console_errors, collapse = " | "))
check("no browser runtime exceptions", length(runtime_errors) == 0L,
      paste(runtime_errors, collapse = " | "))
check("no browser network failures", length(network_errors) == 0L,
      paste(network_errors, collapse = " | "))

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("OOM_WORKDIR_COMPACT_BROWSER_VERIFY_DONE\n")
