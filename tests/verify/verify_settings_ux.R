# Installed synthetic controls/settings gate; no provider or RStudio execution.
suppressPackageStartupMessages({
  library(chromote)
  library(callr)
})
source("tests/verify/owned_process_cleanup.R")

main <- function() {
  project <- normalizePath(".")
  port <- httpuv::randomPort()
  stdout <- tempfile("settings-stdout-")
  stderr <- tempfile("settings-stderr-")
  app <- browser <- NULL
  cleanup <- make_verification_cleanup(
    function() browser, function() app, c(stdout, stderr)
  )
  on.exit(cleanup(), add = TRUE)
  app <- callr::r_bg(function(project, port) {
    setwd(project)
    Sys.setenv(AUI_TEST_DENSITY = "comfortable")
    library(shiny)
    library(shinyAssistantUI)
    package_path <- normalizePath(find.package("shinyAssistantUI"))
    stopifnot(startsWith(package_path, paste0(normalizePath(path.expand("~")), "/")))
    message("INSTALL=", package_path, " VERSION=", packageVersion("shinyAssistantUI"))
    shiny::runApp("tests/verify/settings_ux_app.R",
      host = "127.0.0.1", port = port, launch.browser = FALSE
    )
  }, args = list(project = project, port = port), stdout = stdout, stderr = stderr)
  log_lines <- function() readLines(stderr, warn = FALSE)
  for (i in seq_len(150L)) {
    if (!app$is_alive() || any(grepl("Listening on", log_lines(), fixed = TRUE))) break
    Sys.sleep(0.1)
  }
  if (!app$is_alive() || !any(grepl("Listening on", log_lines(), fixed = TRUE))) {
    stop(paste(log_lines(), collapse = "\n"), call. = FALSE)
  }
  cat(grep("INSTALL=", log_lines(), value = TRUE), "\n")

  errors <- network_errors <- character()
  browser <- ChromoteSession$new(width = 1000, height = 850)
  browser$Runtime$enable()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) {
      errors <<- c(errors, paste(vapply(event$args, function(arg) {
        if (!is.null(arg$value)) as.character(arg$value) else as.character(arg$description)
      }, character(1)), collapse = " "))
    }
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) {
    errors <<- c(errors, event$exceptionDetails$text)
  })
  browser$Network$loadingFailed(callback_ = function(event) {
    network_errors <<- c(network_errors, event$errorText)
  })
  browser$Network$responseReceived(callback_ = function(event) {
    if (event$response$status >= 400) {
      network_errors <<- c(network_errors, paste(event$response$status, event$response$url))
    }
  })
  value <- function(js) {
    result <- browser$Runtime$evaluate(js, returnByValue = TRUE)
    if (!is.null(result$exceptionDetails)) stop(result$exceptionDetails$text, call. = FALSE)
    result$result$value
  }
  checks <- 0L
  check <- function(label, ok) {
    cat(sprintf("[%s] %s\n", if (isTRUE(ok)) "PASS" else "FAIL", label))
    if (!isTRUE(ok)) stop(label, call. = FALSE)
    checks <<- checks + 1L
  }
  wait_for <- function(js, timeout = 8) {
    deadline <- Sys.time() + timeout
    repeat {
      if (isTRUE(value(js))) {
        return(TRUE)
      }
      if (Sys.time() >= deadline || !app$is_alive()) {
        return(FALSE)
      }
      Sys.sleep(0.1)
    }
  }
  quote_js <- function(text) as.character(jsonlite::toJSON(text, auto_unbox = TRUE))
  click <- function(selector) {
    target <- quote_js(selector)
    stopifnot(isTRUE(value(sprintf(
      "(() => {const e=document.querySelector(%s); if(!e)return false; e.scrollIntoView({block:'nearest'}); return true})()",
      target
    ))))
    Sys.sleep(0.15)
    point <- value(sprintf(
      "(() => {const e=document.querySelector(%s),r=e.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2,h=document.elementFromPoint(x,y); return {x,y,hit:!!h&&(e===h||e.contains(h))}})()",
      target
    ))
    stopifnot(isTRUE(point$hit))
    browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
    browser$Input$dispatchMouseEvent(type = "mousePressed", x = point$x, y = point$y, button = "left", clickCount = 1L)
    browser$Input$dispatchMouseEvent(type = "mouseReleased", x = point$x, y = point$y, button = "left", clickCount = 1L)
  }
  choose <- function(selector, selected) {
    stopifnot(isTRUE(value(sprintf(
      "(() => {const e=document.querySelector(%s);if(!e||![...e.options].some(o=>o.value===%s))return false;e.value=%s;e.dispatchEvent(new Event('change',{bubbles:true}));return true})()",
      quote_js(selector), quote_js(selected), quote_js(selected)
    ))))
    Sys.sleep(0.2)
  }
  in_viewport <- function(selector) {
    wait_for(sprintf(
      "(() => {const e=document.querySelector(%s);if(!e)return false;const r=e.getBoundingClientRect();return r.width>0&&r.height>0&&r.top>=0&&r.left>=0&&r.bottom<=innerHeight&&r.right<=innerWidth})()",
      quote_js(selector)
    ))
  }
  key <- function(name, code, key_code) {
    browser$Input$dispatchKeyEvent(type = "keyDown", key = name, code = code, windowsVirtualKeyCode = key_code)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = name, code = code, windowsVirtualKeyCode = key_code)
  }
  has_log <- function(text, timeout = 3) {
    deadline <- Sys.time() + timeout
    repeat {
      if (any(grepl(text, log_lines(), fixed = TRUE))) {
        return(TRUE)
      }
      if (Sys.time() >= deadline) {
        return(FALSE)
      }
      Sys.sleep(0.1)
    }
  }
  font_size <- function() {
    value(
      "parseFloat(getComputedStyle(document.querySelector('[data-slot=aui_assistant-text]')).fontSize)"
    )
  }
  settings <- "[data-slot=aui_settings_dialog]"
  permission <- 'select[aria-label="Permission mode"]'

  browser$Page$navigate(sprintf("http://127.0.0.1:%d/", port))
  browser$Page$loadEventFired()
  check("installed composer is ready", wait_for("!!document.querySelector('.aui-lexical-input[contenteditable=true]')"))
  check("unreported usage is unknown, not invented", isTRUE(value("!!document.querySelector('[aria-label=\"Context usage unavailable\"]')")))
  check("current mode starts Manual with Bypass visible and YOLO hidden", isTRUE(value(
    "(() => {const s=document.querySelector('select[aria-label=\"Permission mode\"]');return s.value==='default'&&[...s.options].some(o=>o.value==='bypassPermissions')&&![...s.options].some(o=>o.value==='yolo')})()"
  )))

  click("[data-slot=model-selector-trigger]")
  check("model picker opens inside the viewport", wait_for("!!document.querySelector('[data-slot=model-selector-content]')") &&
    in_viewport("[data-slot=model-selector-content]"))
  click("[data-slot=model-selector-item][data-value=opus]")
  check("model fixture ACK applies Opus and closes picker", wait_for(
    "document.querySelector('[data-slot=model-selector-value]')?.textContent.includes('Opus') && !document.querySelector('[data-slot=model-selector-content]') && document.querySelector('[data-slot=aui_model_control]')?.dataset.pending==='false'"
  ) && has_log("FIXTURE_ACTION=model:opus"))
  choose(permission, "plan")
  check("permission fixture ACK changes only the current mode", wait_for(
    "document.querySelector('select[aria-label=\"Permission mode\"]')?.value==='plan' && !document.querySelector('select[aria-label=\"Permission mode\"]')?.disabled && document.querySelector('[data-slot=model-selector-value]')?.textContent.includes('Opus')"
  ) && has_log("FIXTURE_ACTION=permissions:plan"))

  click('button[aria-label="Settings"]')
  check("Settings dialog is visible and within viewport", wait_for("!!document.querySelector('[data-slot=aui_settings_dialog]')") && in_viewport(settings))
  check("new-thread default is independent of current mode", isTRUE(value("document.querySelector('[data-slot=aui_default_permission_mode]')?.value==='default'")))
  choose("[data-slot=aui_default_permission_mode]", "acceptEdits")
  check("new-thread default callback leaves current Plan unchanged", has_log("SET_DEFAULT_MODE=acceptEdits") &&
    isTRUE(value("document.querySelector('select[aria-label=\"Permission mode\"]')?.value==='plan'")))
  click("[data-mode-vis=showYolo] input")
  check("Show YOLO ACK updates both selectors", wait_for(
    "[document.querySelector('select[aria-label=\"Permission mode\"]'),document.querySelector('[data-slot=aui_default_permission_mode]')].every(s=>[...s.options].some(o=>o.value==='yolo'))"
  ) && has_log("SET_VIS bypass=TRUE yolo=TRUE"))
  click("[data-mode-vis=showBypass] input")
  check("hidden unselected Bypass disappears from both selectors", wait_for(
    "[document.querySelector('select[aria-label=\"Permission mode\"]'),document.querySelector('[data-slot=aui_default_permission_mode]')].every(s=>![...s.options].some(o=>o.value==='bypassPermissions'))"
  ))
  choose(permission, "yolo")
  check("synthetic YOLO selection receives its own ACK", wait_for("document.querySelector('select[aria-label=\"Permission mode\"]')?.value==='yolo'") &&
    has_log("FIXTURE_ACTION=permissions:yolo"))
  click("[data-mode-vis=showYolo] input")
  check("hiding YOLO retains the current selection but filters the default", wait_for(
    "document.querySelector('select[aria-label=\"Permission mode\"]')?.value==='yolo' && ![...document.querySelector('[data-slot=aui_default_permission_mode]').options].some(o=>o.value==='yolo')"
  ))
  choose(permission, "plan")
  check("leaving hidden YOLO removes it from the current selector", wait_for(
    "document.querySelector('select[aria-label=\"Permission mode\"]')?.value==='plan' && ![...document.querySelector('select[aria-label=\"Permission mode\"]').options].some(o=>o.value==='yolo')"
  ))
  click("[data-slot=aui_run_r_toggle] input")
  check("run-R preference round-trips FALSE to the fixture", has_log("SET_RUNR=FALSE") &&
    isTRUE(value("document.querySelector('[data-slot=aui_run_r_toggle] input')?.checked===false")))
  check("edit presentation starts enabled", isTRUE(value("document.querySelector('[data-slot=aui_show_claude_edits_in_rstudio] input')?.checked===true")))
  click("[data-slot=aui_show_claude_edits_in_rstudio] input")
  Sys.sleep(0.2)
  check("edit presentation preference round-trips FALSE", has_log("SET_CLAUDE_EDITS=FALSE") &&
    isTRUE(value("document.querySelector('[data-slot=aui_show_claude_edits_in_rstudio] input')?.checked===false")))
  choose("[data-slot=aui_composer_density]", "compact")
  check("compact density is confirmed by the server", wait_for("!!document.querySelector('[data-slot=aui_composer-shell][data-density=compact]')") &&
    has_log("SET_DENSITY=compact"))
  choose("[data-slot=aui_assistant_text_size]", "small")
  check("small text preference reaches the server", has_log("SET_TEXT_SIZE=small"))
  value("document.querySelector('[data-slot=aui_settings_dialog]').focus()")
  key("Escape", "Escape", 27L)
  check("Escape closes Settings and restores trigger focus", wait_for(
    "!document.querySelector('[data-slot=aui_settings_dialog]') && document.activeElement===document.querySelector('button[aria-label=\"Settings\"]')"
  ))

  click(".aui-lexical-input[contenteditable=true]")
  browser$Input$insertText(text = "edit while RStudio presentation is disabled")
  key("Enter", "Enter", 13L)
  check("real composer produces the synthetic write and final answer", wait_for(
    "document.body.innerText.includes('TYPOGRAPHY.md') && document.body.innerText.includes('ASSISTANT BODY') && !document.querySelector('.aui-composer-cancel')"
  ))
  check(
    "disabled presentation keeps the tool without markers or auto-open",
    !has_log("PUBLISH_EDIT_MARKERS", 0) && !has_log("OPEN_EDIT=", 0)
  )
  check("small assistant prose really computes to 12px", isTRUE(font_size() == 12))
  check("reported usage replaces the unknown affordance", wait_for(
    "!!document.querySelector('[aria-label=\"Context usage\"]') && !document.querySelector('[aria-label=\"Context usage unavailable\"]')"
  ))
  point <- value("(() => {const r=document.querySelector('[aria-label=\"Context usage\"]').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()")
  browser$Input$dispatchMouseEvent(type = "mouseMoved", x = point$x, y = point$y)
  check("usage tooltip opens within the viewport", wait_for("!!document.querySelector('[data-slot=context-display-popover]')") &&
    in_viewport("[data-slot=context-display-popover]"))
  check("usage uses the reported 1200 / 200000 tokens and rounded percent", isTRUE(value(
    "(() => {const t=document.querySelector('[data-slot=context-display-popover]').textContent;return t.includes('1.2k')&&t.includes('200.0k')&&t.includes('1%')})()"
  )))
  browser$Input$dispatchMouseEvent(type = "mouseMoved", x = 900, y = 10)
  layout <- value(
    "(() => {const s=document.querySelector('[data-slot=aui_composer-shell]'),i=s.querySelector('.aui-composer-input'),a=s.querySelector('.aui-composer-action-wrapper'),sr=s.getBoundingClientRect(),ir=i.getBoundingClientRect(),ar=a.getBoundingClientRect();return {height:sr.height,width:sr.width,inputWidth:ir.width,inputBottom:ir.bottom,actionTop:ar.top,controls:['[aria-label=\"Add Attachment\"]','select[aria-label=\"Permission mode\"]','[data-slot=model-selector-trigger]','[data-slot=context-display-trigger]','.aui-composer-send'].every(q=>!!a.querySelector(q))}})()"
  )
  cat("COMPACT_LAYOUT ", jsonlite::toJSON(layout, auto_unbox = TRUE), "\n", sep = "")
  check(
    "compact input retains full width and a non-overlapping action row",
    layout$inputWidth >= layout$width - 12 && layout$actionTop >= layout$inputBottom - 1
  )
  check("compact shell retains the original <=76px limit", layout$height <= 76)
  check("attachment, permission, model, usage and send remain in the action row", layout$controls)

  click('button[aria-label="Settings"]')
  choose("[data-slot=aui_assistant_text_size]", "compact")
  check("Medium text really computes to 14px", wait_for(
    "parseFloat(getComputedStyle(document.querySelector('[data-slot=aui_assistant-text]')).fontSize)===14"
  ) && has_log("SET_TEXT_SIZE=compact"))
  choose("[data-slot=aui_assistant_text_size]", "medium")
  check("Default text really computes to 16px", wait_for(
    "parseFloat(getComputedStyle(document.querySelector('[data-slot=aui_assistant-text]')).fontSize)===16"
  ) && has_log("SET_TEXT_SIZE=medium"))
  choose("[data-slot=aui_composer_density]", "comfortable")
  check("Comfortable density restores the taller composer", wait_for(
    "!!document.querySelector('[data-slot=aui_composer-shell][data-density=comfortable]')"
  ) && value("document.querySelector('[data-slot=aui_composer-shell]').getBoundingClientRect().height") > layout$height)
  click('button[aria-label="Close settings"]')
  check("Close button dismisses Settings", wait_for("!document.querySelector('[data-slot=aui_settings_dialog]')"))
  check("synthetic history can be selected", isTRUE(value(
    "(() => {const e=[...document.querySelectorAll('button')].find(e=>e.textContent.trim()==='Settings history');if(!e)return false;e.click();return true})()"
  )))
  check("history uses the confirmed text-size setting", wait_for("document.body.innerText.includes('HISTORY BODY')") && isTRUE(font_size() == 16))

  browser$Page$reload()
  browser$Page$loadEventFired()
  check("history remains available after a real browser reload", wait_for(
    "[...document.querySelectorAll('button')].some(e=>e.textContent.trim()==='Settings history')"
  ))
  value("[...document.querySelectorAll('button')].find(e=>e.textContent.trim()==='Settings history').click()")
  check("reloaded history renders with working settings", wait_for("document.body.innerText.includes('HISTORY BODY')") && isTRUE(font_size() == 16))
  click('button[aria-label="Settings"]')
  check("reloaded Settings remains inside the viewport", in_viewport(settings))
  check("zero console errors and uncaught exceptions", length(errors) == 0L)
  check("zero network or HTTP errors", length(network_errors) == 0L)
  cat("SETTINGS_UX_DONE checks=", checks, "\n", sep = "")
}

main()
