#!/usr/bin/env Rscript
suppressMessages({ library(chromote); library(callr) })
PORT <- 8934
proc <- callr::r_bg(function(port) {
  setwd("/usrfiles/shared-projects/users/kaiping_yang/shinyAssistantUI")
  suppressMessages(library(shiny))
  shiny::runApp("tests/verify/theme_app.R", host = "127.0.0.1",
                port = port, launch.browser = FALSE)
}, args = list(port = PORT), stdout = "/tmp/theme.log", stderr = "/tmp/theme.err")
on.exit({ try(proc$kill(), silent = TRUE) }, add = TRUE)
Sys.sleep(9)
if (!proc$is_alive()) { cat(readLines("/tmp/theme.err"), sep="\n"); quit(status=1) }

b <- ChromoteSession$new()
b$Page$navigate(sprintf("http://127.0.0.1:%d/", PORT)); b$Page$loadEventFired()
Sys.sleep(4)
ev <- function(js) b$Runtime$evaluate(js)$result$value
chk <- function(name, cond, detail="") cat(sprintf("[%s] %-32s %s\n", if(isTRUE(cond))"PASS" else "FAIL", name, detail))

gp <- function(id, varname)
  ev(sprintf("getComputedStyle(document.getElementById('%s')).getPropertyValue('%s').trim()", id, varname))

# ── 浅色自定义主题 widget ─────────────────────────────────────────────────────
primary_light <- gp("chat_light", "--aui-primary")
bg_light      <- gp("chat_light", "--aui-background")
radius_light  <- gp("chat_light", "--aui-radius")
cat("chat_light --aui-primary   =", primary_light, "\n")
cat("chat_light --aui-background=", bg_light, "\n")
cat("chat_light --aui-radius    =", radius_light, "\n")
# #2563eb ≈ 221 83.3% 53.3%
chk("theme_primary_injected", grepl("^221 ", primary_light) && grepl("%", primary_light), primary_light)
# #eff6ff ≈ 214 100% 96.9%
chk("theme_background_injected", grepl("^214 ", bg_light), bg_light)
chk("theme_radius_injected", identical(radius_light, "1rem"), radius_light)
# inline style attribute 确实带这些变量(scoped 到本 widget)
has_inline <- ev("document.getElementById('chat_light').getAttribute('style').includes('--aui-primary')")
chk("theme_scoped_inline_style", isTRUE(has_inline), "")

# ── 暗色 widget ───────────────────────────────────────────────────────────────
has_dark_cls <- ev("document.getElementById('chat_dark').classList.contains('dark')")
bg_dark      <- gp("chat_dark", "--aui-background")
fg_dark      <- gp("chat_dark", "--aui-foreground")
cat("chat_dark has .dark        =", has_dark_cls, "\n")
cat("chat_dark --aui-background =", bg_dark, "\n")
cat("chat_dark --aui-foreground =", fg_dark, "\n")
chk("dark_class_applied", isTRUE(has_dark_cls), "")
# 暗色背景 = 0 0% 7%(与浅色 0 0% 100% 不同)
chk("dark_palette_active", grepl("0 0% 7%", bg_dark) || grepl("7%", bg_dark), bg_dark)
# 浅色 widget 未被加 dark 类(隔离)
light_no_dark <- ev("!document.getElementById('chat_light').classList.contains('dark')")
chk("per_widget_isolation", isTRUE(light_no_dark), "")

try(b$screenshot("/tmp/theme_shot.png"), silent = TRUE)
b$close(); proc$kill()
cat("DONE\n")
