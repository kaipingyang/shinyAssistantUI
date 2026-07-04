#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 8994
proc <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressMessages(library(shiny))
  shiny::runApp("tests/verify/queue_app.R", host="127.0.0.1", port=port, launch.browser=FALSE)
}, args=list(proj=PROJ, port=PORT), stdout="/tmp/q.log", stderr="/tmp/q.err")
on.exit({ try(proc$kill(), silent=TRUE) }, add=TRUE)
Sys.sleep(9); if (!proc$is_alive()) { cat(readLines("/tmp/q.err"), sep="\n"); quit(status=1) }
b <- ChromoteSession$new(); b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)
chk <- function(n,c,d="") cat(sprintf("[%s] %-26s %s\n", if(isTRUE(c))"PASS" else "FAIL", n, d))
typeSend <- function(txt) {
  ev("document.querySelector('[contenteditable=true]').focus()"); Sys.sleep(0.4)
  b$Input$insertText(text = txt); Sys.sleep(0.4)
  b$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
  b$Input$dispatchKeyEvent(type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
}
# 发第一条
typeSend("first")
Sys.sleep(1.2)  # 此时应在 running(慢 handler)
qbtn <- ev("!!document.querySelector('.aui-composer-queue-btn')")
chk("queue_button_while_running", isTRUE(qbtn), "")
# 运行中输入第二条并点排队按钮
ev("document.querySelector('[contenteditable=true]').focus()"); Sys.sleep(0.3)
b$Input$insertText(text = "second"); Sys.sleep(0.5)
clicked <- ev("(function(){var b=document.querySelector('.aui-composer-queue-btn');if(b){b.click();return true}return false})()")
chk("enqueued", isTRUE(clicked), "")
# 等第一条完成 + 队列 flush + 第二条完成
Sys.sleep(9)
body <- ev("document.body.innerText")
chk("first_reply", grepl("echo:first", body), "")
chk("second_reply_auto_sent", grepl("echo:second", body), "")
n_user <- ev("document.querySelectorAll('[class*=user-message]').length")
cat("user messages:", n_user, "\n")
b$close(); proc$kill(); system("rm -f /tmp/q.log /tmp/q.err")
cat("DONE\n")
