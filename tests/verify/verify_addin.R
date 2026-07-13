#!/usr/bin/env Rscript
# 验证 addin:
#  (1) gadget app 在浏览器渲染 + 端到端能出回复(证明 addin 的 handler/cwd/options 全接线)。
#  (2) 直连 R SDK 证明 .addin_context_text 经 SystemPromptPreset(append=) 到达模型
#      (UI 里让 tool-happy 的 agent 复述选区不稳定,故用直连断言机制本身)。
suppressMessages({library(chromote);library(callr)})
`%||%`<-function(x,y)if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
chk<-function(n,c,d="")cat(sprintf("[%s] %-32s %s\n",if(isTRUE(c))"PASS" else "FAIL",n,d))

# ---- (1) UI e2e ----
p <- callr::r_bg(function(proj,port){setwd(proj);readRenviron(file.path(proj,".Renviron"));Sys.setenv(AUI_PORT=port);suppressMessages(library(shiny));shiny::runApp("tests/verify/addin_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)},
  args=list(proj=PROJ,port=9170), stdout="/tmp/ad.o", stderr="/tmp/ad.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE); Sys.sleep(13)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/ad.e"),10),sep="\n")} else {
  b <- chromote::ChromoteSession$new(); errs<-c()
  b$Runtime$enable()
  b$Runtime$consoleAPICalled(callback_=function(m){if(identical(m$type,"error"))errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" "))})
  b$Runtime$exceptionThrown(callback_=function(m){errs<<-c(errs,paste("EXC:",m$exceptionDetails$exception$description %||% ""))})
  b$Page$navigate("http://127.0.0.1:9170/"); b$Page$loadEventFired(); Sys.sleep(4)
  ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
  chk("gadget_renders", as.integer(ev("document.querySelectorAll('.aui-root').length"))>=1)
  ev("(function(){var t=document.querySelector('textarea');if(t)t.focus();return !!t})()");Sys.sleep(0.4)
  b$Input$insertText(text="say hi in exactly two words"); Sys.sleep(0.3)
  b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
  b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
  replied<-FALSE
  for(i in 1:40){Sys.sleep(2);if(isTRUE(ev("!!document.querySelector('[data-slot=aui_usage_footer]')"))){replied<-TRUE;break}}
  chk("e2e_reply_produced", replied)
  chk("no_react_crash", !any(grepl("React error #31|not valid as a React child|Minified React",errs)))
  try(b$close(),silent=TRUE); try(b$parent$get_browser()$get_process()$kill(),silent=TRUE)
}
try(p$kill(),silent=TRUE); Sys.sleep(1)

# ---- (2) context append 到达模型(直连 SDK,可靠)----
tok <- tryCatch({
  suppressMessages(library(ClaudeAgentSDK)); readRenviron(file.path(PROJ,".Renviron"))
  suppressMessages(pkgload::load_all(PROJ, quiet=TRUE))
  ctx <- list(rel="R/ZebraQuokka.R", selection="ZebraQuokka42 <- function() 'unique-marker-9x'", first_line=10L, last_line=10L)
  appnd <- shinyAssistantUI:::.addin_context_text(ctx, PROJ)   # 用真实构造器
  cl <- ClaudeSDKClient$new(ClaudeAgentOptions(permission_mode="bypassPermissions",
        include_partial_messages=TRUE, system_prompt=SystemPromptPreset(append=appnd)))
  cl$connect(); cl$send("From the code snippet in your system context, what function name is defined? Reply with only that name, no tools.")
  t0<-Sys.time(); txt<-""; done<-FALSE
  repeat{ ms<-cl$poll_messages()
    for(m in ms){ if(inherits(m,"AssistantMessage")) for(bl in m$content) if(inherits(bl,"TextBlock")) txt<-paste0(txt,bl$text)
                  if(inherits(m,"ResultMessage")) done<-TRUE }
    if(done||as.numeric(Sys.time()-t0)>75)break; Sys.sleep(0.1) }
  tryCatch(cl$disconnect(),error=function(e)NULL); txt
}, error=function(e) paste("ERR:",conditionMessage(e)))
chk("context_append_reaches_model", grepl("ZebraQuokka42", tok), substr(tok,1,80))

system("rm -f /tmp/ad.*"); cat("AD_DONE\n")
