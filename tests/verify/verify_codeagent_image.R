# Real codeagent workbench multimodal smoke for example 27.
suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
project <- normalizePath(".", winslash = "/", mustWork = TRUE)
port <- 9654L
logs <- c("/tmp/aui-codeagent-image.out", "/tmp/aui-codeagent-image.err")
unlink(logs)
failures <- character()
check <- function(name, condition, detail = "") {
  ok <- isTRUE(condition)
  cat(sprintf("[%s] %-55s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
}
app <- callr::r_bg(function(project, port) {
  setwd(project)
  Sys.setenv(CODEAGENT_DEMO_PROFILE = "workbench")
  suppressPackageStartupMessages(library(shiny))
  shiny::runApp("examples/27_codeagent_backend.R", host = "127.0.0.1",
                port = port, launch.browser = FALSE)
}, args = list(project = project, port = port),
stdout = logs[[1L]], stderr = logs[[2L]])
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(200)) {
  if (!app$is_alive()) break
  if (file.exists(logs[[2L]]) && any(grepl("Listening on", readLines(logs[[2L]], warn = FALSE)))) break
  Sys.sleep(0.1)
}
if (!app$is_alive()) stop("workbench image fixture failed to boot")

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 900, height = 900)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)
errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) errors <<- c(errors, "console.error")
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  errors <<- c(errors, "Runtime.exceptionThrown")
})
value <- function(script, await = FALSE) {
  result <- browser$Runtime$evaluate(script, returnByValue = TRUE, awaitPromise = await)
  if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text)
  result$result$value
}
wait_for <- function(script, timeout = 30, interval = 0.1) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(script), error = function(e) FALSE))) return(TRUE)
    if (!app$is_alive() || Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
press_enter <- function() {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
}
make_image <- paste0(
  "(function(){const c=document.createElement('canvas');c.width=900;c.height=400;",
  "const x=c.getContext('2d');x.fillStyle='#174ea6';x.fillRect(0,0,c.width,c.height);",
  "x.fillStyle='white';x.font='bold 96px sans-serif';x.fillText('CAIMAGE65',150,235);",
  "return new Promise(r=>c.toBlob(b=>r(new File([b],'caimage65.png',{type:'image/png'})),'image/png'))})()"
)

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("widget mounted", wait_for("!!document.querySelector('.aui-root')", 20))
added <- value(sprintf(paste0(
  "(async function(){const f=await %s;const dt=new DataTransfer();dt.items.add(f);",
  "const ed=document.querySelector('.aui-lexical-input');ed.focus();",
  "ed.dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}));",
  "return true})()"), make_image), await = TRUE)
check("image attachment added", isTRUE(added) && wait_for(
  "!!document.querySelector('.aui-composer-attachments .aui-attachment-root')", 15))
value("document.querySelector('.aui-lexical-input').focus();true")
browser$Input$insertText(text = "Reply with exactly the large white text shown in the image, and nothing else.")
press_enter()
check("image sent in user message", wait_for(
  "document.querySelectorAll('.aui-user-message-attachments-end img').length>=1", 20))
completed <- wait_for(
  "!!document.querySelector('.aui-composer-send') && !document.querySelector('.aui-composer-cancel')", 150)
assistant_text <- value(paste0(
  "Array.from(document.querySelectorAll('[data-role=assistant]'))",
  ".map(x=>x.innerText||'').join(' || ')"
))
check("turn completed", completed)
check("real codeagent vision reply", grepl("CAIMAGE65", assistant_text, fixed = TRUE),
      substr(assistant_text, 1, 500))
check("zero console errors or exceptions", length(errors) == 0L,
      if (length(errors)) paste(errors, collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("CODEAGENT_IMAGE_VERIFY_DONE\n")
