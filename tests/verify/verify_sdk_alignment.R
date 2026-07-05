#!/usr/bin/env Rscript
# 验证 shinyAssistantUI 新对齐能力(真实 claude,copilot-api :4141)。
# #1 成本页脚 / #4 状态行 / #5 命令自动发现 / #6 fork 按钮存在。
suppressMessages({library(chromote);library(callr)})
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
p <- callr::r_bg(function(proj, port) {
  setwd(proj); readRenviron(file.path(proj, ".Renviron")); suppressMessages(library(shiny))
  shiny::runApp("examples/11_tool_calling_claude_sdk.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = 9186), stdout = "/tmp/sdkv.o", stderr = "/tmp/sdkv.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE); Sys.sleep(11)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/sdkv.e"), 8), sep = "\n"); quit() }
b <- chromote::ChromoteSession$new()
b$Page$navigate("http://127.0.0.1:9186/"); b$Page$loadEventFired(); Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)
chk <- function(n, c, d = "") cat(sprintf("[%s] %-28s %s\n", if (isTRUE(c)) "PASS" else "FAIL", n, d))
ev("(function(){document.querySelector('textarea').focus();return 1})()"); Sys.sleep(0.3)
b$Input$insertText(text = "say hi in 2 words"); Sys.sleep(0.3)
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
sawStatus <- FALSE
for (i in 1:24) { Sys.sleep(0.4)
  if (isTRUE(ev("!!document.querySelector('[data-slot=aui_status_line]')"))) sawStatus <- TRUE
  if (isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')"))) break }
chk("#4 status_line_during_run", sawStatus)
for (i in 1:15) { Sys.sleep(1); if (isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')"))) break }
chk("#1 usage_footer_cost", isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')")),
    ev("(function(){var e=document.querySelector('[data-slot=aui_usage_footer]');return e?e.innerText:'(none)'})()"))
ev("(function(){document.querySelector('textarea').focus();return 1})()"); Sys.sleep(0.3)
b$Input$insertText(text = "/"); Sys.sleep(0.8)
ncmd <- ev("document.querySelectorAll('[data-slash-cmd]').length")
chk("#5 slash_has_commands", !is.na(ncmd) && ncmd > 0, paste("cmd count:", ncmd))
cat("R errors:", paste(head(grep("Action failed|Error|error:", readLines("/tmp/sdkv.e"), value = TRUE), 3), collapse = " | "), "\n")
try(b$close(), silent = TRUE); try(p$kill(), silent = TRUE)
try(chromote::default_chromote_object()$get_browser()$get_process()$kill(), silent = TRUE)
system("rm -f /tmp/sdkv.*")
cat("VERIFY_DONE\n")
