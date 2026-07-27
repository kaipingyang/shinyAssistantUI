suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9302L
unlink(c("/tmp/aui-md.out", "/tmp/aui-md.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/markdown_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-md.out", stderr = "/tmp/aui-md.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-md.err") && any(grepl("Listening on", readLines("/tmp/aui-md.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-md.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 700, height = 760)
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) console_errors <<- c(console_errors, "err"))
browser$Runtime$exceptionThrown(callback_ = function(m) console_errors <<- c(console_errors, "exc"))
value <- function(s) { r <- browser$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
wait_for <- function(s, t = 12, i = 0.05) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(i) } }
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

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 12))
click_sel(".aui-lexical-input[contenteditable='true']"); Sys.sleep(0.4)
browser$Input$insertText(text = "go"); Sys.sleep(0.3)
press_key("Enter", "Enter", 13L); Sys.sleep(0.3)
chk("markdown rendered", wait_for("!!document.querySelector('.aui-md-a')", 12))

chk("link opens in new tab (target=_blank)", isTRUE(value("document.querySelector('.aui-md-a')?.getAttribute('target')==='_blank'")))
chk("link has rel=noopener", isTRUE(value("(document.querySelector('.aui-md-a')?.getAttribute('rel')||'').includes('noopener')")))
chk("link href preserved", isTRUE(value("(document.querySelector('.aui-md-a')?.getAttribute('href')||'').includes('example.com')")))

chk("table wrapped in horizontal scroller", wait_for("!!document.querySelector('.aui-md-table-wrap')", 6))
chk("wide table overflows -> scrollable (not clipped)",
    isTRUE(value("(function(){const w=document.querySelector('.aui-md-table-wrap');return !!w && w.scrollWidth > w.clientWidth;})()")),
    value("(function(){const w=document.querySelector('.aui-md-table-wrap');return w? w.scrollWidth+'>'+w.clientWidth : 'none';})()"))

chk("file path is a clickable ref", wait_for("!!document.querySelector('code[data-file-ref=\"R/app.R\"]')", 6))
click_sel("code[data-file-ref=\"R/app.R\"]")
chk("clicking file path fires open_file (probe = R/app.R:12)", wait_for("(document.getElementById('probe')?.textContent||'').includes('R/app.R:12')", 6),
    value("document.getElementById('probe')?.textContent"))

# 角度1：R 代码块上出现"Run in Console"按钮,点击 → on_run_in_console 收到代码
chk("R code block shows a Run-in-Console button", wait_for("!!document.querySelector('[data-run-in-console]')", 6))
click_sel("[data-run-in-console]")
chk("clicking Run sends code to console callback (ran contains mean(x))",
    wait_for("(document.getElementById('ran')?.textContent||'').includes('mean(x)')", 6),
    value("document.getElementById('ran')?.textContent"))
# Angle A：捕获结果自动喂回 Claude —— handler 收到含输出的消息(lastmsg 含 RESULT_42)
chk("console result is auto-submitted back to the model (lastmsg has RESULT_42)",
    wait_for("(document.getElementById('lastmsg')?.textContent||'').includes('RESULT_42')", 8),
    value("(document.getElementById('lastmsg')?.textContent||'').slice(0,80)"))

# 未知/无语言代码块 → 标签显示 "markdown"(不再硬当 r)
chk("unlabeled code block header shows 'markdown' (not 'r')",
    isTRUE(value("Array.from(document.querySelectorAll('.aui-code-header-language')).some(e => (e.textContent||'').trim()==='markdown')")),
    value("Array.from(document.querySelectorAll('.aui-code-header-language')).map(e=>(e.textContent||'').trim()).join('|')"))
# 行内 code → 蓝字(oklch 蓝色相 ~264 或 rgb 蓝通道最强),不再黑/灰
chk("inline code text is blue",
    isTRUE(value("(function(){var e=document.querySelector('.aui-md-inline-code');if(!e)return false;var c=getComputedStyle(e).color;if(/oklch/i.test(c)){var n=c.match(/[\\d.]+/g);var h=parseFloat(n[n.length-1]);return h>=220&&h<=290;}var m=c.match(/\\d+/g);return m&&(+m[2])>(+m[0])&&(+m[2])>(+m[1])&&(+m[2])>100;})()")),
    value("(function(){var e=document.querySelector('.aui-md-inline-code');return e?getComputedStyle(e).color:'none';})()"))

chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")
try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("MARKDOWN_VERIFY_DONE\n")
