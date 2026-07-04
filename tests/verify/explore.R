#!/usr/bin/env Rscript
# 探索验证 app 的 DOM，确定 composer 输入元素与提交方式
suppressMessages({ library(chromote); library(callr) })

PORT <- 8931
proc <- callr::r_bg(function(port) {
  setwd("/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI")
  suppressMessages(library(shiny))
  shiny::runApp("tests/verify/verify_app.R", host = "127.0.0.1",
                port = port, launch.browser = FALSE)
}, args = list(port = PORT), stdout = "/tmp/verify_app.log", stderr = "/tmp/verify_app.err")

on.exit({ try(proc$kill(), silent = TRUE) }, add = TRUE)
Sys.sleep(9)
cat("app alive:", proc$is_alive(), "\n")
if (!proc$is_alive()) { cat(readLines("/tmp/verify_app.err"), sep="\n"); quit(status=1) }

b <- ChromoteSession$new()
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT))
b$Page$loadEventFired()
Sys.sleep(4)
ev <- function(js) b$Runtime$evaluate(js)$result$value

cat("=== title ===\n"); cat(ev("document.title"), "\n")
cat("=== widget root exists ===\n")
cat(ev("!!document.querySelector('.aui-root, [id*=chat]')"), "\n")
cat("=== contenteditable count ===\n")
cat(ev("document.querySelectorAll('[contenteditable]').length"), "\n")
cat("=== textarea count ===\n")
cat(ev("document.querySelectorAll('textarea').length"), "\n")
cat("=== composer-ish class names ===\n")
cat(ev("Array.from(document.querySelectorAll('[class*=composer], [class*=Composer]')).map(e=>e.tagName+'.'+e.className).slice(0,12).join('\\n')"), "\n")
cat("=== all Shiny input ids (from bindings) ===\n")
cat(ev("(function(){try{return Object.keys(Shiny.shinyapp.$inputValues||{}).join(', ')}catch(e){return 'ERR:'+e.message}})()"), "\n")
cat("=== body text length ===\n")
cat(ev("document.body.innerText.length"), "\n")

b$close(); proc$kill()
cat("DONE\n")
