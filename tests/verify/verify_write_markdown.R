suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9642L
unlink(c("/tmp/aui-write-md.out", "/tmp/aui-write-md.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond)
  cat(sprintf("[%s] %-58s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(function(project, port) {
  setwd(project)
  suppressPackageStartupMessages(library(shiny))
  shiny::runApp(
    "tests/verify/write_markdown_app.R",
    host = "127.0.0.1", port = port, launch.browser = FALSE
  )
}, args = list(project = project, port = port),
stdout = "/tmp/aui-write-md.out", stderr = "/tmp/aui-write-md.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) {
  if (!app$is_alive()) break
  if (file.exists("/tmp/aui-write-md.err") &&
      any(grepl("Listening on", readLines("/tmp/aui-write-md.err", warn = FALSE)))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) {
  cat(tail(readLines("/tmp/aui-write-md.err", warn = FALSE), 20), sep = "\n")
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

layout_ok <- function(author) paste0(
  "(function(){const root=document.querySelector('[data-arg-lang=markdown]');",
  "const code=root?.querySelector('code');if(!code)return false;",
  "const tokens=Array.from(code.querySelectorAll('span.token'));",
  "return code.textContent.includes('| Developer | Changes |') && ",
  "code.innerText.includes('| Developer | Changes |') && ",
  "code.innerText.includes('| ", author, " | Promoted the Flexible Figure module to production |') && ",
  "!code.innerText.includes('|\\n Developer') && tokens.length>0 && ",
  "tokens.every(e=>getComputedStyle(e).display==='inline');})()"
)
live_layout_ok <- layout_ok("Kaiping Yang")
history_layout_ok <- layout_ok("Historical Author")

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 15))
click_sel(".aui-lexical-input[contenteditable='true']")
browser$Input$insertText(text = "write it")
press_enter()

chk("live Write Markdown card rendered", wait_for(
  "!!document.querySelector('[data-arg-view=code][data-arg-lang=markdown]')", 15))
chk("live Markdown table keeps source rows and inline tokens", isTRUE(value(live_layout_ok)),
    value("document.querySelector('[data-arg-lang=markdown] code')?.innerText"))
chk("live Write parameters are code, not JSON wrapper", isTRUE(value(
  "!!document.querySelector('[data-arg-lang=markdown]') && !document.querySelector('[data-arg-lang=markdown] [data-args-format=json]')"
)))

chk("clicked Markdown Write history thread", click_thread("Markdown Write history"))
chk("historical Write loaded from session", wait_for(
  "document.body.innerText.includes('Historical Markdown Write restored')", 8))
chk("history Markdown table keeps source rows and inline tokens", isTRUE(value(history_layout_ok)),
    value("document.querySelector('[data-arg-lang=markdown] code')?.innerText"))
chk("history remains completed and has no approval form", isTRUE(value(
  "!document.querySelector('.aui-shiny-approval') && document.body.innerText.includes('File written')"
)))
chk("no browser console errors", length(console_errors) == 0,
    if (length(console_errors)) paste(console_errors, collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("WRITE_MARKDOWN_VERIFY_DONE\n")
