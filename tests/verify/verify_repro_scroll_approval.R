suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9227L
unlink(c("/tmp/aui-repro.out", "/tmp/aui-repro.err"))
report <- function(name, detail) cat(sprintf("[OBSERVE] %-42s %s\n", name, detail))
failures <- character()
chk <- function(name, condition, detail = "") {
  passed <- isTRUE(condition)
  cat(sprintf("[%s] %-46s %s\n", if (passed) "PASS" else "FAIL", name, detail))
  if (!passed) failures <<- c(failures, name)
  invisible(passed)
}

app <- callr::r_bg(function(project, port) {
  setwd(project); suppressPackageStartupMessages(library(shiny))
  shiny::runApp("tests/verify/repro_scroll_approval_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(project = project, port = port), stdout = "/tmp/aui-repro.out", stderr = "/tmp/aui-repro.err")
on.exit(try(app$kill(), silent = TRUE), add = TRUE)
for (i in seq_len(100)) { if (!app$is_alive()) break; if (file.exists("/tmp/aui-repro.err") && any(grepl("Listening on", readLines("/tmp/aui-repro.err", warn = FALSE)))) break; Sys.sleep(0.25) }
if (!app$is_alive()) { cat(tail(readLines("/tmp/aui-repro.err", warn = FALSE), 20), sep = "\n"); stop("boot failed") }

chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
browser <- ChromoteSession$new(width = 760, height = 560)  # 模拟 RStudio Viewer 小窗
on.exit({ try(browser$close(), silent = TRUE); try(browser$parent$get_browser()$get_process()$kill(), silent = TRUE) }, add = TRUE)
value <- function(s) { r <- browser$Runtime$evaluate(s, returnByValue = TRUE); if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text); r$result$value }
console_errors <- character()
browser$Runtime$enable()
browser$Runtime$consoleAPICalled(callback_ = function(message) {
  if (identical(message$type, "error")) console_errors <<- c(console_errors, "console-error")
})
browser$Runtime$exceptionThrown(callback_ = function(message) { console_errors <<- c(console_errors, "exception") })
wait_for <- function(s, t = 12, i = 0.05) { d <- Sys.time() + t; repeat { if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) return(TRUE); if (Sys.time() >= d) return(FALSE); Sys.sleep(i) } }
key <- function(n, c, vk) { browser$Input$dispatchKeyEvent(type="keyDown", key=n, code=c, windowsVirtualKeyCode=as.integer(vk)); browser$Input$dispatchKeyEvent(type="keyUp", key=n, code=c, windowsVirtualKeyCode=as.integer(vk)) }
type_text <- function(t) { value("(function(){const e=document.querySelector('.aui-lexical-input[contenteditable=true]');if(e)e.focus();return !!e})()"); browser$Input$insertText(text = t) }

browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); browser$Page$loadEventFired()
wait_for("!!document.querySelector('.aui-lexical-input[contenteditable=true]')")

# ── 问题1a：流式长回复后，视口跟随到底部 ──────────────────────────────────
type_text("scroll test"); key("Enter", "Enter", 13L)
wait_for("document.body.innerText.includes('Line 120')", 15)
Sys.sleep(2.0)
m <- fromJSON(value(paste0(
  "(function(){const e=document.querySelector('[data-slot=aui_thread-viewport]');",
  "if(!e)return JSON.stringify({el:'none',scrollHeight:0,clientHeight:0,scrollTop:0,distanceFromBottom:9999});",
  "return JSON.stringify({el:'aui_thread-viewport',scrollHeight:e.scrollHeight,clientHeight:e.clientHeight,",
  "scrollTop:Math.round(e.scrollTop),distanceFromBottom:Math.round(e.scrollHeight-e.scrollTop-e.clientHeight)})})()")))
report("scrollHeight / clientHeight", sprintf("%d / %d", m$scrollHeight, m$clientHeight))
report("distance from bottom after streaming (px)", m$distanceFromBottom)
chk("ISSUE1a auto-follows to bottom", m$distanceFromBottom <= 12, sprintf("dist=%d", m$distanceFromBottom))

