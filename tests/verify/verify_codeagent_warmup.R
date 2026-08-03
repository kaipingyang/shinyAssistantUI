# Plan 51 A — cold-start fix:codeagent client 后台预热(prewarm),UI 立即可交互 + 显示 warming 指示,
# 不再因 codeagent_client 构造(~4s)白屏/冻结。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9879L
p<-callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("examples/27_codeagent_backend.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/wu.o",stderr="/tmp/wu.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(12)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/wu.e",warn=FALSE),15),sep="\n");quit(status=1)}
errs<-c();b<-chromote::ChromoteSession$new();b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
t0<-Sys.time()
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired()
composer_t<-NA; for(i in 1:40){Sys.sleep(0.25); if(isTRUE(ev("!!document.querySelector('[contenteditable=true]')"))){composer_t<-as.numeric(Sys.time()-t0);break}}
cat(sprintf("[%s] composer interactive fast (%.1fs after navigate, <4s)\n", if(!is.na(composer_t) && composer_t<4)"PASS" else "FAIL", composer_t %||% NA))
# 欢迎界面(空状态):自定义 welcome 文案 + starter 建议气泡
welcome<-ev("document.querySelector('.aui-thread-welcome-root')?.innerText||''") %||% ""
cat(sprintf("[%s] welcome message shown (custom, English): %s\n", if(grepl("codeagent is ready",welcome))"PASS" else "FAIL", substr(gsub("\n"," ",welcome),1,60)))
warmed_seen<-FALSE; wtxt<-""; for(i in 1:24){wt<-ev("document.querySelector('[data-slot=aui_warming]')?.innerText||''") %||% ""; if(nzchar(wt)){warmed_seen<-TRUE;wtxt<-wt;break}; Sys.sleep(0.25)}
cat(sprintf("[%s] warming indicator English/codeagent (not 'Claude Code'): %s\n", if(warmed_seen && grepl("codeagent",wtxt) && !grepl("Claude Code",wtxt))"PASS" else "FAIL", trimws(gsub("\n"," ",wtxt))))
for(i in 1:40){if(!isTRUE(ev("!!document.querySelector('[data-slot=aui_warming]')"))) break; Sys.sleep(0.5)}
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
b$close();p$kill();system("rm -f /tmp/wu.*")
cat("CODEAGENT_WARMUP_DONE\n")
