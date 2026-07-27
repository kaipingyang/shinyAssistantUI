suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
proj <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; port <- 9319L
unlink(c("/tmp/cq.out", "/tmp/cq.err")); failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/current_question_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = proj, port = port), stdout = "/tmp/cq.out", stderr = "/tmp/cq.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in 1:120) { if (!app$is_alive()) break
  if (file.exists("/tmp/cq.err") && any(grepl("Listening on", readLines("/tmp/cq.err", warn = FALSE)))) break
  Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/cq.err", warn = FALSE), 15), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
b <- ChromoteSession$new(width = 620, height = 480)
on.exit({ try(b$close(), silent = TRUE); try(b$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
errs <- character(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) errs <<- c(errs, "e"))
b$Runtime$exceptionThrown(callback_ = function(m) errs <<- c(errs, "x"))
val <- function(s) { r <- b$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
wait <- function(s, t = 15) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(val(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(0.1) } }
click_sel <- function(sel) { j <- val(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", toJSON(sel, auto_unbox = TRUE))); if (is.null(j)) return(FALSE); p <- fromJSON(j); b$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L); b$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L); TRUE }
send <- function(text, n) {
  click_sel(".aui-lexical-input[contenteditable='true']"); Sys.sleep(0.3)
  b$Input$insertText(text = text); Sys.sleep(0.2)
  b$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  b$Input$dispatchKeyEvent(type = "keyUp",   key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
  wait(sprintf("document.querySelectorAll('[data-role=\"user\"]').length >= %d", n), 15)
}
barText <- function() val("(document.querySelector('[data-slot=aui_current_question]')||{}).textContent||''")
setScroll <- function(topExpr) { val(sprintf("(function(){var v=document.querySelector('[data-slot=aui_thread-viewport]');v.scrollTop=%s;return true})()", topExpr)); Sys.sleep(0.5) }

b$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); b$Page$loadEventFired()
chk("widget mounted", wait("!!document.querySelector('.aui-root')", 12))
send("QUESTION ONE alpha", 1)
send("QUESTION TWO beta", 2)
send("QUESTION THREE gamma", 3)
chk("three user turns present", isTRUE(val("document.querySelectorAll('[data-role=\"user\"]').length>=3")))
chk("pinned bar exists (content overflows)", wait("!!document.querySelector('[data-slot=aui_current_question]')", 8))

setScroll("0")  # 滚到顶
chk("scrolled to top -> bar shows Q1 (ONE), not Q3", isTRUE({ t <- barText(); grepl("ONE", t) && !grepl("THREE", t) }), barText())

setScroll("v.scrollHeight")  # 滚到底
chk("scrolled to bottom -> bar shows Q3 (THREE)", isTRUE(grepl("THREE", barText())), barText())

chk("no browser console errors", length(errs) == 0, if (length(errs)) paste(utils::head(errs, 3), collapse = " | ") else "0 errors")
try(b$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("CURRENT_QUESTION_VERIFY_DONE\n")
