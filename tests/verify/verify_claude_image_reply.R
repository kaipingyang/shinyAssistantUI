suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
project <- normalizePath(".", winslash = "/", mustWork = TRUE)
port <- 9650L
unlink(c("/tmp/aui-claude-image.out", "/tmp/aui-claude-image.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond)
  cat(sprintf("[%s] %-55s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name)
  invisible(ok)
}

app <- callr::r_bg(function(project, port) {
  setwd(project)
  readRenviron(file.path(project, ".Renviron"))
  suppressPackageStartupMessages(library(shiny))
  shiny::runApp(
    "tests/verify/claude_backend_app.R",
    host = "127.0.0.1", port = port, launch.browser = FALSE
  )
}, args = list(project = project, port = port),
stdout = "/tmp/aui-claude-image.out", stderr = "/tmp/aui-claude-image.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(160)) {
  if (!app$is_alive()) break
  if (file.exists("/tmp/aui-claude-image.err") &&
      any(grepl("Listening on", readLines("/tmp/aui-claude-image.err", warn = FALSE)))) break
  Sys.sleep(0.1)
}
if (!app$is_alive()) {
  cat(tail(readLines("/tmp/aui-claude-image.err", warn = FALSE), 30), sep = "\n")
  stop("boot failed")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(),
  "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new(width = 900, height = 900)
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) console_errors <<- c(console_errors, "console.error")
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  console_errors <<- c(console_errors, "exception")
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
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
press_enter <- function() {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter",
                                 windowsVirtualKeyCode = 13L)
  browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter",
                                 windowsVirtualKeyCode = 13L)
}
make_image <- function(label, width, height) sprintf(
  paste0(
    "(function(){const c=document.createElement('canvas');c.width=%d;c.height=%d;",
    "const x=c.getContext('2d');const g=x.createLinearGradient(0,0,c.width,c.height);",
    "g.addColorStop(0,'#1463ff');g.addColorStop(1,'#ffcc22');x.fillStyle=g;",
    "x.fillRect(0,0,c.width,c.height);x.fillStyle='white';",
    "x.font='bold 120px sans-serif';x.fillText(%s,c.width/4,c.height/2);",
    "return new Promise(r=>c.toBlob(b=>r(new File([b],%s,{type:'image/png'})),'image/png'))})()"
  ),
  width, height,
  jsonlite::toJSON(label, auto_unbox = TRUE),
  jsonlite::toJSON(paste0(tolower(label), ".png"), auto_unbox = TRUE)
)
add_image <- function(label, method = c("drop", "paste"), width = 1280, height = 640) {
  method <- match.arg(method)
  event_script <- if (method == "paste") {
    "ed.dispatchEvent(new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true}))"
  } else {
    "['dragenter','dragover','drop'].forEach(t=>ed.dispatchEvent(new DragEvent(t,{dataTransfer:dt,bubbles:true,cancelable:true})))"
  }
  script <- sprintf(
    "(async function(){const f=await %s;const dt=new DataTransfer();dt.items.add(f);const ed=document.querySelector('.aui-lexical-input');ed.focus();%s;return true})()",
    make_image(label, width, height), event_script
  )
  isTRUE(value(script, await = TRUE)) && wait_for(
    "!!document.querySelector('.aui-composer-attachments .aui-attachment-root')", 15)
}
assistant_has <- function(text) sprintf(
  "Array.from(document.querySelectorAll('[data-role=assistant]')).some(x=>(x.innerText||'').includes(%s))",
  jsonlite::toJSON(text, auto_unbox = TRUE)
)

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 20))

chk("cold image-only attachment added", add_image("IMAGE64", "drop"))
press_enter()
chk("cold image-only user message sent", wait_for(
  "document.querySelectorAll('.aui-user-message-attachments-end img').length>=1", 20))
chk("cold image-only receives non-empty vision reply", wait_for(
  "Array.from(document.querySelectorAll('[data-role=assistant]')).some(x=>{const t=(x.innerText||'').replace(/●|Copy|Refresh|More/g,'').trim();return t.length>8})", 130),
    value("(function(){const a=document.querySelectorAll('[data-role=assistant]');return a.length?(a[a.length-1].innerText||'').slice(0,300):''})()"))
chk("cold image-only turn fully completed", wait_for(
  "!!document.querySelector('.aui-composer-send') && !document.querySelector('.aui-composer-cancel')", 30))

user_images_before <- value("document.querySelectorAll('.aui-user-message-attachments-end img').length")
chk("pasted image attachment added", add_image("PASTE77", "paste", 640, 320))
value("document.querySelector('.aui-lexical-input').focus();true")
browser$Input$insertText(text = "Reply with exactly PASTE77 if you can see the image.")
press_enter()
chk("pasted image user message sent", wait_for(sprintf(
  "document.querySelectorAll('.aui-user-message-attachments-end img').length>%d",
  as.integer(user_images_before)
), 20))
chk("pasted image receives vision reply", wait_for(assistant_has("PASTE77"), 130),
    value("(function(){const a=document.querySelectorAll('[data-role=assistant]');return a.length?(a[a.length-1].innerText||'').slice(0,300):''})()"))
chk("no browser console errors", length(console_errors) == 0,
    if (length(console_errors)) paste(console_errors, collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("CLAUDE_IMAGE_REPLY_VERIFY_DONE\n")
