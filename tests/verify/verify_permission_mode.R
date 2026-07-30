# 验证 permission_mode 在【连接时】生效:default 弹审批,bypassPermissions 不弹。
# 这是"切换模式=reset_clients 重连生效"修复的地基证据(切换后下条消息经此路径重连)。
# 真实 claude CLI(copilot-api :4141),需 .Renviron。
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
run_one <- function(mode, port){
  p <- callr::r_bg(function(proj,port,mode){setwd(proj);readRenviron(file.path(proj,".Renviron"));Sys.setenv(AUI_TEST_MODE=mode);suppressMessages(library(shiny));shiny::runApp("tests/verify/perm_mode_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)}, args=list(proj=PROJ,port=port,mode=mode), stdout=sprintf("/tmp/pm_%s.o",mode), stderr=sprintf("/tmp/pm_%s.e",mode))
  Sys.sleep(11)
  if(!p$is_alive()){cat(mode,"BOOT FAIL\n");return(NA)}
  b <- chromote::ChromoteSession$new(); ev<-function(js) tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
  b$Page$navigate(sprintf("http://127.0.0.1:%d/",port)); b$Page$loadEventFired(); Sys.sleep(4)
  ev("(function(){var t=document.querySelector('textarea,[contenteditable=true]');if(t)t.focus();return !!t})()"); Sys.sleep(0.4)
  b$Input$insertText(text="Use the Bash tool to run exactly this command and nothing else: touch /tmp/aui_perm_probe.txt")
  b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
  b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
  approval<-FALSE
  for(i in 1:30){Sys.sleep(1.5)
    if(isTRUE(ev("!!document.querySelector('[data-approval-deny-with-msg],[data-approval-always-single],[data-approval-always-toggle]')"))){approval<-TRUE;break}
    if(isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')"))) break
  }
  try(b$close(),silent=TRUE); try(p$kill(),silent=TRUE); approval
}
a1 <- run_one("default", 9771L)
a2 <- run_one("bypassPermissions", 9772L)
cat(sprintf("[%s] default mode prompts for Bash (approval=%s)\n", if(isTRUE(a1))"PASS" else "FAIL", a1))
cat(sprintf("[%s] bypassPermissions suppresses prompt (approval=%s)\n", if(isFALSE(a2))"PASS" else "FAIL", a2))
try(chromote::default_chromote_object()$get_browser()$get_process()$kill(),silent=TRUE)
system("rm -f /tmp/pm_* /tmp/aui_perm_probe.txt")
cat("PERM_MODE_DONE\n")
