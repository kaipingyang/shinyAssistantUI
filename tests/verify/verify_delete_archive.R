suppressPackageStartupMessages({
  library(callr); library(chromote); library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9805L
failures <- character()
unlink(c("/tmp/aui-da.out", "/tmp/aui-da.err"))

check <- function(name, condition, detail = "") {
  passed <- isTRUE(condition)
  cat(sprintf("[%s] %-48s %s\n", if (passed) "PASS" else "FAIL", name, detail))
  if (!passed) failures <<- c(failures, name)
  invisible(passed)
}

app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/delete_archive_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-da.out", stderr = "/tmp/aui-da.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)

for (i in seq_len(80)) {
  if (!app$is_alive()) break
  if (file.exists("/tmp/aui-da.err") && any(grepl("Listening on", readLines("/tmp/aui-da.err", warn = FALSE)))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-da.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new()
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)

console_errors <- character(); current_stage <- "boot"
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) {
    text <- paste(vapply(message$args, function(a) as.character(a$value %||% a$description %||% ""), character(1)), collapse = " ")
    console_errors <<- c(console_errors, paste(current_stage, text))
  }
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  d <- message$exceptionDetails
  console_errors <<- c(console_errors, paste(current_stage, "exception:", d$exception$description %||% d$text %||% "?"))
})

value <- function(script) {
  r <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text)
  r$result$value
}
wait_for <- function(script, timeout = 8, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    if (isTRUE(tryCatch(value(script), error = function(e) FALSE))) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
key <- function(name, code, vk) {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = name, code = code, windowsVirtualKeyCode = as.integer(vk))
  browser$Input$dispatchKeyEvent(type = "keyUp", key = name, code = code, windowsVirtualKeyCode = as.integer(vk))
}
type_text <- function(text) {
  value("(function(){const e=document.querySelector('.aui-lexical-input[contenteditable=true]');if(e)e.focus();return !!e})()")
  browser$Input$insertText(text = text)
}
click_sel <- function(sel) {
  j <- value(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", toJSON(sel, auto_unbox = TRUE)))
  if (is.null(j)) return(FALSE)
  p <- fromJSON(j)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L)
  Sys.sleep(0.15); TRUE
}
# 点击某个会话项（按标题文字）的 More 菜单按钮
click_item_more <- function(title) {
  j <- value(sprintf(paste0(
    "(function(){const items=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')];",
    "const it=items.find(x=>x.innerText.includes(%s));if(!it)return null;",
    "const b=it.querySelector('[data-slot=aui_thread-list-item-more]');if(!b)return null;",
    "const r=b.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()"), toJSON(title, auto_unbox = TRUE)))
  if (is.null(j)) return(FALSE)
  p <- fromJSON(j)
  browser$Input$dispatchMouseEvent(type = "mouseMoved", x = p$x, y = p$y)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L)
  Sys.sleep(0.2); TRUE
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("widget mounted", wait_for("!!document.querySelector('.aui-root')", 12))
check("sessions listed", wait_for("document.body.innerText.includes('sess-keep') && document.body.innerText.includes('sess-del')", 8))

# ── 代码高亮 ─────────────────────────────────────────────────────────────────
current_stage <- "highlight"
type_text("show code"); key("Enter", "Enter", 13L)
check("assistant code block is syntax-highlighted",
      wait_for("(function(){const el=document.querySelector('[data-syntax-highlighter=prism]');if(!el)return false;return el.querySelectorAll('code span, span.token').length>0})()", 8))

# ── 侧栏折叠持久化（跨页面重载）────────────────────────────────────────────
current_stage <- "sidebar-persist"
check("sidebar starts expanded", wait_for("document.querySelector('[data-slot=aui_thread_sidebar]')?.getAttribute('data-collapsed')==='false'"))
click_sel("[data-slot=aui_sidebar_toggle]")
check("sidebar collapsed", wait_for("!document.querySelector('[data-slot=aui_thread_sidebar]')", 4))
browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
# 折叠改为“仅本会话、不持久化”（default 展开，方便选历史）→ 重载后回到展开态。
check("sidebar reopens expanded after reload (collapse is session-only, not persisted)",
      wait_for("!!document.querySelector('.aui-root') && document.querySelector('[data-slot=aui_thread_sidebar]')?.getAttribute('data-collapsed')==='false'", 10))
check("sessions still listed after reload", wait_for("document.body.innerText.includes('sess-arch')", 8))

# ── Archive 软隐藏（持久化，可恢复）─────────────────────────────────────────
current_stage <- "archive"
click_item_more("sess-arch")
check("archive menu item present", wait_for("!!document.querySelector('[data-slot=aui_thread-list-item-more-content]')", 4))
# 点击 Archive（菜单里第 3 项，用文字定位）
value("(function(){const its=[...document.querySelectorAll('[data-slot=aui_thread-list-item-more-item]')];const a=its.find(x=>x.innerText.trim()==='Archive');if(a)a.click();return !!a})()")
check("archived session appears in archived section",
      wait_for("(function(){const s=document.querySelector('[data-slot=aui_thread-list-archived]');return !!s && s.innerText.includes('sess-arch')})()", 6))
check("archived session left the active list",
      wait_for("(function(){const items=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')];return !items.some(x=>x.innerText.includes('sess-arch'))})()", 4))

# ── Unarchive 恢复 ───────────────────────────────────────────────────────────
current_stage <- "unarchive"
click_sel("[data-slot=aui_thread-list-unarchive]")
check("unarchived session returns to active list",
      wait_for("(function(){const items=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')];return items.some(x=>x.innerText.includes('sess-arch'))})()", 6))

# ── Delete 二次确认 + 真删 ──────────────────────────────────────────────────
current_stage <- "delete"
value("document.getElementById('deleted-probe').textContent='';true")
click_item_more("sess-del")
value("(function(){const its=[...document.querySelectorAll('[data-slot=aui_thread-list-item-more-item]')];const d=its.find(x=>x.innerText.trim()==='Delete');if(d)d.click();return !!d})()")
check("delete confirmation dialog appears", wait_for("!!document.querySelector('[data-slot=aui_delete_confirm]')", 4))
# 先测试取消不删
click_sel("[data-cancel-delete]")
check("cancel keeps the session", wait_for("document.body.innerText.includes('sess-del') && document.getElementById('deleted-probe').textContent===''", 4))
# 再确认删除
click_item_more("sess-del")
value("(function(){const its=[...document.querySelectorAll('[data-slot=aui_thread-list-item-more-item]')];const d=its.find(x=>x.innerText.trim()==='Delete');if(d)d.click();return !!d})()")
check("delete confirmation dialog appears again", wait_for("!!document.querySelector('[data-slot=aui_delete_confirm]')", 4))
click_sel("[data-confirm-delete]")
check("confirm dialog dismisses immediately after clicking Delete (Bug: stayed open)",
      wait_for("!document.querySelector('[data-slot=aui_delete_confirm]')", 4))
check("confirm calls backend real delete", wait_for("document.getElementById('deleted-probe').textContent==='sess-del'", 6),
      value("document.getElementById('deleted-probe').textContent"))
check("deleted session removed from list and does not reappear",
      wait_for("(function(){const items=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')];return !items.some(x=>x.innerText.includes('sess-del'))})()", 6))

check("no browser console errors", length(console_errors) == 0,
      if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("Chromium verification failed: ", paste(failures, collapse = ", "))
cat("DELETE_ARCHIVE_CHROMIUM_DONE\n")
