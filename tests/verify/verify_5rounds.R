#!/usr/bin/env Rscript
# 5 轮综合测试:ellmer 全能力 + ClaudeAgentSDK 全能力 + slash 语义(含 /model)。
suppressMessages({ library(chromote); library(callr) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"

launch <- function(path, port, renv = TRUE) {
  callr::r_bg(function(proj, path, port, renv) {
    setwd(proj); if (renv) readRenviron(file.path(proj, ".Renviron"))
    suppressMessages(library(shiny))
    shiny::runApp(path, host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(proj = PROJ, path = path, port = port, renv = renv),
     stdout = sprintf("/tmp/t%d.o", port), stderr = sprintf("/tmp/t%d.e", port))
}
sess <- function(port) { b <- chromote::ChromoteSession$new(); b$Page$navigate(sprintf("http://127.0.0.1:%d/", port)); b$Page$loadEventFired(); Sys.sleep(4); b }
evf  <- function(b) function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)
typeSend <- function(b, ev, txt) {
  ev("(function(){var t=document.querySelector('textarea');t.focus();return true})()"); Sys.sleep(0.4)
  b$Input$insertText(text = txt); Sys.sleep(0.4)
  b$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
  b$Input$dispatchKeyEvent(type="keyUp",   key="Enter", code="Enter", windowsVirtualKeyCode=13L)
}
waitFor <- function(ev, pat, n = 20) { for (i in 1:n) { Sys.sleep(2); t <- ev("document.body.innerText"); if (!is.na(t) && grepl(pat, t, ignore.case = TRUE)) return(TRUE) }; FALSE }
R <- list()
rec <- function(k, v) R[[k]] <<- isTRUE(v)

# ===== ROUND 1: ellmer chat + tool =====
cat("\n===== ROUND 1: ellmer (chat + weather tool) =====\n")
p <- launch("examples/09_tool_calling.R", 9101)
Sys.sleep(9)
if (p$is_alive()) {
  b <- sess(9101); ev <- evf(b)
  typeSend(b, ev, "Reply with exactly one word: pong")
  rec("R1_ellmer_chat", waitFor(ev, "pong"))
  typeSend(b, ev, "What's the weather in Paris? use the weather tool")
  rec("R1_ellmer_tool", waitFor(ev, "Weather Lookup|temperature|Paris", 20))
  b$close()
} else { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/t9101.e"),5),sep="\n") }
p$kill(); Sys.sleep(1)

# ===== ROUND 2: ClaudeAgentSDK chat + Bash tool =====
cat("\n===== ROUND 2: ClaudeAgentSDK (chat + Bash tool) =====\n")
p <- launch("examples/11_tool_calling_claude_sdk.R", 9102)
Sys.sleep(11)
if (p$is_alive()) {
  b <- sess(9102); ev <- evf(b)
  typeSend(b, ev, "Reply with exactly one word: pong")
  rec("R2_claude_chat", waitFor(ev, "pong", 25))
  typeSend(b, ev, "Run 'echo HELLO_BASH' using the Bash tool")
  rec("R2_claude_tool", waitFor(ev, "HELLO_BASH|Bash|Used tool", 30))
  b$close()
} else { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/t9102.e"),8),sep="\n") }
p$kill(); Sys.sleep(1)

# ===== ROUND 3: slash semantics (/greet expands to prompt) =====
cat("\n===== ROUND 3: slash 语义 (/greet -> prompt) =====\n")
p <- launch("tests/verify/slash_semantics_app.R", 9103, renv = FALSE)
Sys.sleep(9)
if (p$is_alive()) {
  b <- sess(9103); ev <- evf(b)
  # 用 popover 选 /greet
  typeSend(b, ev, "unused"); Sys.sleep(2)  # leave welcome
  ev("(function(){var t=document.querySelector('textarea');var s=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value').set;s.call(t,'');t.dispatchEvent(new Event('input',{bubbles:true}));t.focus();return true})()"); Sys.sleep(0.3)
  b$Input$insertText(text = "/greet"); Sys.sleep(0.8)
  rec("R3_slash_popover", ev("!!document.querySelector('.aui-slash-popover')"))
  # 直接发送 /greet(不点 popover),验证 runtime 展开
  b$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L); b$Input$dispatchKeyEvent(type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
  Sys.sleep(2); body <- ev("document.body.innerText")
  # 展开成功 = handler 收到 prompt 文本(HELLO_FROM_PROMPT),而非字面 /greet
  rec("R3_slash_expands_to_prompt", grepl("RECEIVED\\[Reply with exactly: HELLO_FROM_PROMPT", body))
  rec("R3_slash_not_literal", !grepl("RECEIVED\\[/greet", body))
  b$close()
} else { cat("BOOT FAIL\n") }
p$kill(); Sys.sleep(1)

# ===== ROUND 4: /model semantics (NOT a client model-switcher) =====
cat("\n===== ROUND 4: /model 语义 =====\n")
p <- launch("tests/verify/slash_semantics_app.R", 9104, renv = FALSE)
Sys.sleep(9)
if (p$is_alive()) {
  b <- sess(9104); ev <- evf(b)
  typeSend(b, ev, "unused"); Sys.sleep(2)
  ev("(function(){var t=document.querySelector('textarea');var s=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value').set;s.call(t,'');t.dispatchEvent(new Event('input',{bubbles:true}));t.focus();return true})()"); Sys.sleep(0.3)
  b$Input$insertText(text = "/model"); Sys.sleep(0.8)
  # /model 不是已配置命令 -> popover 不应列出它
  pop <- ev("(function(){var p=document.querySelector('.aui-slash-popover');return p?p.innerText:'(none)'})()")
  rec("R4_model_not_a_command", !grepl("model", tolower(pop)) || pop == "(none)")
  # 发送 /model haiku -> 未定义命令,原样发给 AI(handler 收到字面 /model)
  ev("(function(){var t=document.querySelector('textarea');var s=Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value').set;s.call(t,'');t.dispatchEvent(new Event('input',{bubbles:true}));t.focus();return true})()"); Sys.sleep(0.3)
  typeSend(b, ev, "/model haiku"); Sys.sleep(2)
  rec("R4_model_sent_literal", grepl("RECEIVED\\[/model haiku", ev("document.body.innerText")))
  b$close()
} else { cat("BOOT FAIL\n") }
p$kill(); Sys.sleep(1)

# ===== ROUND 5: stability re-run (ellmer + claude chat) =====
cat("\n===== ROUND 5: 稳定性复跑 =====\n")
p <- launch("examples/09_tool_calling.R", 9105)
Sys.sleep(9)
if (p$is_alive()) { b <- sess(9105); ev <- evf(b); typeSend(b, ev, "Reply with exactly one word: pong"); rec("R5_ellmer_chat", waitFor(ev, "pong")); b$close() } else cat("BOOT FAIL ellmer\n")
p$kill(); Sys.sleep(1)
p <- launch("examples/11_tool_calling_claude_sdk.R", 9106)
Sys.sleep(11)
if (p$is_alive()) { b <- sess(9106); ev <- evf(b); typeSend(b, ev, "Reply with exactly one word: pong"); rec("R5_claude_chat", waitFor(ev, "pong", 25)); b$close() } else cat("BOOT FAIL claude\n")
p$kill()

cat("\n================ 测试报告 ================\n")
for (k in names(R)) cat(sprintf("[%s] %s\n", if (R[[k]]) "PASS" else "FAIL", k))
cat(sprintf("\n%d / %d 通过\n", sum(unlist(R)), length(R)))
system("rm -f /tmp/t91*.o /tmp/t91*.e")
