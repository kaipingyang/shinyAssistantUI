#!/usr/bin/env Rscript
# 验证 v0.1.0 观感回归:toolName(参数摘要) 标题 + 子agent嵌套缩进 + 无 React 崩溃。
suppressMessages({library(chromote);library(callr)})
`%||%`<-function(x,y)if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
p <- callr::r_bg(function(proj,port){setwd(proj);readRenviron(file.path(proj,".Renviron"));suppressMessages(library(shiny));shiny::runApp("tests/verify/task_progress_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},
  args=list(proj=PROJ,port=9176), stdout="/tmp/tc.o", stderr="/tmp/tc.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE); Sys.sleep(12)
if(!p$is_alive()){cat("BOOT FAIL\n");quit()}
b <- chromote::ChromoteSession$new(); errs<-c()
b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m){if(identical(m$type,"error"))errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" "))})
b$Runtime$exceptionThrown(callback_=function(m){errs<<-c(errs,paste("EXC:",m$exceptionDetails$exception$description %||% ""))})
b$Page$navigate("http://127.0.0.1:9176/"); b$Page$loadEventFired(); Sys.sleep(4)
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
chk<-function(n,c,d="")cat(sprintf("[%s] %-30s %s\n",if(isTRUE(c))"PASS" else "FAIL",n,d))
ev("(function(){var t=document.querySelector('textarea');if(t)t.focus();return !!t})()");Sys.sleep(0.4)
b$Input$insertText(text="Use the Task tool to launch a general-purpose subagent that runs the Bash command: echo hello-nested. Report its output.")
Sys.sleep(0.3)
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
for(i in 1:45){Sys.sleep(2);if(isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')")))break}
Sys.sleep(2)
# 标题含参数摘要:trigger label 里出现 "toolName(" 形式
titles <- ev("JSON.stringify(Array.from(document.querySelectorAll('[data-slot=tool-fallback-trigger-label]')).map(e=>e.innerText.replace(/\\n/g,'|')).slice(0,8))")
cat("tool titles:", titles, "\n")
chk("arg_summary_title", ev("Array.from(document.querySelectorAll('[data-slot=tool-fallback-trigger-label]')).some(e=>/\\(.+\\)/.test(e.innerText))"))
# 嵌套:存在 data-tool-depth>0 的卡(子agent里的工具)
depths <- ev("JSON.stringify(Array.from(document.querySelectorAll('[data-tool-depth]')).map(e=>e.getAttribute('data-tool-depth')))")
cat("tool depths:", depths, "\n")
chk("nested_tool_indent", ev("Array.from(document.querySelectorAll('[data-tool-depth]')).some(e=>parseInt(e.getAttribute('data-tool-depth'))>0)"))
# 新特性仍在
chk("usage_footer_present", isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')")))
# 无 React 崩溃
r31 <- any(grepl("React error #31|not valid as a React child|Minified React",errs))
chk("no_react_crash", !r31)
chk("aui_root_present", as.integer(ev("document.querySelectorAll('.aui-root').length"))>=1)
if(length(errs)) { cat("=== console errors ===\n"); cat(head(unique(errs),4),sep="\n") }
b$close();p$kill();system("rm -f /tmp/tc.*")
cat("TC_DONE\n")
