#!/usr/bin/env Rscript
# 验证审批工具卡不再重复:一次 tool call = 一张卡(合并流式+审批),无 Interrupted 幽灵卡。
suppressMessages({library(chromote);library(callr)})
`%||%`<-function(x,y)if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
p <- callr::r_bg(function(proj,port){setwd(proj);readRenviron(file.path(proj,".Renviron"));suppressMessages(library(shiny));shiny::runApp("examples/11_tool_calling_claude_sdk.R",host="127.0.0.1",port=port,launch.browser=FALSE)},
  args=list(proj=PROJ,port=9175), stdout="/tmp/ap.o", stderr="/tmp/ap.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE); Sys.sleep(12)
if(!p$is_alive()){cat("BOOT FAIL\n");quit()}
b <- chromote::ChromoteSession$new(); errs<-c()
b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m){if(identical(m$type,"error"))errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" "))})
b$Runtime$exceptionThrown(callback_=function(m){errs<<-c(errs,paste("EXC:",m$exceptionDetails$exception$description %||% ""))})
b$Page$navigate("http://127.0.0.1:9175/"); b$Page$loadEventFired(); Sys.sleep(4)
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
ev("(function(){var t=document.querySelector('textarea');if(t)t.focus();return !!t})()");Sys.sleep(0.4)
b$Input$insertText(text="查看武汉天气"); Sys.sleep(0.3)
b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
napprove <- 0
for(i in 1:60){
  Sys.sleep(2)
  clicked <- ev("(function(){var bs=Array.from(document.querySelectorAll('button')).filter(b=>/^\\s*Approve\\s*$/.test(b.innerText));bs.forEach(b=>b.click());return bs.length})()")
  if(!is.na(clicked)) napprove <- napprove + as.integer(clicked)
  if(isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')"))) break
}
Sys.sleep(2)
cat("approvals clicked:", napprove, "\n")
cat("tool card titles:", ev("JSON.stringify(Array.from(document.querySelectorAll('[data-slot=tool-fallback-trigger-label]')).map(e=>e.innerText.replace(/\\s+/g,' ').trim()))"), "\n")
ncards <- as.integer(ev("document.querySelectorAll('[data-slot=tool-fallback-trigger]').length"))
dup <- ev("(function(){var t=Array.from(document.querySelectorAll('[data-slot=tool-fallback-trigger-label]')).map(e=>e.innerText.replace(/\\s+/g,' ').trim());var seen={},d=false;t.forEach(x=>{if(seen[x])d=true;seen[x]=1});return d})()")
chk<-function(n,c,d="")cat(sprintf("[%s] %-28s %s\n",if(isTRUE(c))"PASS" else "FAIL",n,d))
chk("no_duplicate_tool_cards", isTRUE(!isTRUE(dup)), paste("cards=",ncards))
chk("no_interrupted_ghost", !isTRUE(ev("/Interrupted/.test(document.body.innerText)")))
chk("no_react_crash", !any(grepl("React error #31|not valid as a React child|Minified React",errs)))
chk("got_final_answer", ev("/武汉|weather|天气|°C|温度/.test(document.body.innerText)"))
if(length(errs)) { cat("=== console errors ===\n"); cat(head(unique(errs),3),sep="\n") }
b$close();p$kill();system("rm -f /tmp/ap.*")
cat("AP_DONE\n")
