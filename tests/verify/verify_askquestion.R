suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9633L
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
click_thread <- function(label) {
  j <- value(sprintf(
    "(function(){const e=Array.from(document.querySelectorAll('[data-slot=aui_thread-list-item]')).find(x=>(x.innerText||'').includes(%s));if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+20,y:r.top+r.height/2})})()",
    jsonlite::toJSON(label, auto_unbox = TRUE)
  ))
  if (is.null(j)) return(FALSE)
  p <- fromJSON(j)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L)
  TRUE
}
chk("options rendered (Red/Blue/R/Python)",
    isTRUE(value("['Red','Blue','R','Python'].every(l => !!document.querySelector('[data-ask-option=\"'+l+'\"]'))")))

chk("tool args use readable questions view (not JSON)",
    isTRUE(value("!!document.querySelector('[data-arg-view=\"questions\"]') && !document.querySelector('[data-args-format=\"json\"]') && document.querySelector('[data-arg-view=\"questions\"]').innerText.includes('Single choice') && document.querySelector('[data-arg-view=\"questions\"]').innerText.includes('Multiple choice')")))

# BUG回归：单选先 Blue 再输入 Teal → Other 必须接管；多选 R + SQL 可叠加。
jclick <- function(sel) value(sprintf("(function(){var e=document.querySelector(%s);if(!e)return false;e.click();return true;})()", jsonlite::toJSON(sel, auto_unbox = TRUE)))
jclick("[data-ask-option='Blue'] input"); Sys.sleep(0.15)
value("document.querySelector('[data-ask-custom=\"0\"]').focus(); true")
browser$Input$insertText(text = "Teal"); Sys.sleep(0.15)
jclick("[data-ask-option='R'] input"); Sys.sleep(0.15)
value("document.querySelector('[data-ask-custom=\"1\"]').focus(); true")
browser$Input$insertText(text = "SQL"); Sys.sleep(0.15)
chk("single Other becomes selected and old Blue is cleared",
    isTRUE(value("document.querySelector('[data-ask-custom-selector=\"0\"]').checked && !document.querySelector('[data-ask-option=\"Blue\"] input').checked")))
chk("multi Other is checked alongside R",
    isTRUE(value("document.querySelector('[data-ask-custom-selector=\"1\"]').checked && document.querySelector('[data-ask-option=\"R\"] input').checked")))
jclick("[data-ask-submit]")
chk("answers round-trip: custom overrides single; multi includes custom",
    wait_for("(function(){var t=document.getElementById('decision')?.textContent||'';return t.includes('\\\"Fav color?\\\":\\\"Teal\\\"') && t.includes('\\\"Which langs?\\\":[\\\"R\\\",\\\"SQL\\\"]');})()", 12),
    value("document.getElementById('decision')?.textContent"))

# session-load / 历史完成态：answers必须保留在结构化视图，不能恢复审批表单。
chk("clicked AskUserQuestion history thread", click_thread("Ask history"))
chk("historical AskUserQuestion loaded", wait_for(
    "document.body.innerText.includes('Historical answers restored')", 8))
chk("history keeps structured questions and submitted answers",
    isTRUE(value("(function(){const v=document.querySelector('[data-arg-view=questions]');return !!v && !document.querySelector('[data-args-format=json]') && v.innerText.includes('Answer:') && v.innerText.includes('Teal') && v.innerText.includes('R, SQL');})()")))
chk("history does not restore interactive question form",
    isTRUE(value("!document.querySelector('[data-slot=ask-user-question]')")))
chk("history preserves approved completion state",
    isTRUE(value("document.querySelector('[data-approval-result=approved]')?.innerText.includes('Approved')")))

chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")
try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("ASKQUESTION_VERIFY_DONE\n")
