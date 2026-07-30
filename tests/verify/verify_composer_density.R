# Plan 45 批3 无头验证:两档 composer 高度 → --composer-min-height 不同 + 自动增高仍在。
suppressMessages({library(chromote); library(callr)})
`%||%` <- function(x, y) if (is.null(x)) y else x
PROJ <- "/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI"
measure <- function(density, port) {
  p <- callr::r_bg(function(proj, port, d){setwd(proj);Sys.setenv(AUI_TEST_DENSITY=d);suppressMessages(library(shiny));shiny::runApp("tests/verify/settings_ux_app.R",host="127.0.0.1",port=port,launch.browser=FALSE)}, args=list(proj=PROJ,port=port,d=density), stdout=sprintf("/tmp/cd_%s.o",density), stderr=sprintf("/tmp/cd_%s.e",density))
  Sys.sleep(9)
  if(!p$is_alive()){cat(density,"BOOT FAIL\n");return(NULL)}
  b <- chromote::ChromoteSession$new(); ev<-function(js) tryCatch(b$Runtime$evaluate(js)$result$value,error=function(e)NA)
  b$Page$navigate(sprintf("http://127.0.0.1:%d/",port)); b$Page$loadEventFired(); Sys.sleep(4)
  minh <- ev("(function(){var e=document.querySelector('.aui-composer-input');if(!e)return null;return getComputedStyle(e).minHeight})()")
  maxh <- ev("(function(){var e=document.querySelector('.aui-composer-input');if(!e)return null;return getComputedStyle(e).maxHeight})()")
  try(b$close(),silent=TRUE); try(p$kill(),silent=TRUE)
  list(minh=minh, maxh=maxh)
}
comf <- measure("comfortable", 9791L)
comp <- measure("compact", 9792L)
cat(sprintf("comfortable min-height=%s max-height=%s\n", comf$minh %||% "NA", comf$maxh %||% "NA"))
cat(sprintf("compact     min-height=%s max-height=%s\n", comp$minh %||% "NA", comp$maxh %||% "NA"))
px <- function(s) suppressWarnings(as.numeric(sub("px","",s %||% "")))
ok_diff <- !is.na(px(comf$minh)) && !is.na(px(comp$minh)) && px(comp$minh) < px(comf$minh)
cat(sprintf("[%s] compact min-height < comfortable min-height\n", if(ok_diff)"PASS" else "FAIL"))
# 自动增高仍在:max-height 有限(非 none)→ 打字可增高到上限
ok_grow <- !is.na(px(comf$maxh)) && !is.na(px(comp$maxh))
cat(sprintf("[%s] auto-grow preserved (finite max-height both)\n", if(ok_grow)"PASS" else "FAIL"))
try(chromote::default_chromote_object()$get_browser()$get_process()$kill(),silent=TRUE)
system("rm -f /tmp/cd_*")
cat("COMPOSER_DENSITY_DONE\n")
