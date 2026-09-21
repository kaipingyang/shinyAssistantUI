run_handler_protocol_verification <- function() {
  project <- normalizePath(".")
  installed <- normalizePath(find.package("shinyAssistantUI"))
  stopifnot(identical(
    installed, "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4/shinyAssistantUI"
  ))
  root <- tempfile("handler-protocol-")
  dir.create(root, mode = "0700")
  browser <- app <- NULL
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  cleanup <- make_verification_cleanup(function() browser, function() app)
  on.exit({
    cleanup()
    unlink(root, recursive = TRUE)
  }, add = TRUE)
  port <- httpuv::randomPort()
  stderr <- file.path(root, "app.err")
  app <- callr::r_bg(function(project, root, port, installed) {
    Sys.setenv(HOME = root, CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK = "1")
    options(shiny.deepstacktrace = TRUE)
    fixtures <- file.path(project, "tests/verify/fixtures")
    stopifnot(
      file.copy(file.path(fixtures, "claude_handler_stream.py"), file.path(root, "claude")),
      file.copy(file.path(fixtures, "claude_memory_stream.py"), root)
    )
    Sys.chmod(file.path(root, "claude"), "0755")
    Sys.setenv(PATH = paste(root, Sys.getenv("PATH"), sep = .Platform$path.sep))
    stopifnot(identical(unname(Sys.which("claude")), file.path(root, "claude")))
    suppressPackageStartupMessages({
      library(shiny)
      library(shinyAssistantUI)
      library(ClaudeAgentSDK)
    })
    stopifnot(identical(normalizePath(find.package("shinyAssistantUI")), installed))
    ui <- bslib::page_fluid(
      tags$head(tags$link(rel = "icon", href = "data:,")),
      assistantUIOutput("chat", height = "90vh")
    )
    server <- function(input, output, session) {
      events <- list(done = list(), errors = 0L)
      publish <- function() {
        temporary <- file.path(root, "events.tmp")
        saveRDS(events, temporary)
        stopifnot(file.rename(temporary, file.path(root, "events.rds")))
      }
      handler <- make_claude_handler(
        options = ClaudeAgentOptions(
          cwd = root, include_partial_messages = TRUE,
          permission_mode = "default", permission_prompt_tool_name = "stdio"
        ),
        session_map_path = file.path(root, "session-map.rds")
      )
      wrapped <- function(...) {
        args <- list(...)
        thread <- args$thread_id
        original_done <- args$on_done
        original_error <- args$on_error
        args$on_done <- function(...) {
          count <- events$done[[thread]]
          if (is.null(count)) count <- 0L
          events$done[[thread]] <<- count + 1L
          publish()
          original_done(...)
        }
        args$on_error <- function(message) {
          events$errors <<- events$errors + 1L
          publish()
          original_error(message)
        }
        do.call(handler, args[names(args) %in% names(formals(handler))])
      }
      attributes(wrapped) <- attributes(handler)
      api <- assistantUIServer(
        "chat", wrapped, persistence = "server", show_thread_list = TRUE,
        max_concurrent_runs = 2L,
        on_session_load = function(session_id, thread_id, send_thread, ...) {
          send_thread(list(
            list(
              id = paste0("stored-tool-", thread_id), role = "assistant",
              content = list(list(
                type = "tool-call", toolCallId = paste0("stored-tool-", thread_id),
                toolName = "Bash", args = list(command = "echo stored"),
                argsText = as.character(jsonlite::toJSON(
                  list(command = "echo stored"), auto_unbox = TRUE
                )),
                result = paste0("HISTORY_TOOL_", thread_id)
              ))
            ),
            list(
              id = paste0("stored-text-", thread_id), role = "assistant",
              content = list(list(type = "text", text = paste0("HISTORY_", thread_id)))
            )
          ))
        }
      )
      publish()
      session$onFlushed(function() {
        api$send_sessions(list(sessions = list(
          list(id = "A", title = "Alpha"),
          list(id = "B", title = "Beta")
        )))
      }, once = TRUE)
    }
    check_stop <- function() {
      if (file.exists(file.path(root, "stop"))) stopApp() else
        later::later(check_stop, 0.1)
    }
    later::later(check_stop, 0.1)
    runApp(shinyApp(ui, server), host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(project = project, root = root, port = port, installed = installed),
  stdout = file.path(root, "app.out"), stderr = stderr, supervise = TRUE,
  user_profile = FALSE, system_profile = FALSE)
  wait <- function(predicate, timeout = 15, label = "condition") {
    deadline <- Sys.time() + timeout
    repeat {
      if (!app$is_alive()) {
        cat(readLines(stderr, warn = FALSE), sep = "\n")
        stop("Handler fixture app exited")
      }
      if (isTRUE(predicate())) return(invisible(TRUE))
      if (Sys.time() > deadline) {
        cat(tail(readLines(stderr, warn = FALSE), 30L), sep = "\n")
        stop("Handler protocol timed out: ", label)
      }
      Sys.sleep(0.05)
    }
  }
  wait(function() file.exists(stderr) && any(grepl(
    "Listening on", readLines(stderr, warn = FALSE), fixed = TRUE
  )))
  chromote::set_chrome_args(unique(c(
    chromote::default_chrome_args(), "--disable-dev-shm-usage", "--no-sandbox", "--disable-gpu"
  )))
  browser <- chromote::ChromoteSession$new(width = 1100, height = 800)
  errors <- 0L
  network_errors <- 0L
  browser$Runtime$enable()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) errors <<- errors + 1L
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) errors <<- errors + 1L)
  browser$Network$loadingFailed(callback_ = function(event) {
    if (!isTRUE(event$canceled)) network_errors <<- network_errors + 1L
  })
  browser$Network$responseReceived(callback_ = function(event) {
    if (event$response$status >= 400) network_errors <<- network_errors + 1L
  })
  js <- function(code) {
    value <- browser$Runtime$evaluate(code, returnByValue = TRUE)
    if (!is.null(value$exceptionDetails)) stop("Handler browser evaluation failed")
    value$result$value
  }
  check_js <- function(label, code) {
    wait(function() isTRUE(js(code)), label = label)
    cat("[PASS] ", label, "\n", sep = "")
  }
  has <- function(text) sprintf(
    "document.body.innerText.includes(%s)", jsonlite::toJSON(text, auto_unbox = TRUE)
  )
  thread <- function(title) {
    code <- sprintf("(()=>{const row=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(x=>x.innerText.includes(%s));const b=row?.querySelector('[data-slot=aui_thread-list-item-trigger]');if(!b)return false;b.click();return true})()",
                    jsonlite::toJSON(title, auto_unbox = TRUE))
    check_js(paste("select", title), code)
  }
  send <- function(value) {
    check_js("real composer ready",
             "!!document.querySelector('[contenteditable=true]')&&!!document.querySelector('.aui-composer-send')")
    js("document.querySelector('[contenteditable=true]').focus(); true")
    browser$Input$insertText(value)
    check_js("send enabled", "!!document.querySelector('.aui-composer-send:not([disabled])')")
    browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter",
                                   windowsVirtualKeyCode = 13L)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter",
                                   windowsVirtualKeyCode = 13L)
  }
  browser$Page$navigate(paste0("http://127.0.0.1:", port))
  check_js("installed widget mounted", "!!document.querySelector('.aui-root')")
  thread("Alpha")
  check_js("history restored", has("HISTORY_A"))
  check_js("historical tool rendered", "!!document.querySelector('[data-slot=tool-fallback-trigger]')")
  js("(()=>{const b=document.querySelector('[data-slot=tool-fallback-trigger]');if(b.getAttribute('aria-expanded')!=='true')b.click();return true})()")
  check_js("historical tool result opens", has("HISTORY_TOOL_A"))

  send("APPROVAL")
  check_js("approval metadata and streamed card merge",
           "document.querySelectorAll('[data-approval-title]').length===1&&document.querySelector('[data-approval-title]').innerText==='Synthetic approval'&&document.querySelectorAll('[data-slot=tool-fallback-trigger]').length===2")
  stopifnot(!isTRUE(js(has("APPROVAL_DONE"))))
  thread("Beta")
  check_js("second history restored", has("HISTORY_B"))
  send("NORMAL")
  check_js("B completes while A waits for approval", has("NORMAL_DONE"))
  thread("Alpha")
  check_js("A approval survives thread switch",
           "[...document.querySelectorAll('button')].some(b=>b.innerText.trim()==='Approve')")
  js("[...document.querySelectorAll('button')].find(b=>b.innerText.trim()==='Approve').click(); true")
  check_js("A continues after approval", has("APPROVAL_DONE"))
  check_js("no duplicate live tool card", "document.querySelectorAll('[data-slot=tool-fallback-trigger]').length===2")

  send("CANCEL")
  check_js("A is actually streaming", has("RUNNING_"))
  thread("Beta")
  check_js("B restored without A stream", paste0(has("HISTORY_B"), "&&!", has("RUNNING_")))
  send("NORMAL")
  wait(function() identical(readRDS(file.path(root, "events.rds"))$done$B, 2L))
  thread("Alpha")
  check_js("A remains cancellable", "!!document.querySelector('.aui-composer-cancel')")
  js("document.querySelector('.aui-composer-cancel').click(); true")
  wait(function() identical(readRDS(file.path(root, "events.rds"))$done$A, 2L))
  check_js("A settles after Stop", "!!document.querySelector('.aui-composer-send')")
  send("NORMAL")
  check_js("same client/thread usable after Stop", has("NORMAL_DONE"))
  wait(function() identical(readRDS(file.path(root, "events.rds"))$done$A, 3L))
  events <- readRDS(file.path(root, "events.rds"))
  stopifnot(events$errors == 0L, events$done$A == 3L, events$done$B == 2L)

  browser$Page$reload()
  browser$Page$loadEventFired()
  check_js("reload remounts widget", "!!document.querySelector('.aui-root')")
  thread("Alpha")
  check_js("history tools restore again after reload", has("HISTORY_A"))
  check_js("reload has no stale run",
           "document.querySelectorAll('[data-run-phase=running],[data-run-phase=queued],[data-run-phase=connecting]').length===0")
  stopifnot(errors == 0L, network_errors == 0L)
  file.create(file.path(root, "stop"))
  app$wait(5000)
  stopifnot(!app$is_alive(), app$get_exit_status() == 0L)
  cleanup()
  cat("HANDLER_PROTOCOL_PASSED done_A=3 done_B=2 console=0 runtime=0 network=0 cleanup=true\n")
}

if (sys.nframe() == 0L) run_handler_protocol_verification()
