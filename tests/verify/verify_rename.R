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

# 先发一条消息,确保侧边栏有一个有内容的线程
ev("(function(){var t=document.querySelector('textarea');if(t)t.focus();return !!t})()")
Sys.sleep(0.4)
b$Input$insertText(text = "hello")
Sys.sleep(0.3)
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
Sys.sleep(3)

# 侧边栏至少一个线程项(vendored 组件用 data-slot,非 class)
n_items <- ev("document.querySelectorAll('[data-slot=aui_thread-list-item]').length")
chk("sidebar_thread_present", as.integer(n_items) >= 1, sprintf("(items=%s)", n_items))
title0 <- ev("(function(){var t=document.querySelector('[data-slot=aui_thread-list-item-title]');return t?t.innerText:'(none)'})()")
cat("initial title:", title0, "\n")

# 点开第一个线程项的 More 菜单。⚠ base-ui 菜单靠**真实指针事件**开(JS .click() 不行),
# 用 CDP dispatchMouseEvent(先 mouseMoved 触发 hover 让按钮可见)。
mrect <- ev("(function(){var m=document.querySelector('[data-slot=aui_thread-list-item-more]');if(!m)return null;var r=m.getBoundingClientRect();return JSON.stringify({x:r.x+r.width/2,y:r.y+r.height/2})})()")
if (!is.na(mrect) && !is.null(mrect)) {
  xy <- jsonlite::fromJSON(mrect)
  b$Input$dispatchMouseEvent(type="mouseMoved", x=xy$x, y=xy$y); Sys.sleep(0.3)
  b$Input$dispatchMouseEvent(type="mousePressed",  x=xy$x, y=xy$y, button="left", clickCount=1)
  b$Input$dispatchMouseEvent(type="mouseReleased", x=xy$x, y=xy$y, button="left", clickCount=1)
}
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
title1 <- ev("(function(){var t=document.querySelector('[data-slot=aui_thread-list-item-title]');return t?t.innerText:'(none)'})()")
cat("new title:", title1, "\n")
chk("title_updated", identical(title1, "Renamed Project X"), title1)
# 验证 R 端收到 on_rename
Sys.sleep(0.5)
rlog <- tryCatch(paste(readLines("/tmp/rn.err"), collapse=" "), error=function(e) "")
chk("R_on_rename_fired", grepl("on_rename.*Renamed Project X", rlog), "")

b$close(); proc$kill()
system("rm -f /tmp/rn.log /tmp/rn.err")
cat("DONE\n")
