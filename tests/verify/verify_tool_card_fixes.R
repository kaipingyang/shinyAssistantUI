suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9362L
unlink(c("/tmp/aui-tcf.out", "/tmp/aui-tcf.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/tool_card_fixes_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-tcf.out", stderr = "/tmp/aui-tcf.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-tcf.err") && any(grepl("Listening on", readLines("/tmp/aui-tcf.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-tcf.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

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

chk("diff view rendered", wait_for("!!document.querySelector('[data-arg-view=\"diff\"]')", 15))

# C: Edit 未设 defaultOpen 也自动展开(diff 内容可见,无需点开)
chk("Edit card is expanded by default (diff visible without click)",
    isTRUE(value("(function(){var e=document.querySelector('[data-arg-view=\"diff\"]');if(!e)return false;var r=e.getBoundingClientRect();return r.height>0 && r.width>0;})()")))

# D: 文件路径按钮显示完整路径(不截断)
chk("file path button shows the FULL path (not truncated basename)",
    isTRUE(value("(function(){var b=document.querySelector('[data-open-file]');if(!b)return false;var t=(b.textContent||'');return t.includes('/edit_target_demo.R') && t.includes(document.querySelector('[data-open-file]').getAttribute('data-open-file'));})()")),
    value("(document.querySelector('[data-open-file]')?.textContent||'').slice(-60)"))

# ③ 标题:显示文件名,不再 Edit(false)
chk("title shows file basename (not Edit(false))",
    isTRUE(value("(function(){var t=document.body.innerText||'';return t.includes('edit_target_demo.R') && !t.includes('Edit(false)');})()")),
    value("(document.body.innerText.match(/Edit\\([^)]*\\)/)||['<none>'])[0]"))

# ④ diff 行号:出现真实行号 4(而非从 1)
chk("diff gutter shows real line number 4 (not 1)",
    isTRUE(value("Array.from(document.querySelectorAll('[data-slot=\"diff-viewer-line-number\"]')).some(e => (e.textContent||'').trim()==='4')")),
    value("Array.from(document.querySelectorAll('[data-slot=\"diff-viewer-line-number\"]')).map(e=>(e.textContent||'').trim()).join(',')"))

chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")
try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("TOOL_CARD_FIXES_VERIFY_DONE\n")
