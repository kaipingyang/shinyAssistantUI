home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
.libPaths(c(
  home_library,
  "/posit_share/site_library_u/4.4.3",
  .Library.site,
  .Library
))

suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project_root <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9341L
stdout_path <- "/tmp/assistant-text-settings-browser.out"
stderr_path <- "/tmp/assistant-text-settings-browser.err"
unlink(c(stdout_path, stderr_path))

app <- callr::r_bg(function(project_root, home_library, port) {
  .libPaths(c(
  home_library,
  "/posit_share/site_library_u/4.4.3",
  .Library.site,
  .Library
))
  setwd(project_root)
  suppressPackageStartupMessages({
    library(shiny)
    library(shinyAssistantUI)
  })
  cat("installed=", normalizePath(find.package("shinyAssistantUI")), "\n", sep = "")
  shiny::runApp(
    "tests/verify/settings_ux_app.R",
    host = "127.0.0.1",
    port = port,
    launch.browser = FALSE
  )
}, args = list(
  project_root = project_root,
  home_library = home_library,
  port = port
), stdout = stdout_path, stderr = stderr_path)

on.exit({
  try(app$kill(), silent = TRUE)
  unlink(c(stdout_path, stderr_path))
}, add = TRUE)

for (i in seq_len(120L)) {
  if (!app$is_alive()) {
    cat(readLines(stderr_path, warn = FALSE), sep = "\n")
    stop("Settings fixture exited during startup", call. = FALSE)
  }
  logs <- if (file.exists(stderr_path)) readLines(stderr_path, warn = FALSE) else character()
  if (any(grepl("Listening on", logs, fixed = TRUE))) break
  Sys.sleep(0.25)
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage",
  "--no-sandbox",
  "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 760, height = 720)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)

browser_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(event) {
  if (identical(event$type, "error")) {
    text <- paste(vapply(event$args, function(arg) {
      as.character(arg$value %||% arg$description %||% "")
    }, character(1)), collapse = " ")
    browser_errors <<- c(browser_errors, paste0("console: ", text))
  }
})
browser$Runtime$exceptionThrown(callback_ = function(event) {
  browser_errors <<- c(
    browser_errors,
    paste0(
      "exception: ",
      event$exceptionDetails$exception$description %||%
        event$exceptionDetails$text %||% "unknown"
    )
  )
})

