suppressPackageStartupMessages({ library(callr); library(chromote); library(jsonlite) })
`%||%` <- function(x, y) if (is.null(x)) y else x
project <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
port <- 9229L
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

# ── 用户主动上滚后，后续流式内容不得劫持阅读位置 ────────────────────────────
type_text("slow scroll"); key("Enter", "Enter", 13L)
chk("slow stream reaches pause point", wait_for("document.body.innerText.includes('Slow line 020')", 8))
vp_center <- fromJSON(value(paste0(
  "(function(){const e=document.querySelector('[data-slot=aui_thread-viewport]');",
  "const r=e.getBoundingClientRect();return JSON.stringify({x:Math.round(r.left+r.width/2),",
  "y:Math.round(r.top+r.height/2)})})()"
)))
browser$Input$dispatchMouseEvent(
  type = "mouseWheel", x = as.integer(vp_center$x), y = as.integer(vp_center$y),
  deltaX = 0, deltaY = -520
)
Sys.sleep(0.25)
manual_scroll <- fromJSON(value(paste0(
  "(function(){const e=document.querySelector('[data-slot=aui_thread-viewport]');",
  "return JSON.stringify({top:e.scrollTop,dist:e.scrollHeight-e.scrollTop-e.clientHeight})})()"
)))
chk("manual wheel moves away from bottom", manual_scroll$dist > 80, sprintf("dist=%.1f", manual_scroll$dist))
chk("slow stream finishes after manual scroll", wait_for("document.body.innerText.includes('Slow line 080')", 10))
Sys.sleep(0.3)
after_manual <- fromJSON(value(paste0(
  "(function(){const e=document.querySelector('[data-slot=aui_thread-viewport]');",
  "return JSON.stringify({top:e.scrollTop,dist:e.scrollHeight-e.scrollTop-e.clientHeight})})()"
)))
chk(
  "stream does not hijack deliberate upward scroll",
  abs(after_manual$top - manual_scroll$top) <= 12 && after_manual$dist > manual_scroll$dist,
  sprintf("top %.1f->%.1f, dist %.1f->%.1f", manual_scroll$top, after_manual$top, manual_scroll$dist, after_manual$dist)
)

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
# 上一段已证明用户主动上滚不会被 stream 劫持。这里显式恢复 follow-bottom，
# 再验证正常跟随状态下 approval 会被抬到 sticky footer 之上。
value("(function(){const e=document.querySelector('[data-slot=aui_thread-viewport]');if(e)e.scrollTo({top:e.scrollHeight,behavior:'instant'});return !!e})()")
chk("approval scenario starts at bottom", wait_for("(function(){const e=document.querySelector('[data-slot=aui_thread-viewport]');return !!e&&(e.scrollHeight-e.scrollTop-e.clientHeight)<=12})()", 4))
type_text("do the task"); key("Enter", "Enter", 13L)
# 第一个审批出现
chk("first approval appears", wait_for("[...document.querySelectorAll('button')].some(b=>/Approve/i.test(b.textContent||''))", 12))
Sys.sleep(0.3)
pending1 <- as.integer(value("[...document.querySelectorAll('button')].filter(b=>/^Approve$/i.test((b.textContent||'').trim())).length"))
chk("only one approval pending at a time (A)", pending1 == 1L, sprintf("pending=%d", pending1))
# 审批按钮必须位于 sticky footer 上方的有效可视区，且中心点不能被 footer 覆盖。
inview <- isTRUE(value(paste0(
  "(function(){const b=[...document.querySelectorAll('button')].find(x=>/^Approve$/i.test((x.textContent||'').trim()));",
  "const v=document.querySelector('[data-slot=aui_thread-viewport]'),f=document.querySelector('[data-slot=aui_thread-viewport-footer]');",
  "if(!b||!v||!f)return false;const r=b.getBoundingClientRect(),vr=v.getBoundingClientRect(),fr=f.getBoundingClientRect();",
  "const effectiveBottom=Math.min(vr.bottom,fr.top);const hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);",
  "return r.top>=vr.top-1&&r.bottom<=effectiveBottom+1&&!!hit&&(hit===b||b.contains(hit)||!!hit.closest('.aui-shiny-approval'))})()")))
chk("approval button is above sticky footer and clickable", inview)
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
chk("second approval is above sticky footer", isTRUE(value(paste0(
  "(function(){const a=[...document.querySelectorAll('.aui-shiny-approval')].at(-1),",
  "v=document.querySelector('[data-slot=aui_thread-viewport]'),f=document.querySelector('[data-slot=aui_thread-viewport-footer]');",
  "if(!a||!v||!f)return false;const ar=a.getBoundingClientRect(),vr=v.getBoundingClientRect(),fr=f.getBoundingClientRect();",
  "return ar.top>=vr.top-1&&ar.bottom<=Math.min(vr.bottom,fr.top)+1})()"
))))
value("(function(){const b=[...document.querySelectorAll('button')].find(x=>/^Approve$/i.test((x.textContent||'').trim()));if(b)b.click();return !!b})()")
chk("task completes after serial approvals", wait_for("document.body.innerText.includes('done')", 8))
Sys.sleep(0.3)
chk("approval completion restores bottom follow", isTRUE(value(paste0(
  "(function(){const e=document.querySelector('[data-slot=aui_thread-viewport]');",
  "return !!e&&(e.scrollHeight-e.scrollTop-e.clientHeight)<=12})()"
))))

# ── 无语言标签代码块：按当前中立策略显示 markdown 并高亮，而非误标为 R ─────────
type_text("show me a codeblock"); key("Enter", "Enter", 13L)
chk("code header renders", wait_for("[...document.querySelectorAll('.aui-code-header-language')].some(e=>(e.textContent||'').trim().toLowerCase()==='markdown')", 8))
chk("unlabeled code block is labelled markdown",
    isTRUE(value("[...document.querySelectorAll('.aui-code-header-language')].some(e=>(e.textContent||'').trim().toLowerCase()==='markdown')")),
    value("[...document.querySelectorAll('.aui-code-header-language')].map(e=>(e.textContent||'').trim()).join('|')"))
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
# gate 是 Bash 工具（requiresApproval → 强制展开）；当前 resolver 将 command 渲染为 bash code view。
chk("Bash tool args render as highlighted code", wait_for("!!document.querySelector('[data-slot=tool-fallback-args][data-arg-view=code][data-arg-lang=bash] [data-syntax-highlighter=prism]')", 8))
chk("Bash code view shows the command", isTRUE(value(
  "(document.querySelector('[data-slot=tool-fallback-args][data-arg-view=code][data-arg-lang=bash]')?.textContent||'').includes('ls')")))
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
