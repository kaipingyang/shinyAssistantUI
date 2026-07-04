#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
PORT <- 8933
proc <- callr::r_bg(function(port) {
  setwd("/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI")
  suppressMessages(library(shiny))
  shiny::runApp("tests/verify/approval_app.R", host = "127.0.0.1",
                port = port, launch.browser = FALSE)
}, args = list(port = PORT), stdout = "/tmp/appr.log", stderr = "/tmp/appr.err")
on.exit({ try(proc$kill(), silent = TRUE) }, add = TRUE)
Sys.sleep(9)
if (!proc$is_alive()) { cat(readLines("/tmp/appr.err"), sep="\n"); quit(status=1) }

b <- ChromoteSession$new()
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired()
Sys.sleep(4)
ev <- function(js) b$Runtime$evaluate(js)$result$value
chk <- function(name, cond, detail="") cat(sprintf("[%s] %-30s %s\n", if(isTRUE(cond))"PASS" else "FAIL", name, detail))

# 提交消息
ev("document.querySelector('[contenteditable=true]').focus()")
Sys.sleep(0.5)
b$Input$insertText(text = "delete the file")
Sys.sleep(0.6)
b$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",   key="Enter", code="Enter", windowsVirtualKeyCode=13L)
Sys.sleep(3)

# 1) 审批卡片出现(awaiting approval)
txt1 <- ev("document.body.innerText")
chk("approval_card_shown", grepl("awaiting approval|delete_file", txt1), "")
# 审批按钮"Yes"存在
yes_exists <- ev("Array.from(document.querySelectorAll('button')).some(b=>/^\\s*1\\.?\\s*Yes\\s*$/.test(b.innerText)||/\\bYes\\b/.test(b.innerText))")
chk("approve_button_present", yes_exists, "")

# 2) 点击 Yes 批准
clicked <- ev("(function(){var bs=Array.from(document.querySelectorAll('button'));var t=bs.find(b=>/\\bYes\\b/.test(b.innerText));if(t){t.click();return true}return false})()")
chk("approve_clicked", clicked, "")
Sys.sleep(3)

# 3) 批准后 R 收到并回结果 + 后续文本
txt2 <- ev("document.body.innerText")
chk("approved_badge_or_result", grepl("Approved|File deleted successfully|Deletion approved", txt2), "")
chk("post_approval_reply", grepl("Deletion approved and completed", txt2), "")

b$close(); proc$kill()
cat("DONE\n")