# ── 问题1b：内容溢出时顶部出现"当前提问"小框，可展开 ───────────────────────
chk("current-question box appears on overflow", wait_for("!!document.querySelector('[data-slot=aui_current_question]')", 4))
chk("current-question shows the question text", isTRUE(value("(document.querySelector('[data-slot=aui_current_question]')?.innerText||'').includes('scroll test')")))
chk("current-question starts collapsed", isTRUE(value("document.querySelector('[data-slot=aui_current_question]')?.getAttribute('data-expanded')==='false'")))
value("document.querySelector('[data-slot=aui_current_question_toggle]')?.click(); true")
chk("current-question expands on toggle", wait_for("document.querySelector('[data-slot=aui_current_question]')?.getAttribute('data-expanded')==='true'", 4))

# ── 侧栏折叠：展开按钮浮在提问框之上且不被覆盖，提问框左侧让出空间（并排） ────
value("document.querySelector('[data-slot=aui_sidebar_toggle]')?.click(); true")  # 折叠
chk("sidebar collapses, expand button in main panel", wait_for(
  "!document.querySelector('[data-slot=aui_thread_sidebar]') && !!document.querySelector('[data-slot=aui_sidebar_toggle]')", 4))
# 展开按钮中心点的最顶层元素就是按钮本身（没被 sticky 提问框盖住）
chk("expand button is on top of sticky question box (not covered)", isTRUE(value(paste0(
  "(function(){const b=document.querySelector('[data-slot=aui_sidebar_toggle]');if(!b)return false;",
  "const r=b.getBoundingClientRect();const el=document.elementFromPoint(r.left+r.width/2, r.top+r.height/2);",
  "return !!el && (el===b || b.contains(el) || !!el.closest('[data-slot=aui_sidebar_toggle]'))})()"))))
# 提问框内容左侧留出按钮空位（padding-inline-start 足够避让 start-2 + size-7 按钮）
chk("current-question reserves left space for the button", isTRUE(value(paste0(
  "(function(){const inner=document.querySelector('[data-slot=aui_current_question] > div');if(!inner)return false;",
  "return parseFloat(getComputedStyle(inner).paddingInlineStart||'0') >= 20})()"))))
value("document.querySelector('[data-slot=aui_sidebar_toggle]')?.click(); true")  # 展开还原
wait_for("!!document.querySelector('[data-slot=aui_thread_sidebar]')", 4)

# ── 问题2：串行审批，一次一个且在视口内 ────────────────────────────────────
type_text("do the task"); key("Enter", "Enter", 13L)
# 第一个审批出现
chk("first approval appears", wait_for("[...document.querySelectorAll('button')].some(b=>/Approve/i.test(b.textContent||''))", 12))
Sys.sleep(0.3)
pending1 <- as.integer(value("[...document.querySelectorAll('button')].filter(b=>/^Approve$/i.test((b.textContent||'').trim())).length"))
chk("only one approval pending at a time (A)", pending1 == 1L, sprintf("pending=%d", pending1))
# 审批按钮在视口内（受益于底部跟随）
inview <- isTRUE(value(paste0(
  "(function(){const b=[...document.querySelectorAll('button')].find(x=>/^Approve$/i.test((x.textContent||'').trim()));",
  "if(!b)return false;const r=b.getBoundingClientRect();return r.top>=0 && r.bottom<=innerHeight+1})()")))
chk("approval button is within viewport (visible)", inview)
# #审批UI在折叠内容之外：折叠工具卡后仍能看到并操作（与 ✓Approved 同源修复）
chk("approval buttons sit outside collapsible content", isTRUE(value(paste0(
  "(function(){const b=[...document.querySelectorAll('button')].find(x=>/^Approve$/i.test((x.textContent||'').trim()));",
  "if(!b)return false;return !b.closest('[data-slot=tool-fallback-content], [role=region]')})()"))))
