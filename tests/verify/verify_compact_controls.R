# Issue2 验证:compact 单行保留 model/permission/send 控件。
suppressMessages({library(chromote); library(callr)})
`%||%`<-function(x,y) if(is.null(x))y else x
PROJ<-"/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT<-9841L
p<-callr::r_bg(function(proj,port){setwd(proj);Sys.setenv(AUI_TEST_DENSITY="compact");suppressMessages(library(shiny));shiny::runApp("tests/verify/settings_ux_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},args=list(proj=PROJ,port=PORT),stdout="/tmp/cc.o",stderr="/tmp/cc.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE);Sys.sleep(10)
b<-chromote::ChromoteSession$new();ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT));b$Page$loadEventFired();Sys.sleep(4)
row<-"document.querySelector('.aui-composer-compact-row')"
cat(sprintf("[%s] compact row present\n", if(isTRUE(ev(paste0("!!",row))))"PASS" else "FAIL"))
cat(sprintf("[%s] model button in compact row\n", if(isTRUE(ev(paste0(row,".querySelector('[data-slot=model-selector-trigger]')!==null"))))"PASS" else "FAIL"))
cat(sprintf("[%s] permission select in compact row\n", if(isTRUE(ev(paste0(row,".querySelector('select[aria-label=\"Permission mode\"]')!==null"))))"PASS" else "FAIL"))
cat(sprintf("[%s] send button in compact row\n", if(isTRUE(ev(paste0(row,".querySelector('.aui-composer-send')!==null"))))"PASS" else "FAIL"))
b$close();p$kill();system("rm -f /tmp/cc.*")
cat("COMPACT_CONTROLS_DONE\n")
