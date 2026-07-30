# Plan 45 批1 无头验证:composer 内联按可见性隐藏 YOLO;Settings 有默认模式+可见性控件;
# 切换可见性回调触发(stderr SET_VIS);0 console error。
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"; PORT <- 9799L
p <- callr::r_bg(function(proj, port){setwd(proj);suppressMessages(library(shiny));shiny::runApp("tests/verify/settings_ux_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)}, args=list(proj=PROJ,port=PORT), stdout="/tmp/su.o", stderr="/tmp/su.e")
on.exit(try(p$kill(),silent=TRUE),add=TRUE); Sys.sleep(10)
if(!p$is_alive()){cat("BOOT FAIL\n");cat(tail(readLines("/tmp/su.e"),8),sep="\n");quit(status=1)}
errs<-c(); b<-chromote::ChromoteSession$new(); b$Runtime$enable()
b$Runtime$consoleAPICalled(callback_=function(m) if(identical(m$type,"error")) errs<<-c(errs,paste(sapply(m$args,function(a)a$value %||% a$description %||% ""),collapse=" ")))
ev<-function(js) tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
b$Page$navigate(sprintf("http://127.0.0.1:%d/",PORT)); b$Page$loadEventFired(); Sys.sleep(5)

# composer 内联选择器:含 Bypass,不含 YOLO(showYolo=FALSE)
vals <- ev("(function(){var s=document.querySelector('select[aria-label=\"Permission mode\"]');if(!s)return 'NONE';return [...s.options].map(o=>o.value).join(',')})()")
cat("composer inline options:", vals, "\n")
cat(sprintf("[%s] composer inline hides YOLO, keeps Bypass\n", if(!is.na(vals) && grepl("bypassPermissions",vals) && !grepl("yolo",vals)) "PASS" else "FAIL"))

# 打开 Settings
ev("(function(){var b=[...document.querySelectorAll('button')].find(x=>/Settings/.test(x.getAttribute('aria-label')||''));if(b)b.click();return !!b})()"); Sys.sleep(1)
has_default <- ev("!!document.querySelector('[data-slot=aui_default_permission_mode]')")
has_bypass_vis <- ev("!!document.querySelector('[data-mode-vis=showBypass]')")
has_yolo_vis <- ev("!!document.querySelector('[data-mode-vis=showYolo]')")
cat(sprintf("[%s] Settings has default-mode select\n", if(isTRUE(has_default))"PASS" else "FAIL"))
cat(sprintf("[%s] Settings has Show Bypass + Show YOLO toggles\n", if(isTRUE(has_bypass_vis)&&isTRUE(has_yolo_vis))"PASS" else "FAIL"))
# 默认模式 select 也应隐藏 YOLO
dvals <- ev("(function(){var s=document.querySelector('[data-slot=aui_default_permission_mode]');if(!s)return 'NONE';return [...s.options].map(o=>o.value).join(',')})()")
cat(sprintf("[%s] default-mode select hides YOLO\n", if(!is.na(dvals)&&!grepl("yolo",dvals))"PASS" else "FAIL"))

# 勾选 Show YOLO → 回调 SET_VIS
ev("(function(){var c=document.querySelector('[data-mode-vis=showYolo] input');if(c)c.click();return !!c})()"); Sys.sleep(1)
sv <- any(grepl("SET_VIS", tryCatch(readLines("/tmp/su.e"), error=function(e) character())))
cat(sprintf("[%s] toggling visibility fires persistence callback (SET_VIS)\n", if(sv)"PASS" else "FAIL"))
# run_r 开关渲染 + 切换回调
has_runr <- ev("!!document.querySelector('[data-slot=aui_run_r_toggle]')")
cat(sprintf("[%s] Settings has run_r toggle\n", if(isTRUE(has_runr))"PASS" else "FAIL"))
ev("(function(){var c=document.querySelector('[data-slot=aui_run_r_toggle] input');if(c)c.click();return !!c})()"); Sys.sleep(1)
srr <- any(grepl("SET_RUNR", tryCatch(readLines("/tmp/su.e"), error=function(e) character())))
cat(sprintf("[%s] toggling run_r fires callback (SET_RUNR)\n", if(srr)"PASS" else "FAIL"))
cat(sprintf("[%s] no console errors (%d)\n", if(length(errs)==0)"PASS" else "FAIL", length(errs)))
if(length(errs)) cat(head(unique(errs),3),sep="\n")
b$close(); p$kill(); system("rm -f /tmp/su.*")
cat("SETTINGS_UX_DONE\n")
