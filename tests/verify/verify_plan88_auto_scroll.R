.libPaths(c(
  "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4",
  "/posit_share/site_library_u/4.4.3",
  .Library
))
suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

project <- normalizePath(".", winslash = "/", mustWork = TRUE)
home <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
site <- "/posit_share/site_library_u/4.4.3"
port <- 9678L
stdout_path <- "/tmp/aui-plan88.out"
stderr_path <- "/tmp/aui-plan88.err"
unlink(c(stdout_path, stderr_path))
failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-66s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(
  function(project, home, site, port) {
    .libPaths(c(home, site, .Library))
    setwd(project)
    suppressPackageStartupMessages({ library(shiny); library(shinyAssistantUI) })
    shiny::runApp(
      "tests/verify/plan88_auto_scroll_app.R",
      host = "127.0.0.1", port = port, launch.browser = FALSE
    )
  },
  args = list(project = project, home = home, site = site, port = port),
  stdout = stdout_path, stderr = stderr_path
)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(300L)) {
  if (!app$is_alive()) break
  if (file.exists(stderr_path) && any(grepl("Listening on", readLines(stderr_path, warn = FALSE)))) break
  Sys.sleep(0.1)
}
if (!app$is_alive()) {
  cat(tail(readLines(stderr_path, warn = FALSE), 30L), sep = "\n")
  stop("Plan 88 fixture failed to boot")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 760, height = 500)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(event) {
  if (identical(event$type, "error")) console_errors <<- c(console_errors, "console.error")
})
browser$Runtime$exceptionThrown(callback_ = function(event) {
  console_errors <<- c(console_errors, "Runtime.exceptionThrown")
})
value <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}
wait_for <- function(script, timeout = 30, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(script), error = function(error) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
send_text <- function(text) {
  editor <- ".aui-lexical-input[contenteditable='true']"
  if (!wait_for(sprintf("!!document.querySelector(%s)", toJSON(editor, auto_unbox = TRUE)), 20)) return(FALSE)
  value(sprintf("document.querySelector(%s).focus(); true", toJSON(editor, auto_unbox = TRUE)))
  browser$Input$insertText(text = text)
  browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  TRUE
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("installed Home widget mounted", wait_for("!!document.querySelector('.aui-root')", 30))
check("Shiny websocket connected", wait_for(
  "!!window.Shiny && !!Shiny.shinyapp && !!Shiny.shinyapp.$socket && Shiny.shinyapp.$socket.readyState===1", 30
))
check("real composer submitted initial request", send_text("BEGIN_SCROLL_AUTO"))
check("Write Markdown preview has real inner overflow", wait_for(
  "(()=>{const e=document.querySelector('[data-markdown-preview=true]');return !!e&&e.scrollHeight>e.clientHeight})()", 20
))

before <- fromJSON(value("(()=>{const s=document.querySelector('[data-markdown-preview=true]'),c=s.closest('.aui-shiny-tool'),m=c.closest('[data-slot=aui_assistant-message-root]'),t=c.querySelector('[data-slot=tool-fallback-trigger]');window.__p88s=s;window.__p88c=c;window.__p88m=m;s.scrollTop=s.scrollHeight;s.dispatchEvent(new Event('scroll'));const r=c.getBoundingClientRect();window.__p88outside={x:Math.max(10,Math.min(innerWidth-10,r.left+10)),y:Math.max(10,r.top-25)};return JSON.stringify({top:s.scrollTop,max:s.scrollHeight-s.clientHeight,expanded:t.getAttribute('aria-expanded'),mode:s.closest('[data-arg-view=markdown]').dataset.markdownMode})})()"))
pos <- value("window.__p88outside")
browser$Input$dispatchMouseEvent(type = "mouseMoved", x = as.numeric(pos$x), y = as.numeric(pos$y))
browser$Input$dispatchMouseEvent(type = "mouseWheel", x = as.numeric(pos$x), y = as.numeric(pos$y), deltaY = 420, deltaX = 0)
check("preview was placed exactly at bottom", before$top == before$max && before$max > 0,
      sprintf("top=%s max=%s", before$top, before$max))
check("Write card started open in Markdown preview", identical(before$expanded, "true") && identical(before$mode, "preview"))

check("automatic continuation reached final visible reply", wait_for(
  "(document.body.innerText||'').includes('FINAL RESPONSE AFTER AUTOMATIC CONTINUATION')", 20
))
after <- fromJSON(value("(()=>{const s=document.querySelector('[data-markdown-preview=true]'),c=s.closest('.aui-shiny-tool'),m=c.closest('[data-slot=aui_assistant-message-root]'),t=c.querySelector('[data-slot=tool-fallback-trigger]');return JSON.stringify({top:s.scrollTop,max:s.scrollHeight-s.clientHeight,expanded:t.getAttribute('aria-expanded'),scrollSame:s===window.__p88s,cardSame:c===window.__p88c,messageSame:m===window.__p88m,oldConnected:window.__p88s.isConnected,cards:document.querySelectorAll('.aui-shiny-tool').length})})()"))
check("exact card subtree really remounted", !after$scrollSame && !after$cardSame && after$messageSame && !after$oldConnected)
check("Write card remained expanded after remount", identical(after$expanded, "true"))
check("remounted Markdown preview restored to bottom", after$top == after$max && after$max > 0,
      sprintf("top=%s max=%s", after$top, after$max))
check("tool call/result were not duplicated", identical(after$cards, 1L))

continuation_prompt <- paste0(
  "Please continue from the completed tool results and provide the final response. ",
  "Do not repeat completed tool calls."
)
order <- fromJSON(value(sprintf("(()=>{const roots=[...document.querySelectorAll('[data-slot=aui_user-message-root],[data-slot=aui_assistant-message-root]')];return JSON.stringify(roots.map(e=>({role:e.dataset.slot.includes('user')?'user':'assistant',text:e.innerText})))})()")))
texts <- as.character(order$text)
roles <- as.character(order$role)
notice_i <- which(grepl("Continuing automatically", texts, fixed = TRUE))[1]
prompt_i <- which(roles == "user" & grepl(continuation_prompt, texts, fixed = TRUE))[1]
final_i <- which(grepl("FINAL RESPONSE AFTER AUTOMATIC CONTINUATION", texts, fixed = TRUE))[1]
check("visible notice precedes continuation user bubble", !is.na(notice_i) && !is.na(prompt_i) && notice_i < prompt_i)
check("continuation user bubble precedes final assistant reply", !is.na(final_i) && prompt_i < final_i)

check("real composer submitted failure-cap scenario", send_text("FAIL_CAP"))
check("second stalled continuation surfaces one final error", wait_for(
  "(document.body.innerText||'').includes('Simulated continuation stopped without another automatic retry.')", 10
))
Sys.sleep(1)
continuation_count <- value(sprintf("[...document.querySelectorAll('[data-slot=aui_user-message-root]')].filter(e=>(e.innerText||'').includes(%s)).length", toJSON(continuation_prompt, auto_unbox = TRUE)))
check("failure cap produced no third automatic send", identical(continuation_count, 2L),
      sprintf("continuation bubbles=%s", continuation_count))
check("no console errors or runtime exceptions", length(console_errors) == 0L,
      paste(console_errors, collapse = ", "))

if (length(failures)) stop("Plan 88 Chromium verification failed: ", paste(failures, collapse = ", "))
cat("PLAN88_INSTALLED_CHROMIUM_PASS\n")