evaluate <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) {
    stop(result$exceptionDetails$text, call. = FALSE)
  }
  result$result$value
}
wait_for <- function(script, timeout = 15, interval = 0.1) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(evaluate(script), error = function(e) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
check <- function(label, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-58s %s\n", if (ok) "PASS" else "FAIL", label, detail))
  if (!ok) stop(label, call. = FALSE)
}
click <- function(selector) {
  encoded <- jsonlite::toJSON(selector, auto_unbox = TRUE)
  isTRUE(evaluate(sprintf(
    "(()=>{const x=document.querySelector(%s);if(!x)return false;x.click();return true})()",
    encoded
  )))
}
send_text <- function(text) {
  check("composer available", wait_for("!!document.querySelector('[contenteditable=true]')"))
  evaluate("document.querySelector('[contenteditable=true]').focus()")
  browser$Input$insertText(text = text)
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
}

measure_sizes <- function() {
  jsonlite::fromJSON(evaluate(
    "(()=>{const px=s=>parseFloat(getComputedStyle(document.querySelector(s)).fontSize);return JSON.stringify({body:px('[data-slot=aui_assistant-text]'),heading:px('[data-slot=aui_assistant-text] .aui-md-h1'),assistantCode:px('[data-slot=aui_assistant-text] pre'),toolTrigger:px('.aui-shiny-tool .aui-tool-fallback-trigger'),toolPreview:px('[data-markdown-preview=true]'),toolResult:px('.aui-shiny-tool-result .aui-tool-md p'),toolCode:px('[data-markdown-preview=true] pre'),user:px('.aui-user-message-content'),composer:px('[contenteditable=true]')})})()"
  ))
}
set_text_size <- function(value) {
  encoded <- jsonlite::toJSON(value, auto_unbox = TRUE)
  isTRUE(evaluate(sprintf(
    "(()=>{const s=document.querySelector('[data-slot=aui_assistant_text_size]');if(!s)return false;const set=Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set;set.call(s,%s);s.dispatchEvent(new Event('change',{bubbles:true}));return true})()",
    encoded
  )))
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("installed widget mounted", wait_for("!!document.querySelector('.aui-root')", 20))
check(
  "history session is available for explicit restore",
  wait_for("document.body.innerText.includes('Settings history')")
)
send_text("render the typography fixture")
check(
  "rich assistant response rendered",
  wait_for("document.querySelector('[data-slot=aui_assistant-text]')?.innerText.includes('ASSISTANT BODY')")
)

check(
  "tool typography regions rendered",
  wait_for("(()=>{const sels=['.aui-shiny-tool .aui-tool-fallback-trigger','[data-markdown-preview=true]','.aui-shiny-tool-result .aui-tool-md p','[data-markdown-preview=true] pre'];return sels.every(s=>document.querySelector(s))})()")
)

default_sizes <- measure_sizes()
check("Default assistant body is 16px", abs(default_sizes$body - 16) < 0.2)
check("Default assistant heading is 20px", abs(default_sizes$heading - 20) < 0.2)
check("Default assistant code is 13px", abs(default_sizes$assistantCode - 13) < 0.2)
check("Default tool trigger is 14px", abs(default_sizes$toolTrigger - 14) < 0.2)
check("Default tool Markdown preview is 14px", abs(default_sizes$toolPreview - 14) < 0.2)
check("Default tool result body is 14px", abs(default_sizes$toolResult - 14) < 0.2)
check("Default tool code is 12px", abs(default_sizes$toolCode - 12) < 0.2)

baseline_user_size <- default_sizes$user
baseline_composer_size <- default_sizes$composer
check("open Settings", click("[aria-label=Settings]"))
check(
  "Assistant text size offers Small, Medium, Default",
  wait_for("(()=>{const s=document.querySelector('[data-slot=aui_assistant_text_size]');return !!s&&[...s.options].map(o=>o.value+':'+o.textContent).join('|')==='small:Small|compact:Medium|medium:Default'&&s.value==='medium'})()")
)

check("select Medium", set_text_size("compact"))
check(
  "Medium updates the shared assistant/tool scope",
  wait_for("document.querySelector('[data-slot=aui_assistant-message-content]')?.dataset.assistantTextSize==='compact'&&document.querySelector('[data-slot=aui_assistant-text]')?.dataset.textSize==='compact'")
)
medium_sizes <- measure_sizes()
check("Medium assistant body is 14px", abs(medium_sizes$body - 14) < 0.2)
check("Medium assistant heading is 17.5px", abs(medium_sizes$heading - 17.5) < 0.2)
check("Medium assistant code is 12px", abs(medium_sizes$assistantCode - 12) < 0.2)
check("Medium tool trigger is 12px", abs(medium_sizes$toolTrigger - 12) < 0.2)
check("Medium tool Markdown preview is 12px", abs(medium_sizes$toolPreview - 12) < 0.2)
check("Medium tool result body is 12px", abs(medium_sizes$toolResult - 12) < 0.2)
check("Medium tool code is 11px", abs(medium_sizes$toolCode - 11) < 0.2)

check("select Small", set_text_size("small"))
check(
  "Small updates the shared assistant/tool scope",
  wait_for("document.querySelector('[data-slot=aui_assistant-message-content]')?.dataset.assistantTextSize==='small'&&document.querySelector('[data-slot=aui_assistant-text]')?.dataset.textSize==='small'")
)
small_sizes <- measure_sizes()
check("Small assistant body is 12px", abs(small_sizes$body - 12) < 0.2)
check("Small assistant heading is 15px", abs(small_sizes$heading - 15) < 0.2)
check("Small assistant code is 11px", abs(small_sizes$assistantCode - 11) < 0.2)
check("Small tool trigger is 11px", abs(small_sizes$toolTrigger - 11) < 0.2)
check("Small tool Markdown preview is 11px", abs(small_sizes$toolPreview - 11) < 0.2)
check("Small tool result body is 11px", abs(small_sizes$toolResult - 11) < 0.2)
check("Small tool code is 10px", abs(small_sizes$toolCode - 10) < 0.2)

for (field in c("body", "heading", "assistantCode", "toolTrigger", "toolPreview", "toolResult", "toolCode")) {
  check(
    paste("Small < Medium < Default for", field),
    small_sizes[[field]] < medium_sizes[[field]] && medium_sizes[[field]] < default_sizes[[field]],
    sprintf("%.1f < %.1f < %.1f", small_sizes[[field]], medium_sizes[[field]], default_sizes[[field]])
  )
}
check(
  "user message typography is outside the assistant scope",
  abs(small_sizes$user - baseline_user_size) < 0.2
)
check(
  "composer typography is outside the assistant scope",
  abs(small_sizes$composer - baseline_composer_size) < 0.2
)
check(
  "canonical Medium and Small callbacks reach R",
  wait_for("true", 1) && {
    deadline <- Sys.time() + 8
    found <- FALSE
    while (Sys.time() < deadline && !found) {
      lines <- if (file.exists(stderr_path)) readLines(stderr_path, warn = FALSE) else character()
      found <- any(grepl("SET_TEXT_SIZE=compact", lines, fixed = TRUE)) &&
        any(grepl("SET_TEXT_SIZE=small", lines, fixed = TRUE))
      if (!found) Sys.sleep(0.1)
    }
    found
  }
)

browser$Emulation$setDeviceMetricsOverride(
  width = 760L, height = 320L, deviceScaleFactor = 1, mobile = FALSE
)
Sys.sleep(0.4)
check(
  "short viewport constrains Settings inside the sidebar",
  isTRUE(evaluate("(()=>{const d=document.querySelector('[data-slot=aui_settings_dialog]');const s=document.querySelector('[data-slot=aui_thread_sidebar]');if(!d||!s)return false;const dr=d.getBoundingClientRect(),sr=s.getBoundingClientRect();return dr.top>=sr.top-1&&dr.bottom<=sr.bottom+1&&dr.height>100})()"))
)
check(
  "short Settings panel has real internal vertical overflow",
  isTRUE(evaluate("(()=>{const d=document.querySelector('[data-slot=aui_settings_dialog]');const y=getComputedStyle(d).overflowY;return (y==='auto'||y==='scroll')&&getComputedStyle(d).overscrollBehaviorY==='contain'&&d.scrollHeight>d.clientHeight+1})()"))
)
check(
  "Settings scrollbar moves to the final controls",
  isTRUE(evaluate("(()=>{const d=document.querySelector('[data-slot=aui_settings_dialog]');d.scrollTop=d.scrollHeight;return d.scrollTop>0})()"))
)
check(
  "sticky Settings header and close control remain visible after scroll",
  isTRUE(evaluate("(()=>{const d=document.querySelector('[data-slot=aui_settings_dialog]');const h=document.querySelector('[data-slot=aui_settings_header]');const c=h?.querySelector('[aria-label=\"Close settings\"]');if(!d||!h||!c)return false;const dr=d.getBoundingClientRect(),hr=h.getBoundingClientRect(),cr=c.getBoundingClientRect();return hr.top>=dr.top-1&&hr.bottom<=dr.bottom+1&&cr.top>=dr.top-1&&cr.bottom<=dr.bottom+1})()"))
)
check(
  "final Settings text becomes reachable at the bottom",
  isTRUE(evaluate("(()=>{const d=document.querySelector('[data-slot=aui_settings_dialog]');const p=[...d.querySelectorAll('p')].at(-1);if(!p)return false;const dr=d.getBoundingClientRect(),pr=p.getBoundingClientRect();return pr.top<dr.bottom&&pr.bottom<=dr.bottom+1})()"))
)

check("close Settings after short-screen scroll", click("[aria-label='Close settings']"))
check(
  "select historical session through the real history path",
  wait_for("(()=>{const item=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(x=>x.innerText.includes('Settings history'));const trigger=item?.querySelector('[data-slot=aui_thread-list-item-trigger]');if(!trigger)return false;trigger.click();return true})()")
)
check(
  "restored history uses the selected small assistant size",
  wait_for("(()=>{const t=[...document.querySelectorAll('[data-slot=aui_assistant-text]')].find(x=>x.innerText.includes('HISTORY BODY'));return !!t&&t.dataset.textSize==='small'&&Math.abs(parseFloat(getComputedStyle(t).fontSize)-12)<0.2})()")
)

check(
  "zero console/runtime errors",
  length(browser_errors) == 0L,
  if (length(browser_errors)) paste(unique(browser_errors), collapse = " | ") else "0 errors"
)
logs <- if (file.exists(stdout_path)) readLines(stdout_path, warn = FALSE) else character()
check(
  "Home installed package used",
  any(grepl(paste0("installed=", home_library, "/shinyAssistantUI"), logs, fixed = TRUE)),
  paste(logs, collapse = " | ")
)
cat("ASSISTANT_TEXT_SETTINGS_BROWSER_DONE\n")
