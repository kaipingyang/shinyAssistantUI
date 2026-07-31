# ModelSelector 位置:应在 composer 输入框内部底部行(而非顶部)。fixture=thinking_app.R(含 model)。
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9761L
p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/thinking_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)}, args=list(proj=PROJ,port=PORT), stdout="/tmp/mp.o", stderr="/tmp/mp.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/mp.e"),8),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
b$Runtime$exceptionThrown(callback_=function(m) errs<<-c(errs,paste("EXC:",m$exceptionDetails$exception$description %||% m$exceptionDetails$text %||% "")))
ev<-function(js) tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT)); b$Page$loadEventFired(); Sys.sleep(5)
cat(sprintf("[%s] model-selector trigger exists\n", if(isTRUE(ev("!!document.querySelector('[data-slot=model-selector-trigger]')")))"PASS" else "FAIL"))
cat(sprintf("[%s] trigger INSIDE composer shell bottom row\n", if(isTRUE(ev("!!document.querySelector('.aui-composer-action-wrapper [data-slot=model-selector-trigger]')")))"PASS" else "FAIL"))
cat(sprintf("[%s] trigger NOT at composer top\n", if(!isTRUE(ev("!!document.querySelector('.aui-composer-root > [data-slot=model-selector-trigger]')")))"PASS" else "FAIL"))
ev("(function(){var t=document.querySelector('[data-slot=model-selector-trigger]');if(t)t.click();return true})()"); Sys.sleep(1)
cat(sprintf("[%s] popover opens in viewport\n", if(isTRUE(ev("(function(){var c=document.querySelector('[data-slot=model-selector-content]');if(!c)return false;var r=c.getBoundingClientRect();return r.width>0&&r.top>=0&&r.left>=0})()")))"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat(head(unique(errs),3),sep="\n")
b$close(); p$kill(); system("rm -f /tmp/mp.*")
cat("MODEL_POS_DONE\n")
