suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9420L
unlink(c("/tmp/aui-ask.out", "/tmp/aui-ask.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/askquestion_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-ask.out", stderr = "/tmp/aui-ask.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-ask.err") && any(grepl("Listening on", readLines("/tmp/aui-ask.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-ask.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 720, height = 900)
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) console_errors <<- c(console_errors, "err"))
browser$Runtime$exceptionThrown(callback_ = function(m) console_errors <<- c(console_errors, "exc"))
value <- function(s) { r <- browser$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
wait_for <- function(s, t = 15, i = 0.05) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(i) } }
click_sel <- function(sel) {
  j <- value(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", jsonlite::toJSON(sel, auto_unbox = TRUE)))
  if (is.null(j)) return(FALSE); p <- fromJSON(j)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L); TRUE
}
press_key <- function(key, code, vk) {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = key, code = code, windowsVirtualKeyCode = vk)
  browser$Input$dispatchKeyEvent(type = "keyUp",   key = key, code = code, windowsVirtualKeyCode = vk)
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 15))
click_sel(".aui-lexical-input[contenteditable='true']"); Sys.sleep(0.35)
browser$Input$insertText(text = "go"); Sys.sleep(0.25)
press_key("Enter", "Enter", 13L); Sys.sleep(0.3)

chk("AskUserQuestion card rendered", wait_for("!!document.querySelector('[data-slot=\"ask-user-question\"]')", 15))
chk("two questions rendered", isTRUE(value("document.querySelectorAll('[data-ask-question]').length===2")),
    value("document.querySelectorAll('[data-ask-question]').length+''"))
chk("options rendered (Red/Blue/R/Python)",
    isTRUE(value("['Red','Blue','R','Python'].every(l => !!document.querySelector('[data-ask-option=\"'+l+'\"]'))")))

# 单选 Blue + 多选 R + Python → 提交(用原生 .click() 更可靠)
jclick <- function(sel) value(sprintf("(function(){var e=document.querySelector(%s);if(!e)return false;e.click();return true;})()", jsonlite::toJSON(sel, auto_unbox = TRUE)))
jclick("[data-ask-option='Blue'] input"); Sys.sleep(0.15)
jclick("[data-ask-option='R'] input"); Sys.sleep(0.15)
jclick("[data-ask-option='Python'] input"); Sys.sleep(0.15)
jclick("[data-ask-submit]")
chk("answers round-trip: single=string 'Blue', multi=array ['R','Python']",
    wait_for("(function(){var t=document.getElementById('decision')?.textContent||'';return t.includes('\"Fav color?\":\"Blue\"') && t.includes('\"Which langs?\":[\"R\",\"Python\"]');})()", 12),
    value("document.getElementById('decision')?.textContent"))

chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")
try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("ASKQUESTION_VERIFY_DONE\n")
