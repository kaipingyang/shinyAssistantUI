suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9247L
unlink(c("/tmp/aui-wd.out", "/tmp/aui-wd.err"))
failures <- character()
chk <- function(name, cond, detail = "") {
  ok <- isTRUE(cond); cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
  if (!ok) failures <<- c(failures, name); invisible(ok)
}
app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/working_dir_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-wd.out", stderr = "/tmp/aui-wd.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-wd.err") && any(grepl("Listening on", readLines("/tmp/aui-wd.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-wd.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 900, height = 640)
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
key_enter <- function() { browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L); browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L) }

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 12))

# 工作目录栏显示初始目录 + 该目录 sessions
chk("working-dir bar shows initial dir (dir-A)", wait_for("(document.querySelector('[data-slot=aui_working_dir]')?.getAttribute('data-working-dir')||'').includes('dir-A')", 8))
chk("dir-A sessions listed", wait_for("document.body.innerText.includes('A session')", 8))

# 点击 Change → 手输框出现（native_picker=FALSE）
click_sel("[data-slot=aui_working_dir_change]")
chk("manual input appears (browser fallback)", wait_for("!!document.querySelector('[data-slot=aui_working_dir_input]')", 4))

# 输入 dir-B + Enter → 切目录
value("(function(){const i=document.querySelector('[data-slot=aui_working_dir_input]');i.focus();i.value='/tmp/wd/dir-B';return true})()")
browser$Input$insertText(text = "")  # 确保聚焦（值已设）
key_enter()

chk("working-dir bar updates to dir-B", wait_for("(document.querySelector('[data-slot=aui_working_dir]')?.getAttribute('data-working-dir')||'').includes('dir-B')", 8))
chk("dir-B sessions replace dir-A", wait_for("document.body.innerText.includes('B session') && !document.body.innerText.includes('A session')", 8))

# ── 收藏夹：保存当前(dir-B) → Favorites 出现 → 切到 dir-A → 点收藏跳回 dir-B → 删除 ──
click_sel("[data-slot=aui_working_dir_save]")
chk("favorite saved (dir-B appears in Favorites)", wait_for("!!document.querySelector('[data-slot=aui_project_item][data-project*=dir-B]')", 6))
# 切到 dir-A
click_sel("[data-slot=aui_working_dir_change]")
wait_for("!!document.querySelector('[data-slot=aui_working_dir_input]')", 4)
value("(function(){const i=document.querySelector('[data-slot=aui_working_dir_input]');i.focus();i.value='/tmp/wd/dir-A';return true})()")
key_enter()
chk("switched to dir-A via input", wait_for("(document.querySelector('[data-slot=aui_working_dir]')?.getAttribute('data-working-dir')||'').includes('dir-A')", 8))
# 点收藏的 dir-B → 跳回
click_sel("[data-slot=aui_project_item][data-project*=dir-B] [data-slot=aui_project_jump]")
chk("clicking a favorite jumps to that folder (dir-B)", wait_for("(document.querySelector('[data-slot=aui_working_dir]')?.getAttribute('data-working-dir')||'').includes('dir-B') && document.body.innerText.includes('B session')", 8))
# 删除收藏
click_sel("[data-slot=aui_project_item][data-project*=dir-B] [data-slot=aui_project_remove]")
chk("removing a favorite drops it from the list", wait_for("!document.querySelector('[data-slot=aui_project_item][data-project*=dir-B]')", 6))

chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("WORKING_DIR_VERIFY_DONE\n")
