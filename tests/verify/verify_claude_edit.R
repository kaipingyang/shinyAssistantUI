suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9405L
unlink(c("/tmp/aui-ce.out", "/tmp/aui-ce.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-56s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); Sys.setenv(AUI_PORT = port); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/claude_edit_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-ce.out", stderr = "/tmp/aui-ce.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(120)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-ce.err") && any(grepl("Listening on", readLines("/tmp/aui-ce.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-ce.err", warn = FALSE), 25), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 780, height = 900)
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) console_errors <<- c(console_errors, "err"))
browser$Runtime$exceptionThrown(callback_ = function(m) console_errors <<- c(console_errors, "exc"))
value <- function(s) { r <- browser$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
wait_for <- function(s, t = 40, i = 0.1) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(i) } }
click_native <- function(js_el) value(sprintf("(function(){const e=%s;if(!e)return false;e.click();return true})()", js_el))
click_xy <- function(sel) {
  j <- value(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", jsonlite::toJSON(sel, auto_unbox = TRUE)))
  if (is.null(j)) return(FALSE); p <- fromJSON(j)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L); TRUE
}
hover_msg <- function() {
  j <- value("(function(){const m=document.querySelector('[data-role=\"user\"] .aui-user-message-content')||document.querySelector('[data-role=\"user\"]');if(!m)return null;const r=m.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()")
  if (is.null(j)) return(FALSE); p <- fromJSON(j); browser$Input$dispatchMouseEvent(type = "mouseMoved", x = p$x, y = p$y); TRUE
}
press_key <- function(key, code, vk, mods = 0L) {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = key, code = code, windowsVirtualKeyCode = vk, modifiers = mods)
  browser$Input$dispatchKeyEvent(type = "keyUp",   key = key, code = code, windowsVirtualKeyCode = vk, modifiers = mods)
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 20))
# 1) 首发:让 Claude 只回一个词 BANANA
click_xy(".aui-lexical-input[contenteditable='true']"); Sys.sleep(0.4)
browser$Input$insertText(text = "Reply with exactly one word: BANANA . No other text."); Sys.sleep(0.3)
press_key("Enter", "Enter", 13L)
chk("Claude first reply (BANANA)", wait_for("/BANANA/i.test(document.body.innerText)", 45),
    value("document.body.innerText.replace(/\\s+/g,' ').slice(-60)"))
Sys.sleep(1.0)
# 2) hover 用户气泡 → pencil → edit
hover_msg(); Sys.sleep(0.4)
chk("edit pencil appears on hover", wait_for("!!document.querySelector('svg.lucide-pencil')", 8))
click_native("document.querySelector('svg.lucide-pencil')?.closest('button')")
chk("edit composer opened", wait_for("!!document.querySelector('.aui-edit-composer-input')", 6))
# 3) 改文本 → 要求回 CHERRY
click_xy(".aui-edit-composer-input"); Sys.sleep(0.25)
press_key("a", "KeyA", 65L, mods = 2L); Sys.sleep(0.1)
browser$Input$insertText(text = "Reply with exactly one word: CHERRY . No other text."); Sys.sleep(0.3)
# 4) Update
upd <- click_native("Array.from(document.querySelectorAll('.aui-edit-composer-root button')).find(b=>/update/i.test(b.textContent))")
chk("clicked Update", isTRUE(upd))
# 5) 期望 Claude 重新回答 CHERRY(证明 make_claude_handler 的 edit→resend 生效)
chk("edit->Update RE-TRIGGERS Claude (CHERRY)", wait_for("/CHERRY/i.test(document.body.innerText)", 45),
    value("document.body.innerText.replace(/\\s+/g,' ').slice(-80)"))

chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")
try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("CLAUDE_EDIT_VERIFY_DONE\n")
