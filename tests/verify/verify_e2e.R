#!/usr/bin/env Rscript
# 端到端验证:真实无头 Chromium 驱动 composer 提交,读 DOM 真值断言所有特性。
suppressMessages({ library(chromote); library(callr) })

PORT <- 8932
proc <- callr::r_bg(function(port) {
  setwd("/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI")
  suppressMessages(library(shiny))
  shiny::runApp("tests/verify/verify_app.R", host = "127.0.0.1",
                port = port, launch.browser = FALSE)
}, args = list(port = PORT), stdout = "/tmp/verify_app2.log", stderr = "/tmp/verify_app2.err")
on.exit({ try(proc$kill(), silent = TRUE) }, add = TRUE)
Sys.sleep(9)
if (!proc$is_alive()) { cat(readLines("/tmp/verify_app2.err"), sep="\n"); quit(status=1) }

b <- ChromoteSession$new()
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired()
Sys.sleep(4)
ev  <- function(js) b$Runtime$evaluate(js)$result$value
evj <- function(js) {
  r <- b$Runtime$evaluate(js, returnByValue = TRUE)$result$value
  if (is.null(r)) NA else r
}

results <- list()
chk <- function(name, cond, detail = "") {
  results[[name]] <<- isTRUE(cond)
  cat(sprintf("[%s] %-34s %s\n", if (isTRUE(cond)) "PASS" else "FAIL", name, detail))
}

# ── 1) composer 存在 ──────────────────────────────────────────────────────────
n_ce <- ev("document.querySelectorAll('[contenteditable=true]').length")
chk("composer_present", n_ce >= 1, sprintf("(contenteditable=%s)", n_ce))

# ── 2) AttachmentDropzone 存在(拖拽上传) ──────────────────────────────────────
n_dz <- ev("document.querySelectorAll('[class*=dropzone],[class*=Dropzone],[data-dragging]').length + document.querySelectorAll('input[type=file]').length")
chk("attachment_upload_present", n_dz >= 1, sprintf("(dropzone/file inputs=%s)", n_dz))

# ── 驱动:聚焦 composer,输入文本,回车提交 ────────────────────────────────────
ev("document.querySelector('[contenteditable=true]').focus()")
Sys.sleep(0.5)
b$Input$insertText(text = "run research")
Sys.sleep(0.8)
typed <- ev("document.querySelector('[contenteditable=true]').innerText")
cat("typed into composer:", typed, "\n")
# 回车提交
b$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)
b$Input$dispatchKeyEvent(type = "keyUp",   key = "Enter", code = "Enter", windowsVirtualKeyCode = 13L)

# 等待 handler 跑完(thinking+工具+流式+done)
Sys.sleep(6)

# ── 3) 用户消息气泡出现 ───────────────────────────────────────────────────────
body_txt <- ev("document.body.innerText")
chk("user_message_shown", grepl("run research", body_txt), "")

# ── 4) 流式文本回复出现 ───────────────────────────────────────────────────────
chk("streaming_reply_shown", grepl("final streamed answer for verification", body_txt), "")

# ── 5) thinking/reasoning 卡片 ────────────────────────────────────────────────
chk("thinking_card_shown", grepl("Thought|Thinking", body_txt), "")

# ── 6) 工具卡片 + sub-agent 层级深度(D2 核心) ────────────────────────────────
depths_json <- evj("JSON.stringify(Array.from(document.querySelectorAll('[data-tool-depth]')).map(e=>({d:e.getAttribute('data-tool-depth'),p:e.getAttribute('data-parent-tool-call-id')})))")
cat("tool depth map:", depths_json, "\n")
n_tools <- ev("document.querySelectorAll('[data-tool-depth]').length")
chk("tool_cards_rendered", n_tools >= 4, sprintf("(cards=%s)", n_tools))
has_depth0 <- ev("Array.from(document.querySelectorAll('[data-tool-depth]')).some(e=>e.getAttribute('data-tool-depth')==='0')")
has_depth1 <- ev("Array.from(document.querySelectorAll('[data-tool-depth]')).some(e=>e.getAttribute('data-tool-depth')==='1')")
has_depth2 <- ev("Array.from(document.querySelectorAll('[data-tool-depth]')).some(e=>e.getAttribute('data-tool-depth')==='2')")
chk("subagent_depth0_parent", has_depth0, "")
chk("subagent_depth1_child",  has_depth1, "")
chk("subagent_depth2_grandchild", has_depth2, "")
# 缩进真实生效(marginLeft>0 的嵌套卡片)
indented <- ev("Array.from(document.querySelectorAll('[data-tool-depth]')).some(e=>parseFloat(getComputedStyle(e).marginLeft)>0)")
chk("subagent_visual_indent", indented, "")
# parent 链属性正确
child_has_parent <- ev("Array.from(document.querySelectorAll('[data-tool-depth=\"1\"]')).some(e=>e.getAttribute('data-parent-tool-call-id')==='parent-1')")
chk("subagent_parent_attr", child_has_parent, "")

# ── 7) 工具结果渲染 ───────────────────────────────────────────────────────────
chk("tool_result_shown", grepl("Research complete|Found 12 results|Summary complete", body_txt), "")

# ── 8) followup 建议(回复后) ─────────────────────────────────────────────────
chk("followup_suggestions_shown", grepl("Tell me more about climate data|What are the sources", body_txt), "")

# ── 9) 操作栏按钮:导出/引用/编辑/复制等 ─────────────────────────────────────
# hover 到 assistant 消息使 action bar 可见后再计数(部分 autohide)
n_export <- ev("document.querySelectorAll('[class*=export],[aria-label*=Export],[title*=Export]').length")
export_txt <- grepl("Export Markdown", body_txt)
# action bar 按钮总数(copy/reload/feedback/more)
n_actionbtn <- ev("document.querySelectorAll('.aui-action-bar-button,[class*=action-bar] button,button[aria-label]').length")
chk("action_bar_present", n_actionbtn >= 1, sprintf("(buttons=%s, exportEl=%s)", n_actionbtn, n_export))

# ── 10) 侧边栏(thread list) ───────────────────────────────────────────────────
n_sidebar <- ev("document.querySelectorAll('[class*=thread-list],[class*=ThreadList],[class*=sidebar]').length")
chk("thread_list_sidebar", n_sidebar >= 1 || grepl("New", body_txt), sprintf("(els=%s)", n_sidebar))

# 截图存档(供人工核对布局)
try(b$screenshot("/tmp/verify_shot.png"), silent = TRUE)

cat("\n=== SUMMARY ===\n")
pass <- sum(unlist(results)); total <- length(results)
cat(sprintf("PASS %d / %d\n", pass, total))
failed <- names(results)[!unlist(results)]
if (length(failed)) cat("FAILED:", paste(failed, collapse=", "), "\n")

b$close(); proc$kill()
cat("DONE\n")
if (pass < total) quit(status = 2)
