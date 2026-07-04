#!/usr/bin/env Rscript
# 真实对话验证:后台进程 readRenviron 加载凭证,驱动 composer 发消息,轮询等真实回复。
suppressMessages({ library(chromote); library(callr) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"

args <- commandArgs(trailingOnly = TRUE)
app     <- if (length(args) >= 1) args[1] else "09_tool_calling.R"
port    <- if (length(args) >= 2) as.integer(args[2]) else 8970
prompt  <- if (length(args) >= 3) args[3] else "Reply with exactly one word: pong"

logf <- sprintf("/tmp/rc_%s.log", app); errf <- sprintf("/tmp/rc_%s.err", app)
proc <- callr::r_bg(function(proj, app, port) {
  setwd(proj)
  readRenviron(file.path(proj, ".Renviron"))   # 关键:加载 ellmer 凭证
  suppressMessages(library(shiny))
  shiny::runApp(file.path("examples", app), host = "127.0.0.1",
                port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, app = app, port = port), stdout = logf, stderr = errf)
on.exit({ try(proc$kill(), silent = TRUE) }, add = TRUE)
Sys.sleep(9)
if (!proc$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines(errf), 8), sep="\n"); quit(status=1) }

b <- ChromoteSession$new()
b$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); b$Page$loadEventFired()
Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)

base_len <- ev("document.body.innerText.length")
cat(sprintf("app=%s  base bodyText=%s\n", app, base_len))

# 发消息
ev("document.querySelector('[contenteditable=true]').focus()")
Sys.sleep(0.5)
b$Input$insertText(text = prompt)
Sys.sleep(0.7)
b$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",   key="Enter", code="Enter", windowsVirtualKeyCode=13L)
cat("message sent, polling for reply...\n")

# 轮询最多 40s 等真实 LLM 回复
reply_ok <- FALSE; err_seen <- FALSE; snippet <- "(none)"
expect_token <- if (length(args) >= 4) tolower(args[4]) else "pong"
for (i in 1:20) {
  Sys.sleep(2)
  snippet <- ev("(function(){var xs=document.querySelectorAll('.aui-assistant-message-root,[class*=assistant-message]');if(!xs.length)return '';return xs[xs.length-1].innerText.slice(0,300)})()")
  if (is.na(snippet) || !nzchar(snippet)) next
  low <- tolower(snippet)
  if (grepl(expect_token, low, fixed = TRUE)) { reply_ok <- TRUE; break }
  # 错误卡(排除刚好含 pong 的情况)
  if (grepl("traceback|uncaught|failed to fetch|http 4|http 5", low)) { err_seen <- TRUE; break }
}

cat(sprintf("[%s] reply_received=%s (expect '%s') error_card=%s\n",
            if(reply_ok && !err_seen)"PASS" else "FAIL", reply_ok, expect_token, err_seen))
cat("assistant snippet:", gsub("\n"," ",snippet), "\n")

# 工具调用诊断:工具卡数量 + 是否有结果
n_toolcards <- ev("document.querySelectorAll('[data-tool-depth]').length")
tool_txt <- ev("(function(){var xs=document.querySelectorAll('[data-tool-depth]');return xs.length?Array.from(xs).map(e=>e.innerText.slice(0,120)).join(' || '):'(no tool cards)'})()")
cat(sprintf("tool cards: %s\n", n_toolcards))
cat("tool card text:", gsub("\n"," ", tool_txt), "\n")

b$close(); proc$kill()
cat("DONE\n")
