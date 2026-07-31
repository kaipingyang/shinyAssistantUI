suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9762L
unlink(c("/tmp/aui-appr.out", "/tmp/aui-appr.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-54s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/approval_suggestions_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-appr.out", stderr = "/tmp/aui-appr.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-appr.err") && any(grepl("Listening on", readLines("/tmp/aui-appr.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-appr.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 720, height = 820)
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) console_errors <<- c(console_errors, "err"))
browser$Runtime$exceptionThrown(callback_ = function(m) console_errors <<- c(console_errors, "exc"))
value <- function(s) { r <- browser$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
wait_for <- function(s, t = 15, i = 0.05) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(i) } }
press_key <- function(key, code, vk) {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = key, code = code, windowsVirtualKeyCode = vk)
  browser$Input$dispatchKeyEvent(type = "keyUp",   key = key, code = code, windowsVirtualKeyCode = vk)
}
click_sel <- function(sel) {
  j <- value(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", jsonlite::toJSON(sel, auto_unbox = TRUE)))
  if (is.null(j)) return(FALSE); p <- fromJSON(j)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L); TRUE
}
send_msg <- function(text) {
  click_sel(".aui-lexical-input[contenteditable='true']"); Sys.sleep(0.35)
  browser$Input$insertText(text = text); Sys.sleep(0.25)
  press_key("Enter", "Enter", 13L); Sys.sleep(0.3)
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 15))

# ── Round 1: Always-allow(点权限建议 → suggestionIdx)─────────────────────────
send_msg("round one")
# 默认收起:先看到 "Always allow… ▾" 触发器,不直接显示建议。
chk("approval card shows an 'Always allow' toggle", wait_for("!!document.querySelector('[data-approval-always-toggle]')", 15))
chk("suggestion checkboxes are hidden until opened",
    isTRUE(value("document.querySelectorAll('[data-always-check]').length===0")))
click_sel("[data-approval-always-toggle]"); Sys.sleep(0.3)
chk("opening reveals a checkbox per suggestion (2)",
    wait_for("document.querySelectorAll('[data-always-check]').length===2", 8),
    value("document.querySelectorAll('[data-always-check]').length+''"))
chk("suggestion labels present (edits + Bash rule)",
    isTRUE(value("(function(){var t=document.querySelector('[data-approval-always-panel]')?.textContent||'';return t.includes('Always allow edits') && t.includes('Always allow Bash(git status:*)');})()")))
# 勾选两个建议 → 一次 Approve & remember → suggestionIdxs=[0,1]
click_sel("[data-always-check='0']"); Sys.sleep(0.15)
click_sel("[data-always-check='1']"); Sys.sleep(0.15)
click_sel("[data-approval-always-apply]")
chk("multi-select Approve&remember sends approved=true + suggestionIdxs=[0,1]",
    wait_for("(function(){var t=document.getElementById('decision')?.textContent||'';return t.includes('\"approved\":true') && t.includes('\"suggestionIdxs\":[0,1]');})()", 12),
    value("document.getElementById('decision')?.textContent"))

# ── Round 2: Deny 并反馈文本(customMessage)───────────────────────────────────
send_msg("round two")
chk("second approval card pending (Deny & tell Claude visible)", wait_for("!!document.querySelector('[data-approval-deny-with-msg]')", 15))
click_sel("[data-approval-deny-with-msg]"); Sys.sleep(0.3)
chk("deny textarea appears", wait_for("!!document.querySelector('[data-approval-deny-input]')", 8))
click_sel("[data-approval-deny-input]"); Sys.sleep(0.2)
browser$Input$insertText(text = "use grep instead"); Sys.sleep(0.25)
click_sel("[data-approval-deny-send]")
chk("clicking Send&deny sends approved=false + customMessage",
    wait_for("(function(){var t=document.getElementById('decision')?.textContent||'';return t.includes('\"approved\":false') && t.includes('use grep instead');})()", 12),
    value("document.getElementById('decision')?.textContent"))

chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")
try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("APPROVAL_VERIFY_DONE\n")
