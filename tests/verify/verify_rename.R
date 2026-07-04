#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 8990
proc <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressMessages(library(shiny))
  shiny::runApp("tests/verify/rename_app.R", host="127.0.0.1", port=port, launch.browser=FALSE)
}, args=list(proj=PROJ, port=PORT), stdout="/tmp/rn.log", stderr="/tmp/rn.err")
on.exit({ try(proc$kill(), silent=TRUE) }, add=TRUE)
Sys.sleep(9)
if (!proc$is_alive()) { cat(readLines("/tmp/rn.err"), sep="\n"); quit(status=1) }
b <- ChromoteSession$new()
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired()
Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)
chk <- function(n,c,d="") cat(sprintf("[%s] %-26s %s\n", if(isTRUE(c))"PASS" else "FAIL", n, d))

# 侧边栏至少一个线程项
n_items <- ev("document.querySelectorAll('.aui-thread-list-item').length")
chk("sidebar_thread_present", as.integer(n_items) >= 1, sprintf("(items=%s)", n_items))
title0 <- ev("(function(){var t=document.querySelector('.aui-thread-list-item-title');return t?t.innerText:'(none)'})()")
cat("initial title:", title0, "\n")

# 点开第一个线程项的 More 菜单(视觉 hidden 但 DOM 可点)
ev("(function(){var it=document.querySelector('.aui-thread-list-item');var btns=it.querySelectorAll('button');for(var b of btns){if(b.title==='More options'){b.click();return true}}return false})()")
Sys.sleep(0.8)
# 点 Rename
clicked <- ev("(function(){var b=Array.from(document.querySelectorAll('.aui-thread-rename-btn'));if(b.length){b[0].click();return true}return false})()")
chk("rename_menu_clicked", isTRUE(clicked), "")
Sys.sleep(0.6)
# 输入框出现?
has_input <- ev("!!document.querySelector('.aui-thread-rename-input')")
chk("rename_input_shown", isTRUE(has_input), "")
# 设值 + 回车提交(React 受控 input)
ev("(function(){var inp=document.querySelector('.aui-thread-rename-input');var s=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;s.call(inp,'Renamed Project X');inp.dispatchEvent(new Event('input',{bubbles:true}));inp.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));return true})()")
Sys.sleep(1.5)
# 验证标题更新
title1 <- ev("(function(){var t=document.querySelector('.aui-thread-list-item-title');return t?t.innerText:'(none)'})()")
cat("new title:", title1, "\n")
chk("title_updated", identical(title1, "Renamed Project X"), title1)
# 验证 R 端收到 on_rename
Sys.sleep(0.5)
rlog <- tryCatch(paste(readLines("/tmp/rn.err"), collapse=" "), error=function(e) "")
chk("R_on_rename_fired", grepl("on_rename.*Renamed Project X", rlog), "")

b$close(); proc$kill()
system("rm -f /tmp/rn.log /tmp/rn.err")
cat("DONE\n")
