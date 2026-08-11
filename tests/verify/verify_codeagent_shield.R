suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- normalizePath(".", winslash = "/", mustWork = TRUE)
port <- 9652L
secret <- "PLAN65_BROWSER_PRIVATE_4Q"
logs <- c("/tmp/aui-codeagent-shield.out", "/tmp/aui-codeagent-shield.err")
unlink(logs)
failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-58s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(function(project, port) {
  setwd(project)
  suppressPackageStartupMessages(library(shiny))
  shiny::runApp(
    "tests/verify/codeagent_shield_app.R",
    host = "127.0.0.1", port = port, launch.browser = FALSE
  )
}, args = list(project = project, port = port),
stdout = logs[[1L]], stderr = logs[[2L]])
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(120)) {
  if (!app$is_alive()) break
  if (file.exists(logs[[2L]]) &&
      any(grepl("Listening on", readLines(logs[[2L]], warn = FALSE)))) break
  Sys.sleep(0.1)
}
if (!app$is_alive()) {
  if (file.exists(logs[[2L]])) cat(tail(readLines(logs[[2L]], warn = FALSE), 30), sep = "\n")
  stop("codeagent shield fixture failed to boot")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 850, height = 900)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)
console_errors <- character()
websocket_frames <- character()
browser$Runtime$enable()
browser$Network$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) console_errors <<- c(console_errors, "console.error")
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  console_errors <<- c(console_errors, "Runtime.exceptionThrown")
})
browser$Network$webSocketFrameReceived(callback_ = function(message) {
  payload <- message$response$payloadData %||% ""
  websocket_frames <<- c(websocket_frames, payload)
})

value <- function(script) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}
wait_for <- function(script, timeout = 20, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(script), error = function(e) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
press_enter <- function() {
  browser$Input$dispatchKeyEvent(
    type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
  browser$Input$dispatchKeyEvent(
    type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L
  )
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("widget mounted", wait_for("!!document.querySelector('.aui-root')", 15))
value("document.querySelector('.aui-lexical-input').focus();true")
browser$Input$insertText(text = "run deterministic shield check")
press_enter()

# During the upstream delay the raw chunks/tool payload have already fired on R.
# They must still be absent from both DOM and decoded WebSocket frames.
Sys.sleep(0.25)
check(
  "raw split text absent before final scan",
  !isTRUE(value(sprintf("document.body.innerText.includes(%s)",
    jsonlite::toJSON(secret, auto_unbox = TRUE))))
)
check(
  "raw text absent from WebSocket frames before final scan",
  !grepl(secret, paste(websocket_frames, collapse = "\n"), fixed = TRUE)
)

safe_script <- sprintf(
  "Array.from(document.querySelectorAll('[data-role=assistant]')).some(x=>(x.innerText||'').includes(%s))",
  jsonlite::toJSON("Shielded answer: [PROTECTED]", auto_unbox = TRUE)
)
check("scanned response released", wait_for(safe_script, 15))
check(
  "turn completed",
  wait_for("!!document.querySelector('.aui-composer-send') && !document.querySelector('.aui-composer-cancel')", 8)
)
body_text <- value("document.body.innerText")
check("raw value absent from final DOM", !grepl(secret, body_text, fixed = TRUE))
expanded <- value(paste0(
  "(function(){const b=document.querySelector('[data-slot=tool-fallback-trigger]');",
  "if(!b)return false;b.click();return true})()"
))
check("safe tool card expands", expanded)
check("safe tool result rendered", wait_for(
  "document.body.innerText.includes('SAFE_TOOL_RESULT_65')", 5
))
body_text <- value("document.body.innerText")
check("projected tool name remains visible", grepl("Ru R", body_text, fixed = TRUE),
      substr(body_text, 1, 1000))
check(
  "raw value absent from every WebSocket frame",
  !grepl(secret, paste(websocket_frames, collapse = "\n"), fixed = TRUE)
)
check(
  "rich image payload suppressed",
  !grepl("UNSAFE_", paste(websocket_frames, collapse = "\n"), fixed = TRUE)
)

first_tool_count <- value("document.querySelectorAll('[data-slot=tool-fallback-root]').length")
value("document.querySelector('.aui-lexical-input').focus();true")
browser$Input$insertText(text = "run deterministic shield check again")
press_enter()
check(
  "second Shield turn completes",
  wait_for("!!document.querySelector('.aui-composer-send') && !document.querySelector('.aui-composer-cancel')", 15)
)
check(
  "second turn creates a distinct tool card",
  wait_for(sprintf(
    "document.querySelectorAll('[data-slot=tool-fallback-root]').length>%d",
    as.integer(first_tool_count)
  ), 8)
)
check(
  "all two-turn WebSocket frames remain secret-free",
  !grepl(secret, paste(websocket_frames, collapse = "\n"), fixed = TRUE)
)

check(
  "usage ring rendered from codeagent context usage",
  wait_for("!!document.querySelector('[data-slot=\"context-display-trigger\"] svg circle')", 8)
)
value(paste0(
  "(function(){var e=document.querySelector('[data-slot=\"context-display-trigger\"]');",
  "if(!e)return false;e.focus();",
  "e.dispatchEvent(new PointerEvent('pointermove',{bubbles:true}));",
  "e.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));return true;})()"
))
check(
  "usage tooltip shows about 12.3 percent",
  wait_for("/12(\\.3)?%/.test(document.querySelector('[data-slot=\"context-display-popover\"]')?.textContent||'')", 8),
  value("document.querySelector('[data-slot=\"context-display-popover\"]')?.textContent||''")
)
check(
  "zero console errors or exceptions",
  length(console_errors) == 0L,
  if (length(console_errors)) paste(console_errors, collapse = " | ") else "0 errors"
)

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("CODEAGENT_SHIELD_BROWSER_VERIFY_DONE\n")
