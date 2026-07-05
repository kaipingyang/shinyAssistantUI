#!/usr/bin/env Rscript
# 驱动 task_progress_app:诱导 Task 子agent,验证 #2 进度卡 + #7 Stop 按钮。
suppressMessages({library(chromote);library(callr)})
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
p <- callr::r_bg(function(proj, port) {
  setwd(proj); readRenviron(file.path(proj, ".Renviron")); suppressMessages(library(shiny))
  shiny::runApp("tests/verify/task_progress_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
}, args = list(proj = PROJ, port = 9190), stdout = "/tmp/taskv.o", stderr = "/tmp/taskv.e")
on.exit(try(p$kill(), silent = TRUE), add = TRUE); Sys.sleep(11)
if (!p$is_alive()) { cat("BOOT FAIL\n"); cat(tail(readLines("/tmp/taskv.e"), 8), sep = "\n"); quit() }
b <- chromote::ChromoteSession$new()
b$Page$navigate("http://127.0.0.1:9190/"); b$Page$loadEventFired(); Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error = function(e) NA)
chk <- function(n, c, d = "") cat(sprintf("[%s] %-30s %s\n", if (isTRUE(c)) "PASS" else "FAIL", n, d))

# 装 20ms 记录器:捕获 task 卡是否出现过 + 出现时是否含 Stop 按钮 + 记录一个 taskId
ev("(function(){window.__sawCard=false;window.__sawStop=false;window.__taskId='';
  window.__rec=setInterval(function(){
    var c=document.querySelector('[data-slot=aui_task_card]');
    if(c){window.__sawCard=true;
      var s=c.querySelector('[data-stop-task]');
      if(s){window.__sawStop=true;window.__taskId=s.getAttribute('data-stop-task')}}
  },20);return true})()")

# 诱导一个较长的 Task 子agent
ev("(function(){document.querySelector('textarea').focus();return 1})()"); Sys.sleep(0.3)
b$Input$insertText(text = "Use the Task tool to launch a general-purpose subagent. Instruct that subagent to use the Bash tool to run exactly: sleep 20 && echo done — then report the output. You MUST delegate via the Task tool, do not run it yourself.")
Sys.sleep(0.3)
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)

# 轮询直到看到卡片(或超时)
cardSeen <- FALSE
for (i in 1:60) { Sys.sleep(1)
  if (isTRUE(ev("window.__sawCard"))) { cardSeen <- TRUE; break }
  if (isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')"))) break  # 已结束
}
chk("#2 task_card_rendered", cardSeen)
chk("#7 stop_button_present", isTRUE(ev("window.__sawStop")),
    paste("taskId:", ev("window.__taskId")))

# #7 若卡片仍在,点 Stop,验证动作气泡出现(⚙️/Stopped)
if (isTRUE(ev("!!document.querySelector('[data-stop-task]')"))) {
  ev("(function(){var s=document.querySelector('[data-stop-task]');if(s)s.click();return !!s})()")
  Sys.sleep(3)
  chk("#7 stop_click_recorded", grepl("Stop|Stopped|stoptask", ev("document.body.innerText")))
} else {
  cat("[INFO] task already completed before Stop could be clicked (fast subagent)\n")
}

# R 端确认收到 task 消息(on_task 触发)
cat("R task log:", paste(head(grep("\\[TASK\\]", readLines("/tmp/taskv.e"), value = TRUE), 5), collapse = " | "), "\n")
try(b$close(), silent = TRUE); try(p$kill(), silent = TRUE)
try(chromote::default_chromote_object()$get_browser()$get_process()$kill(), silent = TRUE)
system("rm -f /tmp/taskv.*")
cat("TASK_VERIFY_DONE\n")