# 批准 A → B 才出现
value("(function(){const b=[...document.querySelectorAll('button')].find(x=>/^Approve$/i.test((x.textContent||'').trim()));if(b)b.click();return !!b})()")
chk("after approving A, task proceeds to B", wait_for("document.body.innerText.includes('Run Rscript') || [...document.querySelectorAll('button')].some(b=>/^Approve$/i.test((b.textContent||'').trim()))", 8))
# #4：批准后出现绿色 Approved 指示，且在折叠外（折叠工具卡也能看到）
chk("approved indicator shows after approval", wait_for("!!document.querySelector('[data-approval-result=approved]')", 6))
chk("approved indicator sits outside collapsible content",
    isTRUE(value("(function(){const el=document.querySelector('[data-approval-result=approved]');if(!el)return false;return !el.closest('[data-slot=tool-fallback-content], [role=region]')})()")))
Sys.sleep(0.3)
pending2 <- as.integer(value("[...document.querySelectorAll('button')].filter(b=>/^Approve$/i.test((b.textContent||'').trim())).length"))
chk("still only one approval pending at a time (B)", pending2 <= 1L, sprintf("pending=%d", pending2))
value("(function(){const b=[...document.querySelectorAll('button')].find(x=>/^Approve$/i.test((x.textContent||'').trim()));if(b)b.click();return !!b})()")
chk("task completes after serial approvals", wait_for("document.body.innerText.includes('done')", 8))

# ── 无语言标签代码块：本 R addin 应按 R 显示（标签 r）并高亮，而非 "unknown" ──────
type_text("show me a codeblock"); key("Enter", "Enter", 13L)
chk("code header renders", wait_for("!!document.querySelector('.aui-code-header-language')", 8))
chk("unlabeled code block is labelled r (not unknown)",
    isTRUE(value("(document.querySelector('.aui-code-header-language')?.textContent||'').trim().toLowerCase()==='r'")),
    value("(document.querySelector('.aui-code-header-language')?.textContent||'').trim()"))
chk("unlabeled code block is syntax-highlighted (token spans)",
    isTRUE(value("!!document.querySelector('.aui-md pre code span, pre code span')")))

# ── Edit 工具卡自动 git 式 diff（改前改后） ─────────────────────────────────────
type_text("editdiff please"); key("Enter", "Enter", 13L)
chk("Edit tool renders a diff viewer", wait_for("!!document.querySelector('[data-slot=aui_edit_diff] [data-slot=diff-viewer]')", 8))
chk("Edit diff has an added line", isTRUE(value("!!document.querySelector('[data-slot=diff-viewer-line][data-type=add]')")))
chk("Edit diff has a deleted line", isTRUE(value("!!document.querySelector('[data-slot=diff-viewer-line][data-type=del]')")))
chk("Edit diff shows new content", isTRUE(value("document.body.innerText.includes('x <- 2')")))

# ── 手动 ```diff 块上色（裸 +/- 也红绿） ────────────────────────────────────────
type_text("show a diffblock"); key("Enter", "Enter", 13L)
chk("diff code block renders a diff viewer", wait_for("document.querySelectorAll('[data-slot=diff-viewer]').length >= 2", 8))
chk("diff code block colours +/- lines", isTRUE(value(
  "!!document.querySelector('[data-slot=diff-viewer-line][data-type=add]') && !!document.querySelector('[data-slot=diff-viewer-line][data-type=del]')")))

# ── 残留任务卡：run 结束后带 Stop 的任务卡应被清理 ─────────────────────────────
type_text("stucktask please"); key("Enter", "Enter", 13L)
chk("task card appears while running", wait_for("!!document.querySelector('[data-slot=aui_task_card]')", 10))
chk("task card has a Stop button", isTRUE(value("!!document.querySelector('[data-slot=aui_task_card] [data-slot=aui_task_stop]')")))
# 批准 gate → run 结束
value("(function(){const b=[...document.querySelectorAll('button')].find(x=>/^Approve$/i.test((x.textContent||'').trim()));if(b)b.click();return !!b})()")
chk("run completes", wait_for("document.body.innerText.includes('done')", 8))
# 关键：run 结束后任务卡（带 Stop）不再残留
chk("task card is cleared after the run ends", wait_for("!document.querySelector('[data-slot=aui_task_card]')", 6))

chk("no browser console errors", length(console_errors) == 0,
    if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")

try(browser$close(), silent = TRUE); try(app$kill(), silent = TRUE)
if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
cat("SCROLL_APPROVAL_VERIFY_DONE\n")
