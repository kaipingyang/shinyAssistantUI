suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9642L
unlink(c("/tmp/aui-write-md.out", "/tmp/aui-write-md.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond)
  cat(sprintf("[%s] %-62s %s\n", if (ok) "PASS" else "FAIL", name, detail))
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
    as.character(jsonlite::toJSON(selector, auto_unbox = TRUE))
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
    as.character(jsonlite::toJSON(label, auto_unbox = TRUE))
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
click_markdown_control <- function(root_selector, label) {
  isTRUE(value(sprintf(
    "(function(){const r=document.querySelector(%s);const b=Array.from(r?.querySelectorAll('button')||[]).find(x=>(x.innerText||'').trim()===%s);if(!b)return false;b.click();return true})()",
    as.character(toJSON(root_selector, auto_unbox = TRUE)),
    as.character(toJSON(label, auto_unbox = TRUE))
  )))
}

md_content <- paste(
  "## Contributors", "", "| Developer | Changes |", "|---|---|",
  "| Kaiping Yang | Promoted the Flexible Figure module to production |",
  "| Hao Wan | AE SOC/PT-by-Grade layout fix |", sep = "\n"
)
history_content <- sub("Kaiping Yang", "Historical Author", md_content, fixed = TRUE)

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
chk("widget mounted from installed package", wait_for("!!document.querySelector('.aui-root')", 15))
click_sel(".aui-lexical-input[contenteditable='true']")
browser$Input$insertText(text = "write it")
press_enter()

chk("live ExitPlanMode + Write render generic Markdown views", wait_for(
  "document.querySelectorAll('[data-arg-view=markdown]').length>=2", 15))
chk("live plans and Markdown Write render real GFM tables", isTRUE(value(
  "document.querySelectorAll('[data-arg-view=markdown] table').length>=2"
)))
chk("ExitPlanMode Source is subtle and Write Source is prominent", isTRUE(value(
  "!!document.querySelector('[data-source-control=subtle]') && !!document.querySelector('[data-source-control=prominent]')"
)))
chk("Markdown Write starts in Preview", identical(value(
  "document.querySelector('[data-source-control=prominent]')?.getAttribute('data-markdown-mode')"
), "preview"))
chk("live Write Source control clicked", click_markdown_control(
  "[data-source-control=prominent]", "Source"
))
chk("live Write Source is byte-identical", isTRUE(value(sprintf(
  "document.querySelector('[data-source-control=prominent] [data-markdown-source=true]')?.textContent===%s",
  as.character(toJSON(md_content, auto_unbox = TRUE))
))))
chk("live Write can return to Preview", click_markdown_control(
  "[data-source-control=prominent]", "Preview"
))
chk("approval card remains available after preview toggles", wait_for(
  "Array.from(document.querySelectorAll('button')).some(b=>/^\\s*Approve\\s*$/.test(b.innerText||''))", 8
))
chk("approval submitted", isTRUE(value(
  "(function(){const b=Array.from(document.querySelectorAll('button')).find(x=>/^\\s*Approve\\s*$/.test(x.innerText||''));if(!b)return false;b.click();return true})()"
)))
chk("approval executes with original Write args", wait_for(
  "document.body.innerText.includes('ORIGINAL_ARGS_PRESERVED') && document.body.innerText.includes('File written')", 10
))
chk("preview did not rewrite original args", isTRUE(value(
  "!document.body.innerText.includes('ORIGINAL_ARGS_CHANGED')"
)))

chk("clicked Markdown tools history thread", click_thread("Markdown tools history"))
chk("historical tool calls restored", wait_for(
  "document.body.innerText.includes('Historical Markdown tools restored')", 10
))
chk("history CSV/TXT/code Write views restored", wait_for(
  "!!document.querySelector('[data-table-format=csv] table') && !!document.querySelector('[data-source-language=text]') && !!document.querySelector('[data-arg-view=code][data-arg-lang=python] [data-syntax-highlighter=prism]')", 10
))
chk("history CSV parsed quoted cell", isTRUE(value(
  "Array.from(document.querySelectorAll('[data-table-format=csv] td')).some(e=>(e.textContent||'')==='hello, world')"
)))
chk("history TXT remains Source-first and byte-identical", isTRUE(value(
  "document.querySelector('[data-source-language=text]')?.textContent==='# Historical rich text\\n\\n- restored item\\n'"
)))
chk("history Python Write restored as code, not Markdown", isTRUE(value(
  "(document.querySelector('[data-arg-view=code][data-arg-lang=python]')?.textContent||'')===\"print('history')\""
)))
chk("history ExitPlanMode + Write both render Markdown", isTRUE(value(
  "document.querySelectorAll('[data-arg-view=markdown]').length>=2 && document.querySelectorAll('[data-arg-view=markdown] table').length>=2"
)))
chk("history Windows .MARKDOWN path defaults Write to Preview", identical(value(
  "document.querySelector('[data-source-control=prominent]')?.getAttribute('data-markdown-mode')"
), "preview"))
chk("history Write Source control clicked", click_markdown_control(
  "[data-source-control=prominent]", "Source"
))
chk("history Write Source remains byte-identical", isTRUE(value(sprintf(
  "document.querySelector('[data-source-control=prominent] [data-markdown-source=true]')?.textContent===%s",
  as.character(toJSON(history_content, auto_unbox = TRUE))
))))
chk("history is completed and has no approval form", isTRUE(value(
  "!document.querySelector('.aui-shiny-approval') && document.body.innerText.includes('File written')"
)))
chk("no browser console/runtime errors", length(console_errors) == 0,
    if (length(console_errors)) paste(console_errors, collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("WRITE_MARKDOWN_VERIFY_DONE\n")
