# Plan45 B验证:compact 单行内联 composer(≈shinychat 扁平),总高显著低于 comfortable。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
meas<-function(d,port){
  p<-callr::r_bg(function(proj,port,d){setwd(proj);Sys.setenv(AUI_TEST_DENSITY=d);suppressMessages(library(shiny));shiny::runApp("tests/verify/settings_ux_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=port,d=d),stdout=sprintf("/tmp/f_%s.o",d),stderr=sprintf("/tmp/f_%s.e",d))
  Sys.sleep(9)
  b<-chromote::ChromoteSession$new();ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
  b$Page$navigate(sprintf("http://127.0.0.1:%d/",port));b$Page$loadEventFired();Sys.sleep(4)
  h<-ev("(function(){var e=document.querySelector('[data-slot=aui_composer-shell]');return e?Math.round(e.getBoundingClientRect().height):null})()")
  send<-ev("!!document.querySelector('.aui-composer-send, .aui-composer-compact-row .aui-composer-send')")
  compactrow<-ev("!!document.querySelector('.aui-composer-compact-row')")
  try(b$close(),silent=TRUE);try(p$kill(),silent=TRUE)
  list(h=h,send=send,row=compactrow)
}
cf<-meas("comfortable",9811L); cp<-meas("compact",9812L)
cat(sprintf("comfortable shell=%spx (send=%s)\n", cf$h %||% "NA", cf$send))
cat(sprintf("compact     shell=%spx (send=%s, single-row=%s)\n", cp$h %||% "NA", cp$send, cp$row))
cat(sprintf("[%s] compact single-row present\n", if(isTRUE(cp$row))"PASS" else "FAIL"))
cat(sprintf("[%s] send button present in compact\n", if(isTRUE(cp$send))"PASS" else "FAIL"))
cat(sprintf("[%s] compact notably shorter (>=25%% drop)\n", if(!is.na(cf$h)&&!is.na(cp$h)&&cp$h<=cf$h*0.75)"PASS" else "FAIL"))
try(chromote::default_chromote_object()$get_browser()$get_process()$kill(),silent=TRUE);system("rm -f /tmp/f_*")
cat("COMPOSER_FLAT_DONE\n")
