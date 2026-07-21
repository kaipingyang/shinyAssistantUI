suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9255L
unlink(c("/tmp/aui-think.out", "/tmp/aui-think.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-46s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/thinking_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-think.out", stderr = "/tmp/aui-think.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-think.err") && any(grepl("Listening on", readLines("/tmp/aui-think.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-think.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 900, height = 700)
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(m) if (identical(m$type, "error")) console_errors <<- c(console_errors, "err"))
browser$Runtime$exceptionThrown(callback_ = function(m) console_errors <<- c(console_errors, "exc"))
value <- function(s) { r <- browser$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
wait_for <- function(s, t = 12, i = 0.05) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(i) } }
click_sel <- function(sel) {
  j <- value(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", jsonlite::toJSON(sel, auto_unbox = TRUE)))
  if (is.null(j)) return(FALSE); p <- fromJSON(j)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L); TRUE
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 12))
# 打开 Settings
click_sel("[aria-label=Settings]")
chk("thinking selector present in Settings", wait_for("!!document.querySelector('select[aria-label=\"Thinking level\"]')", 6))
chk("thinking defaults to 'default'", isTRUE(value("document.querySelector('select[aria-label=\"Thinking level\"]')?.value==='default'")))
# 改为 Extended(enabled)
value("(function(){const s=document.querySelector('select[aria-label=\"Thinking level\"]');s.value='enabled';s.dispatchEvent(new Event('change',{bubbles:true}));return true})()")
chk("thinking action reaches backend (probe = thinking:enabled)", wait_for("(document.getElementById('probe')?.textContent||'').includes('thinking:enabled')", 8),
    value("document.getElementById('probe')?.textContent"))
chk("selector shows the new value optimistically", wait_for("document.querySelector('select[aria-label=\"Thinking level\"]')?.value==='enabled'", 4))
# 模型选择器（#1 /model）：命令菜单里的 /model → 弹选择器 → 点选确认
press_key <- function(key, code, vk) {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = key, code = code, windowsVirtualKeyCode = vk)
  browser$Input$dispatchKeyEvent(type = "keyUp",   key = key, code = code, windowsVirtualKeyCode = vk)
}
click_sel(".aui-lexical-input[contenteditable='true']")   # 聚焦 composer
browser$Input$insertText(text = "/model")
press_key("Escape", "Escape", 27L)   # 关闭 slash 弹层，保留 "/model" 文本
press_key("Enter",  "Enter",  13L)   # 提交 → matchSlashAction 拦截 /model → 开选择器
chk("/model opens the model picker dialog", wait_for("!!document.querySelector('[role=\"dialog\"][aria-label=\"Select model\"]')", 6))
chk("picker lists model options", isTRUE(value("!!document.querySelector('[data-model-option=\"sonnet\"]')")))
click_sel("[data-model-option=\"sonnet\"]")               # 点选 Sonnet 确认
chk("picking a model reaches backend (probe = model:sonnet)", wait_for("(document.getElementById('probe')?.textContent||'').includes('model:sonnet')", 8),
    value("document.getElementById('probe')?.textContent"))
chk("picker closes after pick", wait_for("!document.querySelector('[role=\"dialog\"][aria-label=\"Select model\"]')", 4))
chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("THINKING_VERIFY_DONE\n")
