#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 8992
proc <- callr::r_bg(function(proj, port) {
  setwd(proj); suppressMessages(library(shiny))
  shiny::runApp("tests/verify/html_sandbox_app.R", host="127.0.0.1", port=port, launch.browser=FALSE)
}, args=list(proj=PROJ, port=PORT), stdout="/tmp/hs.log", stderr="/tmp/hs.err")
on.exit({ try(proc$kill(), silent=TRUE) }, add=TRUE)
Sys.sleep(9); if (!proc$is_alive()) { cat(readLines("/tmp/hs.err"), sep="\n"); quit(status=1) }
b <- ChromoteSession$new(); b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired(); Sys.sleep(4)
ev <- function(js) tryCatch(b$Runtime$evaluate(js)$result$value, error=function(e) NA)
chk <- function(n,c,d="") cat(sprintf("[%s] %-30s %s\n", if(isTRUE(c))"PASS" else "FAIL", n, d))
# 发消息触发工具
ev("document.querySelector('[contenteditable=true]').focus()"); Sys.sleep(0.5)
b$Input$insertText(text = "report")
Sys.sleep(0.5)
b$Input$dispatchKeyEvent(type="keyDown", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp", key="Enter", code="Enter", windowsVirtualKeyCode=13L)
Sys.sleep(3)
# 展开工具卡(html 卡默认可能收起;点击标题展开)
ev("(function(){var b=Array.from(document.querySelectorAll('button')).find(x=>/render_report/.test(x.innerText));if(b)b.click();return !!b})()")
Sys.sleep(1)
n_iframe <- ev("document.querySelectorAll('iframe.aui-html-sandbox').length")
chk("sandbox_iframe_rendered", as.integer(n_iframe) >= 1, sprintf("(iframes=%s)", n_iframe))
has_sandbox_attr <- ev("(function(){var f=document.querySelector('iframe.aui-html-sandbox');return f?f.getAttribute('sandbox')==='':false})()")
chk("sandbox_attr_empty", isTRUE(has_sandbox_attr), "sandbox=''")
# 脚本应被阻断:window.__pwned__ 不应被设置
pwned <- ev("window.__pwned__===true")
chk("script_isolated", !isTRUE(pwned), sprintf("(__pwned__=%s)", pwned))
b$close(); proc$kill(); system("rm -f /tmp/hs.log /tmp/hs.err")
cat("DONE\n")
