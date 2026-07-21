suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})

`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9217L
failures <- character()
unlink(c("/tmp/aui-openfile.out", "/tmp/aui-openfile.err"))

check <- function(name, condition, detail = "") {
  passed <- isTRUE(condition)
  cat(sprintf("[%s] %-46s %s\n", if (passed) "PASS" else "FAIL", name, detail))
  if (!passed) failures <<- c(failures, name)
  invisible(passed)
}

app <- callr::r_bg(
  function(project, port) {
    setwd(project)
    suppressPackageStartupMessages(library(shiny))
    shiny::runApp("tests/verify/openfile_reveal_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
  },
  args = list(project = project, port = port),
  stdout = "/tmp/aui-openfile.out", stderr = "/tmp/aui-openfile.err"
)
on.exit(try(app$kill(), silent = TRUE), add = TRUE)

for (i in seq_len(80)) {
  if (!app$is_alive()) break
  if (file.exists("/tmp/aui-openfile.err") &&
      any(grepl("Listening on", readLines("/tmp/aui-openfile.err", warn = FALSE)))) break
  Sys.sleep(0.25)
}
if (!app$is_alive()) {
  cat(tail(readLines("/tmp/aui-openfile.err", warn = FALSE), 20), sep = "\n")
  stop("Browser fixture failed to boot")
}

chromote::set_chrome_args(unique(c(
  chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
)))
browser <- ChromoteSession$new()
on.exit({
  try(browser$close(), silent = TRUE)
  try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE)
}, add = TRUE)

console_errors <- character()
current_stage <- "boot"
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) {
    text <- paste(vapply(message$args, function(arg) as.character(arg$value %||% arg$description %||% ""), character(1)), collapse = " ")
    console_errors <<- c(console_errors, paste(current_stage, "console:", text))
  }
})
browser$Runtime$exceptionThrown(callback_ = function(message) {
  detail <- message$exceptionDetails
  console_errors <<- c(console_errors, paste(current_stage, "exception:", detail$exception$description %||% detail$text %||% "unknown"))
})

value <- function(script) {
  response <- browser$Runtime$evaluate(script, returnByValue = TRUE)
  if (!is.null(response$exceptionDetails)) stop(response$exceptionDetails$text)
  response$result$value
}
wait_for <- function(script, timeout = 8, interval = 0.05) {
  deadline <- Sys.time() + timeout
  repeat {
    answer <- tryCatch(value(script), error = function(e) FALSE)
    if (isTRUE(answer)) return(TRUE)
    if (Sys.time() >= deadline) return(FALSE)
    Sys.sleep(interval)
  }
}
key <- function(name, code, virtual_key, modifiers = 0L) {
  browser$Input$dispatchKeyEvent(type = "keyDown", key = name, code = code,
    windowsVirtualKeyCode = as.integer(virtual_key), modifiers = as.integer(modifiers))
  browser$Input$dispatchKeyEvent(type = "keyUp", key = name, code = code,
    windowsVirtualKeyCode = as.integer(virtual_key), modifiers = as.integer(modifiers))
}
focus_editor <- function() value("(function(){const e=document.querySelector('.aui-lexical-input[contenteditable=true]');if(e)e.focus();return !!e})()")
type_text <- function(text) { focus_editor(); browser$Input$insertText(text = text) }
click_sel <- function(sel) {
  j <- value(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", jsonlite::toJSON(sel, auto_unbox = TRUE)))
  if (is.null(j)) return(FALSE)
  p <- fromJSON(j)
  browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
  browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L)
  TRUE
}

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
browser$Page$loadEventFired()
check("widget mounted", wait_for("!!document.querySelector('.aui-root')", 12))
check("Lexical composer mounted", wait_for("!!document.querySelector('.aui-lexical-input[contenteditable=true]')"))

# ── IDE 文件上下文：仅有文件(无选区)时，chip 与“眼睛”都出现且眼睛可切换隐藏 ──────
current_stage <- "ide-context-eye"
check("ide-context chip shows the active file", wait_for(
  "document.querySelector('[data-slot=aui_ide_context]')?.getAttribute('data-context-file')==='R/demo.R'", 6))
# 关键回归：没有选区时“眼睛”也要出现（旧代码只在 hasSelection 时才渲染 → bug）
check("selection-visibility eye is present without a selection",
      isTRUE(value("!!document.querySelector('[data-slot=aui_selection_visibility]')")))
check("ide-context defaults to visible (file sent)",
      isTRUE(value("document.querySelector('[data-slot=aui_ide_context]')?.getAttribute('data-selection-visible')==='true'")))
# 点眼睛 → 隐藏（data-selection-visible=false，文件将不发送）
value("document.querySelector('[data-slot=aui_selection_visibility]')?.click(); true")
check("clicking the eye hides the file context", wait_for(
  "document.querySelector('[data-slot=aui_ide_context]')?.getAttribute('data-selection-visible')==='false'", 4))
value("document.querySelector('[data-slot=aui_selection_visibility]')?.click(); true")  # 还原
wait_for("document.querySelector('[data-slot=aui_ide_context]')?.getAttribute('data-selection-visible')==='true'", 4)

# ── 侧边栏折叠 ───────────────────────────────────────────────────────────────
current_stage <- "sidebar-collapse"
check("thread sidebar starts expanded", wait_for("document.querySelector('[data-slot=aui_thread_sidebar]')?.getAttribute('data-collapsed')==='false'"))
check("sidebar toggle present", isTRUE(value("!!document.querySelector('[data-slot=aui_sidebar_toggle]')")))
click_sel("[data-slot=aui_sidebar_toggle]")
# 折叠后侧栏元素整体消失（无残留窄轨）
check("sidebar element removed when collapsed", wait_for("!document.querySelector('[data-slot=aui_thread_sidebar]')", 4))
# 展开按钮改在主面板（thread viewport 内），仍可点开
check("expand toggle moves into main panel", isTRUE(value(
  "(function(){const b=document.querySelector('[data-slot=aui_sidebar_toggle]');if(!b)return false;return !!b.closest('[data-slot=aui_thread-viewport]') || !b.closest('[data-slot=aui_thread_sidebar]');})()"
)))
click_sel("[data-slot=aui_sidebar_toggle]")
check("sidebar returns on expand", wait_for("document.querySelector('[data-slot=aui_thread_sidebar]')?.getAttribute('data-collapsed')==='false'", 4))

# ── Claude 编辑后揭示最近一次成功编辑（on_done flush）────────────────────────
current_stage <- "edit-reveal"
value("document.getElementById('opened-file-probe').textContent='';true")
type_text("please do-edit now")
key("Enter", "Enter", 13L)
check("edit run completes", wait_for("document.body.innerText.includes('edited files')", 8))
# 三个编辑工具卡出现（Read/Edit/Write），文件打开按钮可点击
check("tool cards render file-open affordance", wait_for("!!document.querySelector('[data-open-file]')", 6))
# 只揭示最近一次成功编辑 = 最后一个 Write(R/addin.R)
check("reveal fires once for the most recent successful edit",
      wait_for("document.getElementById('opened-file-probe').textContent === 'R/addin.R'", 6),
      value("document.getElementById('opened-file-probe').textContent"))

# ── 点击文件引用在编辑器打开（on_open_file 收到点击路径）─────────────────────
current_stage <- "click-open-file"
value("document.getElementById('opened-file-probe').textContent='';true")
# 点击其中一个工具卡的打开按钮（Read → R/server.R）
clicked <- click_sel("[data-open-file='R/server.R']")
check("clicked a file-open button", clicked)
check("clicking a file reference calls on_open_file",
      wait_for("document.getElementById('opened-file-probe').textContent === 'R/server.R'", 6),
      value("document.getElementById('opened-file-probe').textContent"))

check("no browser console errors or exceptions", length(console_errors) == 0,
      if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE)
try(app$kill(), silent = TRUE)
if (length(failures)) stop("Chromium verification failed: ", paste(failures, collapse = ", "))
cat("OPENFILE_REVEAL_CHROMIUM_DONE\n")
