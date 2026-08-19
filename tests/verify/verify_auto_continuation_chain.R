suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
expected_version <- unname(read.dcf(file.path(project, "DESCRIPTION"), fields = "Version")[[1L]])
port <- 9696L
stdout_path <- "/tmp/aui-auto-chain.out"
stderr_path <- "/tmp/aui-auto-chain.err"
unlink(c(stdout_path, stderr_path))
failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-58s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
}

app <- callr::r_bg(function(project, home_library, port) {
  .libPaths(c(home_library, .libPaths()))
  setwd(project)
  suppressPackageStartupMessages(library(shiny))
  cat("installed=", find.package("shinyAssistantUI"), "\n", sep = "")
  cat("installed_version=", as.character(packageVersion("shinyAssistantUI")), "\n", sep = "")
  shiny::runApp(
    "tests/verify/auto_continuation_chain_app.R",
    host = "127.0.0.1", port = port, launch.browser = FALSE
  )
}, args = list(project = project, home_library = home_library, port = port),
stdout = stdout_path, stderr = stderr_path)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (index in seq_len(160L)) {
  if (!app$is_alive()) break
  if (file.exists(stderr_path) && any(grepl("Listening on", readLines(stderr_path, warn = FALSE), fixed = TRUE))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) stop("auto-continuation fixture failed to start")

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 900, height = 900)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) console_errors <<- c(console_errors, "console")
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  console_errors <<- c(console_errors, "exception")
})
value <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}
wait_for <- function(script, timeout = 30) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(script), error = function(error) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.05)
  }
}
click_selector <- function(selector) {
  point_json <- value(sprintf(
    "(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()",
    jsonlite::toJSON(selector, auto_unbox = TRUE)
  ))
  if (is.null(point_json)) return(FALSE)
  point <- jsonlite::fromJSON(point_json)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y,
                                   button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y,
                                   button = "left", clickCount = 1L)
  TRUE
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("widget mounted", wait_for("!!document.querySelector('.aui-root')"))
check("composer focused", click_selector(".aui-lexical-input[contenteditable='true']"))
Sys.sleep(0.3)
browser$Input$insertText(text = "start chain")
Sys.sleep(0.7)
browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)

check("initial user message was submitted",
      wait_for("Array.from(document.querySelectorAll('[data-role=user]')).some(e=>(e.innerText||'').includes('start chain'))", 15))
check("first backend turn started",
      wait_for("(document.getElementById('calls')?.innerText||'').includes('start chain')", 15))
check("third backend turn produced final visible text",
      wait_for("document.body.innerText.includes('CHAIN_COMPLETE')", 30))
check("backend received exactly three ordered submissions", isTRUE(value(
  "(function(){const t=document.getElementById('calls')?.innerText||'';return t.split('---').length===3&&t.includes('start chain')&&t.includes('completed tool results')&&t.includes('final user-visible response')})()"
)))
check("tool-postlude continuation is a visible user bubble", isTRUE(value(
  "Array.from(document.querySelectorAll('[data-role=user]')).some(e=>(e.innerText||'').includes('completed tool results'))"
)))
check("generic continuation is a visible user bubble", isTRUE(value(
  "Array.from(document.querySelectorAll('[data-role=user]')).some(e=>(e.innerText||'').includes('final user-visible response'))"
)))
check("two automatic continuation notices are visible", isTRUE(value(
  "Array.from(document.querySelectorAll('[data-role=assistant]')).filter(e=>(e.innerText||'').includes('Continuing automatically')).length===2"
)))
check("no user-visible error card", isTRUE(value(
  "!document.body.innerText.includes('Error: Upstream ended')&&!document.body.innerText.includes('Please retry the request')"
)))
logs <- if (file.exists(stdout_path)) readLines(stdout_path, warn = FALSE) else character()
check("fixture uses Home installed package",
      any(grepl(paste0("installed=", home_library, "/shinyAssistantUI"), logs, fixed = TRUE)),
      paste(grep("^installed=", logs, value = TRUE), collapse = " | "))
installed_version <- sub(
  "^installed_version=", "", grep("^installed_version=", logs, value = TRUE)
)
check("installed package version matches source",
      length(installed_version) == 1L && identical(installed_version[[1L]], expected_version),
      paste("expected=", expected_version, "installed=", paste(installed_version, collapse = " | ")))
check("zero browser console/runtime errors", length(console_errors) == 0L,
      paste(length(console_errors), "errors"))

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop("auto-continuation verification failed: ", paste(failures, collapse = ", "))
cat("AUTO_CONTINUATION_CHAIN_VERIFY_DONE\n")
