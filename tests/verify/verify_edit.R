suppressPackageStartupMessages({
  library(callr)
  library(chromote)
  library(jsonlite)
})
main <- function() {
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  `%||%` <- function(x, y) if (is.null(x)) y else x
  project <- normalizePath(".", winslash = "/", mustWork = TRUE)
  port <- httpuv::randomPort()
  logs <- c(tempfile("aui-edit-out-"), tempfile("aui-edit-err-"))
  failures <- character()
  chk <- function(name, cond, detail = "") {
    ok <- isTRUE(cond)
    cat(sprintf("[%s] %-52s %s\n", if (ok) "PASS" else "FAIL", name, detail))
    if (!ok) failures <<- c(failures, name)
    invisible(ok)
  }
  app <- callr::r_bg(function(project, port) {
    setwd(project)
    suppressPackageStartupMessages(library(shiny))
    shiny::runApp("tests/verify/edit_app.R", host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project = project, port = port), stdout = logs[[1L]], stderr = logs[[2L]])
  browser <- NULL
  cleanup <- make_verification_cleanup(function() browser, function() app, logs)
  on.exit(cleanup(), add = TRUE)
  for (i in seq_len(100)) {
    if (!app$is_alive()) break
    if (file.exists(logs[[2L]]) && any(grepl("Listening on", readLines(logs[[2L]], warn = FALSE)))) break
    Sys.sleep(0.25)
  }
  if (!app$is_alive()) {
    cat(tail(readLines(logs[[2L]], warn = FALSE), 20), sep = "\n")
    stop("boot failed")
  }

  chromote::set_chrome_args(unique(c(chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu")))
  browser <- ChromoteSession$new(width = 760, height = 900)
  console_errors <- character()
  browser$Runtime$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(m) {
    if (identical(m$type, "error")) {
      console_errors <<- c(console_errors, paste(vapply(m$args, function(a) {
        as.character(a$value %||% a$description %||% "")
      }, character(1)), collapse = " "))
    }
  })
  browser$Runtime$exceptionThrown(callback_ = function(m) {
    console_errors <<- c(
      console_errors, m$exceptionDetails$exception$description %||% m$exceptionDetails$text
    )
  })
  value <- function(s) {
    r <- browser$Runtime$evaluate(s, returnByValue = TRUE)
    if (!is.null(r$exceptionDetails)) stop(r$exceptionDetails$text)
    r$result$value
  }
  wait_for <- function(s, t = 15, i = 0.05) {
    d <- Sys.time() + t
    repeat {
      if (isTRUE(tryCatch(value(s), error = function(e) FALSE))) {
        return(TRUE)
      }
      if (Sys.time() >= d) {
        return(FALSE)
      }
      Sys.sleep(i)
    }
  }
  click_sel_native <- function(js_el) value(sprintf("(function(){const e=%s;if(!e)return false;e.click();return true})()", js_el))
  click_xy <- function(sel) {
    j <- value(sprintf("(function(){const e=document.querySelector(%s);if(!e)return null;const r=e.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()", jsonlite::toJSON(sel, auto_unbox = TRUE)))
    if (is.null(j)) {
      return(FALSE)
    }
    p <- fromJSON(j)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = p$x, y = p$y, button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = p$x, y = p$y, button = "left", clickCount = 1L)
    TRUE
  }
  press_key <- function(key, code, vk, mods = 0L) {
    browser$Input$dispatchKeyEvent(type = "keyDown", key = key, code = code, windowsVirtualKeyCode = vk, modifiers = mods)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = key, code = code, windowsVirtualKeyCode = vk, modifiers = mods)
  }

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  chk("widget mounted", wait_for("!!document.querySelector('.aui-root')", 15))
  # 1) 首发消息
  click_xy(".aui-lexical-input[contenteditable='true']")
  Sys.sleep(0.35)
  browser$Input$insertText(text = "first")
  Sys.sleep(0.25)
  press_key("Enter", "Enter", 13L)
  chk("first reply streamed (echo: first)", wait_for("document.body.innerText.includes('echo: first')", 12))
  # 2) 真实指针 hover 用户气泡 → autohide 揭示 pencil(0.15.0 下 autohide 会卸载而非透明)
  hover_msg <- function() {
    j <- value("(function(){const m=document.querySelector('[data-role=\"user\"] .aui-user-message-content')||document.querySelector('[data-role=\"user\"]');if(!m)return null;const r=m.getBoundingClientRect();return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2})})()")
    if (is.null(j)) {
      return(FALSE)
    }
    p <- fromJSON(j)
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = p$x, y = p$y)
    TRUE
  }
  hover_msg()
  Sys.sleep(0.3)
  chk("edit pencil appears on hover", wait_for("!!document.querySelector('svg.lucide-pencil')", 6))
  edited_pencil <- click_sel_native("document.querySelector('svg.lucide-pencil')?.closest('button')")
  chk("clicked edit pencil", isTRUE(edited_pencil))
  chk("edit composer opened", wait_for("!!document.querySelector('.aui-edit-composer-input')", 6))
  # 3) 改文本:聚焦 → 全选 → 输入新文本
  click_xy(".aui-edit-composer-input")
  Sys.sleep(0.2)
  press_key("a", "KeyA", 65L, mods = 2L) # Ctrl+A 全选
  Sys.sleep(0.1)
  browser$Input$insertText(text = "second")
  Sys.sleep(0.25)
  edit_text <- value("document.querySelector('.aui-edit-composer-input')?.value || document.querySelector('.aui-edit-composer-input')?.innerText || ''")
  cat("   edit input text now:", edit_text, "\n")
  # 4) 点击 Update(edit composer 里的 Send 按钮,文本为 Update)
  upd <- click_sel_native("Array.from(document.querySelectorAll('.aui-edit-composer-root button')).find(b=>/update/i.test(b.textContent))")
  chk("clicked Update button", isTRUE(upd))
  # 5) 期望重新触发 handler → 新回复 echo: second
  chk(
    "edit->Update RE-TRIGGERS handler (echo: second)", wait_for("document.body.innerText.includes('echo: second')", 12),
    value("document.body.innerText.slice(-80).replace(/\\s+/g,' ')")
  )
  edited_history <- paste0(
    "document.querySelectorAll('[data-role=user]').length===1&&",
    "document.querySelectorAll('[data-role=assistant]').length===1&&",
    "document.querySelector('[data-role=user]')?.textContent.includes('second')&&",
    "document.querySelector('[data-role=assistant]')?.textContent.includes('echo: second')"
  )
  chk("edit replaces the original branch without duplicate messages", wait_for(edited_history))
  browser$Page$reload()
  browser$Page$loadEventFired()
  chk("edited branch survives history reload", wait_for(edited_history))

  chk("no browser console errors", length(console_errors) == 0, if (length(console_errors)) paste(utils::head(console_errors, 3), collapse = " | ") else "0 errors")
  cleanup()
  if (length(failures)) stop("verification failed: ", paste(failures, collapse = ", "))
  cat("EDIT_VERIFY_DONE\n")
}
main()
