suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
project_root <- normalizePath(".", winslash = "/", mustWork = TRUE)
fixture_project <- "/tmp/aui-openfile-cwd-prefix/ERP"
port <- 9644L
unlink(c("/tmp/aui-prefix.out", "/tmp/aui-prefix.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond)
  cat(sprintf("[%s] %-58s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(function(project_root, port) {
  setwd(project_root)
  suppressPackageStartupMessages(library(shiny))
  shiny::runApp(
    "tests/verify/openfile_cwd_prefix_app.R",
    host = "127.0.0.1", port = port, launch.browser = FALSE
  )
}, args = list(project_root = project_root, port = port),
stdout = "/tmp/aui-prefix.out", stderr = "/tmp/aui-prefix.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) {
  if (!app$is_alive()) break
  if (file.exists("/tmp/aui-prefix.err") &&
      any(grepl("Listening on", readLines("/tmp/aui-prefix.err", warn = FALSE)))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) {
  cat(tail(readLines("/tmp/aui-prefix.err", warn = FALSE), 20), sep = "\n")
  stop("boot failed")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 720, height = 900)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(m) {
  if (identical(m$type, "error")) console_errors <<- c(console_errors, "console.error")
})
browser$Runtime$exceptionThrown(callback_ = function(m) {
  console_errors <<- c(console_errors, "exception")
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
click_sel <- function(selector) {
  point <- value(sprintf(
    "(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()",
    jsonlite::toJSON(selector, auto_unbox = TRUE)
  ))
  if (is.null(point)) return(FALSE)
  point <- fromJSON(point)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y,
                                   button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y,
                                   button = "left", clickCount = 1L)
  TRUE
}
click_thread <- function(label) {
  point <- value(sprintf(
    "(function(){const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(x=>(x.innerText||'').includes(%s));if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+20,y:r.top+r.height/2})})()",
    jsonlite::toJSON(label, auto_unbox = TRUE)
  ))
  if (is.null(point)) return(FALSE)
  point <- fromJSON(point)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y,
                                   button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y,
                                   button = "left", clickCount = 1L)
  TRUE
}
press_enter <- function() {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter",
                                 windowsVirtualKeyCode = 13L)
  browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter",
                                 windowsVirtualKeyCode = 13L)
}
probe_is <- function(path) sprintf(
  "document.getElementById('resolved-path-probe')?.innerText.includes(%s)",
  jsonlite::toJSON(path, auto_unbox = TRUE)
)

live_name <- "\u4ea4\u63a5\u6587\u6863_xpt2sas\u5f02\u6b65\u5316.md"
history_name <- "\u5386\u53f2_\u4ea4\u63a5.md"
live_expected <- file.path(fixture_project, live_name)
history_expected <- file.path(fixture_project, history_name)

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 15))
click_sel(".aui-lexical-input[contenteditable='true']")
browser$Input$insertText(text = "show handoff")
press_enter()
chk("live project-prefixed Unicode file chip rendered", wait_for(
  "!!document.querySelector('[data-file-ref^=\"ERP/\"]')", 15))
chk("clicked live project-prefixed file", click_sel("[data-file-ref^='ERP/']"))
chk("live click resolves to cwd-root absolute path", wait_for(probe_is(live_expected), 8),
    value("document.getElementById('resolved-path-probe')?.innerText"))
chk("live resolution does not duplicate ERP directory", isTRUE(value(
  "!document.getElementById('resolved-path-probe')?.innerText.includes('/ERP/ERP/')"
)))

chk("clicked history thread", click_thread("CWD prefix history"))
chk("history project-prefixed Unicode file chip rendered", wait_for(
  "document.body.innerText.includes('Historical handoff') && !!document.querySelector('[data-file-ref^=\"ERP/\"]')", 8))
chk("clicked historical project-prefixed file", click_sel("[data-file-ref^='ERP/']"))
chk("history click resolves distinct cwd-root absolute path", wait_for(probe_is(history_expected), 8),
    value("document.getElementById('resolved-path-probe')?.innerText"))
chk("no browser console errors", length(console_errors) == 0,
    if (length(console_errors)) paste(console_errors, collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
unlink("/tmp/aui-openfile-cwd-prefix", recursive = TRUE, force = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("OPENFILE_CWD_PREFIX_VERIFY_DONE\n")
