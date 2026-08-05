# Plan 51 B 无头验证:真实 codeagent(default 模式)→ 权限 gate → 审批卡桥。
# 断言:① 敏感工具(RunR)弹出审批卡 .aui-shiny-approval;② 卡在视口内;
#       ③ 点 Approve → 工具执行(结果 42 + data-approval-result=approved);
#       ④ 再次触发 → 点 Deny → data-approval-result=denied(deny 路径生效);
#       ⑤ 全程 0 console error。真 LLM via :4141。
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x,y) if(is.null(x))y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9865L
p <- callr::r_bg(function(proj,port){setwd(proj);suppressMessages(library(shiny));
      shiny::runApp("examples/27_codeagent_backend.R",host="127.0.0.1",port=port,launch.browser=FALSE)},
      args=list(proj=PROJ,port=PORT),stdout="/tmp/caap.o",stderr="/tmp/caap.e")
on.exit({try(p$kill(),silent=TRUE);system("rm -f /tmp/caap.*")},add=TRUE); Sys.sleep(14)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/caap.e"),20),sep="\n");quit(status=1)}

errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
b$Runtime$exceptionThrown(callback_=function(m) errs<<-c(errs, m$exceptionDetails$exception$description %||% "exception"))
ev<-function(js)tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
invisible(b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT))); b$Page$loadEventFired(); Sys.sleep(4)

send<-function(text){
  ev("(function(){var t=document.querySelector('[contenteditable=true]');if(t)t.focus();return !!t})()"); Sys.sleep(0.4)
  b$Input$insertText(text=text)
  b$Input$dispatchKeyEvent(type="keyDown",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
  b$Input$dispatchKeyEvent(type="keyUp",key="Enter",code="Enter",windowsVirtualKeyCode=13L)
}
wait_for<-function(js, timeout=75){ for(i in seq_len(timeout*2)){Sys.sleep(0.5); if(isTRUE(ev(js)))return(TRUE); if(!p$is_alive())return(NA)}; FALSE }
# click a button whose trimmed innerText EXACTLY equals `label`, inside .aui-shiny-approval
click_btn<-function(label) ev(sprintf("(function(){var c=document.querySelector('.aui-shiny-approval');if(!c)return false;var b=[].slice.call(c.querySelectorAll('button')).find(function(x){return (x.innerText||'').trim()===%s});if(b){b.click();return true}return false})()", paste0("'",label,"'")))

# ── round 1: RunR → approval card → Approve → executes (42) ───────────────────
send("Use run_r to compute 6*7 and print only the number. One tool call.")
a1 <- wait_for("!!document.querySelector('.aui-shiny-approval')", 75)
cat(sprintf("[%s] sensitive tool raised an approval card (gate->ask_fn->card bridge)\n", if(isTRUE(a1))"PASS" else "FAIL"))
inview <- ev("(function(){var e=document.querySelector('.aui-shiny-approval');if(!e)return false;var r=e.getBoundingClientRect();return r.height>0 && r.top>=0 && r.bottom<=(window.innerHeight+2)})()")
cat(sprintf("[%s] approval card is inside the viewport (real-time scroll)\n", if(isTRUE(inview))"PASS" else "FAIL"))
ok1 <- click_btn("Approve"); cat(sprintf("[%s] clicked Approve\n", if(isTRUE(ok1))"PASS" else "FAIL"))
appr <- wait_for("(function(){return !!document.querySelector('[data-approval-result=approved]')})()", 30)
exec <- wait_for("/42/.test(document.body.innerText)", 60)
cat(sprintf("[%s] approved -> decision=approved AND tool executed (42 present)\n", if(isTRUE(appr) && isTRUE(exec))"PASS" else "FAIL"))

# ── round 2: RunR again → Deny → decision=denied ─────────────────────────────
Sys.sleep(2)
send("Now use run_r to print the text DENYME. One tool call.")
a2 <- wait_for("(function(){var n=document.querySelectorAll('.aui-shiny-approval');return n.length>=1})()", 75)
ok2 <- if(isTRUE(a2)) click_btn("Deny") else FALSE
den <- if(isTRUE(ok2)) wait_for("(function(){return document.querySelectorAll('[data-approval-result=denied]').length>=1})()", 30) else FALSE
cat(sprintf("[%s] second call raised a card, Deny clicked -> decision=denied\n", if(isTRUE(a2)&&isTRUE(ok2)&&isTRUE(den))"PASS" else "FAIL"))

cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat("  errs:", paste(utils::head(errs,3),collapse=" | "),"\n")
if(!p$is_alive()) cat("  (app process died mid-run!)\n")
b$close(); p$kill()
cat("CODEAGENT_APPROVAL_DONE\n")
