# Plan 77 Chromium gate: compact = full-width input row + independent action row.
suppressPackageStartupMessages({ library(chromote); library(callr); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9841L
failures <- character()
chk <- function(name, condition, detail = "") {
  passed <- isTRUE(condition)
  cat(sprintf("[%s] %-52s %s\n", if (passed) "PASS" else "FAIL", name, detail))
  if (!passed) failures <<- c(failures, name)
}

app <- callr::r_bg(function(project, port) {
  setwd(project)
  Sys.setenv(AUI_TEST_DENSITY = "compact")
  suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/settings_ux_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-compact.out", stderr = "/tmp/aui-compact.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) {
  if (!app$is_alive()) break
  if (file.exists("/tmp/aui-compact.err") && any(grepl("Listening on", readLines("/tmp/aui-compact.err", warn = FALSE)))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) stop("compact verification app failed to boot")

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 760, height = 560)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)
value <- function(js) {
  result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}
wait_for <- function(js, timeout = 10) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(js), error = function(e) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(0.05)
  }
}
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(event) {
  if (identical(event$type, "error")) console_errors <<- c(console_errors, "console-error")
})
browser$Runtime$exceptionThrown(callback_ = function(event) {
  console_errors <<- c(console_errors, "exception")
})

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
chk("compact composer shell loads", wait_for("!!document.querySelector('[data-slot=aui_composer-shell][data-density=compact]')"))
value("(function(){const e=document.querySelector('.aui-lexical-input[contenteditable=true]');if(e)e.focus();return !!e})()")
browser$Input$insertText(text = "show usage")
browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
chk("usage data renders its action-row ring", wait_for("!!document.querySelector('[data-slot=context-display-trigger]')"))
layout <- fromJSON(value(paste0(
  "(function(){const s=document.querySelector('[data-slot=aui_composer-shell]'),",
  "i=s?.querySelector('.aui-composer-input'),a=s?.querySelector('.aui-composer-action-wrapper');",
  "if(!s||!i||!a)return JSON.stringify({ok:false});const sr=s.getBoundingClientRect(),ir=i.getBoundingClientRect(),ar=a.getBoundingClientRect();",
  "return JSON.stringify({ok:true,shellWidth:sr.width,shellHeight:sr.height,inputWidth:ir.width,inputTop:ir.top,inputBottom:ir.bottom,",
  "actionTop:ar.top,actionBottom:ar.bottom,legacy:!!s.querySelector('.aui-composer-compact-row'),",
  "attachment:!!a.querySelector('[aria-label=\"Add Attachment\"]'),permission:!!a.querySelector('select[aria-label=\"Permission mode\"]'),",
  "model:!!a.querySelector('[data-slot=model-selector-trigger]'),usage:!!a.querySelector('[data-slot=context-display-trigger]'),",
  "send:!!a.querySelector('.aui-composer-send')})})()"
)))
chk("legacy one-row compact branch is absent", isTRUE(layout$ok) && !isTRUE(layout$legacy))
chk("input occupies the compact shell content width", layout$inputWidth >= layout$shellWidth - 12,
    sprintf("input=%.1f shell=%.1f", layout$inputWidth, layout$shellWidth))
chk("action row is below input without overlap", layout$actionTop >= layout$inputBottom - 1,
    sprintf("inputBottom=%.1f actionTop=%.1f", layout$inputBottom, layout$actionTop))
chk("compact shell remains approximately 64-72px high", layout$shellHeight <= 76,
    sprintf("height=%.1f", layout$shellHeight))
chk("attachment remains in action row", isTRUE(layout$attachment))
chk("permission remains in action row", isTRUE(layout$permission))
chk("model remains in action row", isTRUE(layout$model))
chk("usage remains in action row", isTRUE(layout$usage))
chk("send remains in action row", isTRUE(layout$send))
chk("no browser console/runtime errors", length(console_errors) == 0,
    sprintf("errors=%d", length(console_errors)))

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
unlink(c("/tmp/aui-compact.out", "/tmp/aui-compact.err"))
if (length(failures)) stop("compact verification failed: ", paste(failures, collapse = ", "))
cat("COMPACT_TWO_ROW_VERIFY_DONE\n")
