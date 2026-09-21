run_long_task_lifecycle_verification <- function() {
  project <- normalizePath(".")
  installed <- normalizePath(find.package("shinyAssistantUI"))
  sdk <- normalizePath(find.package("ClaudeAgentSDK"))
  home_library <- "/home/kaiping.yang/R/x86_64-pc-linux-gnu-library/4.4"
  stopifnot(
    identical(installed, file.path(home_library, "shinyAssistantUI")),
    identical(sdk, file.path(home_library, "ClaudeAgentSDK")),
    !identical(Sys.getenv("R_ENABLE_JIT"), "0")
  )
  mode <- Sys.getenv("AUI_LONG_TASK_MODE", "long")
  stopifnot(mode %in% c("smoke", "long", "controls"))
  seconds <- if (identical(mode, "long")) 125 else 5
  output <- Sys.getenv("AUI_LONG_TASK_OUT", "")
  if (nzchar(output)) dir.create(output, recursive = TRUE, showWarnings = FALSE)
  root <- tempfile("long-task-lifecycle-")
  dir.create(root, mode = "0700")
  browser <- app <- NULL
  source("tests/verify/owned_process_cleanup.R", local = TRUE)
  cleanup <- make_verification_cleanup(function() browser, function() app)
  on.exit({
    cleanup()
    if (nzchar(output)) {
      for (name in c("app.err", "app.out", "peer-events.jsonl", "events.rds")) {
        path <- file.path(root, name)
        if (file.exists(path)) file.copy(path, file.path(output, name), overwrite = TRUE)
      }
    }
    unlink(root, recursive = TRUE)
  }, add = TRUE)
  sessions <- setNames(
    paste0(c("11111111", "22222222", "33333333", "44444444", "55555555"),
           "-1111-4111-8111-111111111111"),
    c("Alpha", "Beta", "Gamma", "Delta", "Epsilon")
  )
  port <- httpuv::randomPort()
  stderr <- file.path(root, "app.err")
  app <- callr::r_bg(function(project, root, port, installed, sdk, sessions, seconds) {
    config <- file.path(root, "claude-config")
    Sys.setenv(
      HOME = root, CLAUDE_CONFIG_DIR = config, AUI_LONG_TASK_ROOT = root,
      AUI_LONG_TASK_SECONDS = as.character(seconds), CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK = "1"
    )
    options(shiny.deepstacktrace = TRUE, shinyAssistantUI.claude_idle_start_delay = 0)
    stopifnot(file.copy(
      file.path(project, "tests/verify/fixtures/claude_long_tasks.py"), file.path(root, "claude")
    ))
    Sys.chmod(file.path(root, "claude"), "0755")
    Sys.setenv(PATH = paste(root, Sys.getenv("PATH"), sep = .Platform$path.sep))
    stopifnot(identical(unname(Sys.which("claude")), file.path(root, "claude")))
    suppressPackageStartupMessages({
      library(shiny)
      library(shinyAssistantUI)
      library(ClaudeAgentSDK)
    })
    stopifnot(
      identical(normalizePath(find.package("shinyAssistantUI")), installed),
      identical(normalizePath(find.package("ClaudeAgentSDK")), sdk),
      is.function(ClaudeSDKClient$new()$is_alive)
    )
    transcript_directory <- file.path(config, "projects", gsub("[^a-zA-Z0-9]", "-", root))
    dir.create(transcript_directory, recursive = TRUE)
    for (title in names(sessions)) {
      sid <- sessions[[title]]
      previous <- NULL
      entry <- function(role, content, suffix) {
        id <- paste0("history-", title, "-", suffix)
        value <- list(
          type = role, uuid = id, parentUuid = previous, sessionId = sid,
          cwd = root, timestamp = "2026-09-21T00:00:00Z",
          message = list(role = role, content = content)
        )
        previous <<- id
        as.character(jsonlite::toJSON(value, auto_unbox = TRUE, null = "null"))
      }
      tool <- paste0("history-tool-", title)
      padding <- unlist(lapply(seq_len(30L), function(index) {
        c(
          entry("user", paste0("Earlier question ", index), paste0("padding-user-", index)),
          entry("assistant", list(list(
            type = "text", text = paste0("HISTORY_PADDING_", title, "_", index)
          )), paste0("padding-answer-", index))
        )
      }), use.names = FALSE)
      lines <- c(
        padding,
        entry("user", paste0("HISTORY_REQUEST_", title), "user"),
        entry("assistant", list(list(
          type = "tool_use", id = tool, name = "Read",
          input = list(file_path = "synthetic/report.txt")
        )), "tool"),
        entry("user", list(list(
          type = "tool_result", tool_use_id = tool, content = paste0("HISTORY_TOOL_", title)
        )), "result"),
        entry("assistant", list(list(type = "text", text = paste0("HISTORY_READY_", title))), "answer")
      )
      writeLines(lines, file.path(transcript_directory, paste0(sid, ".jsonl")), useBytes = TRUE)
    }
    events <- list(done = list(), errors = list(), pages = list(), history = list())
    handler <- make_claude_handler(
      options = ClaudeAgentOptions(
        cwd = root, include_partial_messages = TRUE,
        permission_mode = "default", permission_prompt_tool_name = "stdio"
      ),
      session_map_path = file.path(root, "session-map.rds")
    )
    onStop(attr(handler, "cleanup"))
    publish <- function() {
      events$snapshot <- attr(handler, "performance_snapshot")()
      temporary <- file.path(root, "events.tmp")
      saveRDS(events, temporary)
      stopifnot(file.rename(temporary, file.path(root, "events.rds")))
    }
    wrapped <- function(...) {
      args <- list(...)
      thread <- args$thread_id
      done <- args$on_done
      error <- args$on_error
      args$on_done <- function(...) {
        count <- events$done[[thread]]
        if (is.null(count)) count <- 0L
        events$done[[thread]] <<- count + 1L
        publish()
        done(...)
      }
      args$on_error <- function(message) {
        events$errors[[length(events$errors) + 1L]] <<- list(thread = thread, message = message)
        publish()
        error(message)
      }
      do.call(handler, args[names(args) %in% names(formals(handler))])
    }
    attributes(wrapped) <- attributes(handler)
    ui <- bslib::page_fluid(
      tags$head(tags$link(rel = "icon", href = "data:,")),
      assistantUIOutput("chat", height = "94vh")
    )
    server <- function(input, output, session) {
      loader <- make_claude_session_loader(file.path(root, "session-map.rds"))
      api <- assistantUIServer(
        "chat", wrapped, persistence = "server", show_thread_list = TRUE,
        max_concurrent_runs = 2L,
        action_items = if (identical(Sys.getenv("AUI_LONG_TASK_MODE"), "controls")) {
          getFromNamespace(".claude_action_items", "shinyAssistantUI")(include_export = FALSE)
        } else list(),
        on_session_load = function(session_id, thread_id, send_thread, cursor = NULL,
                                   limit = 50L, project = NULL) {
          if (!is.null(cursor)) {
            count <- events$pages[[thread_id]]
            if (is.null(count)) count <- 0L
            events$pages[[thread_id]] <<- count + 1L
            publish()
          }
          loader(session_id, thread_id, function(messages, cursor = NULL, has_more = FALSE) {
            events$history[[thread_id]] <<- list(
              count = length(messages), has_more = has_more, has_cursor = !is.null(cursor)
            )
            publish()
            send_thread(messages, cursor = cursor, has_more = has_more)
          }, cursor, limit, project)
        }
      )
      session$onFlushed(function() {
        api$send_sessions(list(sessions = lapply(names(sessions), function(title) {
          list(id = sessions[[title]], title = title, project = root)
        })))
      }, once = TRUE)
    }
    publish()
    check_stop <- function() {
      if (file.exists(file.path(root, "stop"))) stopApp() else later::later(check_stop, 0.1)
    }
    later::later(check_stop, 0.1)
    runApp(shinyApp(ui, server), host = "127.0.0.1", port = port, launch.browser = FALSE)
  }, args = list(
    project = project, root = root, port = port, installed = installed, sdk = sdk,
    sessions = sessions, seconds = seconds
  ), stdout = file.path(root, "app.out"), stderr = stderr,
  supervise = TRUE, user_profile = FALSE, system_profile = FALSE)
  wait <- function(predicate, timeout = 15, label = "condition") {
    until <- Sys.time() + timeout
    repeat {
      if (!app$is_alive()) {
        cat(readLines(stderr, warn = FALSE), sep = "\n")
        stop("Lifecycle fixture app exited")
      }
      if (isTRUE(predicate())) return(invisible(TRUE))
      if (Sys.time() >= until) {
        cat(tail(readLines(stderr, warn = FALSE), 30L), sep = "\n")
        if (file.exists(file.path(root, "events.rds"))) {
          print(readRDS(file.path(root, "events.rds"))$history)
        }
        if (!is.null(browser)) {
          state <- browser$Runtime$evaluate(
            "JSON.stringify({editors:document.querySelectorAll('[contenteditable=true]').length,send:[...document.querySelectorAll('.aui-composer-send')].map(b=>({disabled:b.disabled,text:b.innerText})),body:document.body.innerText.slice(-4000)})",
            returnByValue = TRUE
          )
          cat("\nDOM_STATE ", state$result$value, "\n", sep = "")
        }
        stop("Lifecycle verification timed out: ", label)
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
  browser <- chromote::ChromoteSession$new(width = 1200, height = 1000)
  console_errors <- runtime_errors <- network_errors <- 0L
  browser$Runtime$enable()
  browser$Network$enable()
  browser$Runtime$consoleAPICalled(callback_ = function(event) {
    if (identical(event$type, "error")) console_errors <<- console_errors + 1L
  })
  browser$Runtime$exceptionThrown(callback_ = function(event) runtime_errors <<- runtime_errors + 1L)
  browser$Network$loadingFailed(callback_ = function(event) {
    if (!isTRUE(event$canceled)) network_errors <<- network_errors + 1L
  })
  browser$Network$responseReceived(callback_ = function(event) {
    if (event$response$status >= 400) network_errors <<- network_errors + 1L
  })
  js <- function(code) {
    value <- browser$Runtime$evaluate(code, returnByValue = TRUE)
    if (!is.null(value$exceptionDetails)) stop("Lifecycle browser evaluation failed")
    value$result$value
  }
  has <- function(text) sprintf(
    "document.body.innerText.includes(%s)", jsonlite::toJSON(text, auto_unbox = TRUE)
  )
  check <- function(label, code, timeout = 15) {
    wait(function() isTRUE(js(code)), timeout = timeout, label = label)
    cat("[PASS] ", label, "\n", sep = "")
  }
  select <- function(title) {
    check(paste("select", title), sprintf(
      "(()=>{const row=[...document.querySelectorAll('[data-slot=aui_thread-list-item]')].find(x=>x.innerText.includes(%s));const button=row?.querySelector('[data-slot=aui_thread-list-item-trigger]');if(!button)return false;button.click();return true})()",
      jsonlite::toJSON(title, auto_unbox = TRUE)
    ))
    check(paste("restore canonical history", title), has(paste0("HISTORY_READY_", title)))
  }
  send <- function(text, literal_action = FALSE) {
    check("real composer ready", "!!document.querySelector('[contenteditable=true]')&&!!document.querySelector('.aui-composer-send')")
    js("document.querySelector('[contenteditable=true]').focus(); true")
    browser$Input$insertText(text)
    check("composer send enabled", "!!document.querySelector('.aui-composer-send:not([disabled])')")
    if (literal_action) {
      browser$Input$dispatchKeyEvent(type = "keyDown", key = "Escape", code = "Escape",
                                    windowsVirtualKeyCode = 27L)
      browser$Input$dispatchKeyEvent(type = "keyUp", key = "Escape", code = "Escape",
                                    windowsVirtualKeyCode = 27L)
    }
    browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter",
                                  windowsVirtualKeyCode = 13L)
    browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter",
                                  windowsVirtualKeyCode = 13L)
  }
  approve <- function(label) {
    check(paste(label, "approval remains interactive"),
          "[...document.querySelectorAll('button')].some(b=>b.innerText.trim()==='Approve'&&!b.disabled)")
    js("(()=>{const button=[...document.querySelectorAll('button')].find(b=>b.innerText.trim()==='Approve'&&!b.disabled);button.scrollIntoView({block:'center'});return true})()")
    check(paste(label, "approval is in viewport"),
          "(()=>{const b=[...document.querySelectorAll('button')].find(b=>b.innerText.trim()==='Approve'&&!b.disabled);const r=b.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight&&r.left>=0&&r.right<=innerWidth})()")
    js("[...document.querySelectorAll('button')].find(b=>b.innerText.trim()==='Approve'&&!b.disabled).click(); true")
  }
  stop_sidecar <- function(label) {
    check(paste(label, "sidecar exists"), "!!document.querySelector('[data-stop-task=sidecar]:not([disabled])')")
    js("document.querySelector('[data-stop-task=sidecar]').click(); true")
    check(paste(label, "Stop rejection permits retry"),
          "document.querySelector('[data-stop-task=sidecar]')?.innerText==='Retry Stop'&&!!document.querySelector('[data-task-stop-error]')")
    js("document.querySelector('[data-stop-task=sidecar]').click(); true")
    check(paste(label, "terminal task event resolves Stop"),
          "!document.querySelector('[data-task-active=true][data-task-id=sidecar]')&&document.body.innerText.includes('Task is stopped')")
  }
  browser$Page$navigate(paste0("http://127.0.0.1:", port))
  check("installed widget mounted", "!!document.querySelector('.aui-root')")
  select("Alpha")
  check("historical tool card exists", "!!document.querySelector('[data-slot=tool-fallback-trigger]')")
  js("document.querySelector('[data-slot=tool-fallback-trigger]').click(); true")
  check("historical file_path arguments and tool result render", has("HISTORY_TOOL_Alpha"))
  if (identical(mode, "controls")) {
    send("NORMAL")
    check("SDK foreground establishes an active session", has("NORMAL_DONE"))
    wait(function() identical(readRDS(file.path(root, "events.rds"))$done[[sessions[["Alpha"]]]], 1L))
    pick_model <- function(model) {
      js("document.querySelector('[data-slot=model-selector-trigger]').click(); true")
      check("SDK-backed model picker stays within viewport",
            "(()=>{const e=document.querySelector('[data-slot=model-selector-content]');if(!e)return false;const r=e.getBoundingClientRect();return r.width>0&&r.top>=0&&r.left>=0&&r.right<=innerWidth&&r.bottom<=innerHeight})()")
      js(sprintf("document.querySelector('[data-slot=model-selector-item][data-value=%s]').click(); true",
                 model))
    }
    pick_model("opus")
    check("model selection waits for the SDK ACK",
          "document.querySelector('[data-slot=aui_model_control]')?.dataset.pending==='true'&&!document.querySelector('[data-slot=model-selector-value]')?.textContent.includes('Opus')")
    check("model ACK applies Opus",
          "document.querySelector('[data-slot=aui_model_control]')?.dataset.pending==='false'&&document.querySelector('[data-slot=model-selector-value]')?.textContent.includes('Opus')")
    pick_model("haiku")
    check("rejected SDK model keeps the last confirmed selection",
          "document.querySelector('[data-slot=aui_model_error]')?.title.includes('Synthetic model rejection')&&document.querySelector('[data-slot=model-selector-value]')?.textContent.includes('Opus')")
    pick_model("sonnet")
    check("a later model ACK clears the error and applies Sonnet",
          "!document.querySelector('[data-slot=aui_model_error]')&&document.querySelector('[data-slot=model-selector-value]')?.textContent.includes('Sonnet')")
    js("(()=>{const e=document.querySelector('select[aria-label=\"Permission mode\"]');e.value='plan';e.dispatchEvent(new Event('change',{bubbles:true}));return true})()")
    check("permission downgrade is acknowledged by the SDK",
          "document.querySelector('select[aria-label=\"Permission mode\"]')?.value==='plan'&&!document.querySelector('select[aria-label=\"Permission mode\"]')?.disabled")
    send("/context", literal_action = TRUE)
    check("context action renders reported tokens and categories",
          "document.body.innerText.includes('1.2k / 200k')&&[...document.querySelectorAll('table')].some(t=>t.innerText.includes('Synthetic instructions')&&t.innerText.includes('Synthetic messages'))")
    js("window.__compactResults=[];$(document).on('shiny:message.compactProtocol',event=>{for(const [name,value] of Object.entries(event.message?.custom||{})){if(name.endsWith(':action-result')&&value.actionId==='compact')window.__compactResults.push(value)}});true")
    send("/compact", literal_action = TRUE)
    check("compact shows structured running progress",
          "!!document.querySelector('[data-slot=action-progress][data-action-kind=compact][data-action-state=running]')")
    check("compact reports elapsed time with an indeterminate bar",
          "(()=>{const e=document.querySelector('[data-slot=action-progress][data-action-kind=compact]');return !!e.querySelector('[data-indeterminate=true]')&&/\\d+s elapsed/.test(e.innerText)&&!/\\d+%/.test(e.innerText)})()")
    check("compact blocks only composer submission, not an AI Stop button",
          "document.querySelector('[data-slot=aui_composer-shell]')?.dataset.blocked==='true'&&document.querySelector('.aui-lexical-input')?.getAttribute('contenteditable')==='false'&&!!document.querySelector('.aui-composer-compact-blocked')&&!document.querySelector('.aui-composer-cancel')")
    check("compact success reaches the browser over the real bridge",
          "window.__compactResults.some(value=>value.status==='ok'&&value.value?.phase==='complete')")
    cat("COMPACT_ACTION_RESULTS ", js("JSON.stringify(window.__compactResults)"), "\n", sep = "")
    check("compact receives a successful terminal ACK",
          "!!document.querySelector('[data-slot=action-progress][data-action-state=complete]')&&document.body.innerText.includes('Conversation compacted')")
    check("compact restores composer and stops progress animation",
          "document.querySelector('.aui-lexical-input')?.getAttribute('contenteditable')==='true'&&!document.querySelector('[data-slot=action-progress] [data-indeterminate=true]')")
    check("canonical compact summary renders as assistant, never user",
          "[...document.querySelectorAll('[data-slot=aui_assistant-message-root]')].some(e=>e.innerText.includes('SYNTHETIC_COMPACT_SUMMARY'))&&![...document.querySelectorAll('.aui-user-message-content')].some(e=>e.innerText.includes('SYNTHETIC_COMPACT_SUMMARY'))")
    send("NORMAL")
    wait(function() identical(readRDS(file.path(root, "events.rds"))$done[[sessions[["Alpha"]]]], 2L),
         label = "foreground after compact")
    check("conversation remains usable after compaction", has("NORMAL_DONE"))
    browser$Page$reload()
    browser$Page$loadEventFired()
    check("controls widget remounts", "!!document.querySelector('.aui-root')")
    select("Alpha")
    check("compact summary survives a real history reload",
          "[...document.querySelectorAll('[data-slot=aui_assistant-message-root]')].some(e=>e.innerText.includes('SYNTHETIC_COMPACT_SUMMARY'))&&![...document.querySelectorAll('.aui-user-message-content')].some(e=>e.innerText.includes('SYNTHETIC_COMPACT_SUMMARY'))")
    observations <- lapply(readLines(file.path(root, "peer-events.jsonl"), warn = FALSE),
                           jsonlite::fromJSON)
    kinds <- vapply(observations, `[[`, "", "kind")
    stopifnot(
      sum(kinds == "model_applied") == 2L, sum(kinds == "model_rejected") == 1L,
      sum(kinds == "permission_applied") == 1L,
      sum(kinds == "compact_started") == 1L, sum(kinds == "compact_completed") == 1L,
      !any(kinds == "interrupt"),
      length(readRDS(file.path(root, "events.rds"))$errors) == 0L,
      console_errors == 0L, runtime_errors == 0L, network_errors == 0L
    )
    file.create(file.path(root, "stop"))
    app$wait(5000)
    stopifnot(!app$is_alive(), app$get_exit_status() == 0L)
    cleanup()
    cat("CLAUDE_CONTROLS_PROTOCOL_PASSED console=0 runtime=0 network=0 cleanup=true\n")
    return(invisible(NULL))
  }
  send("LONG_BACKGROUND")
  check("top-level background turn opens after foreground completion", has("BACKGROUND_LONG_STARTED"))
  check("background Task remains active", "!!document.querySelector('[data-task-active=true][data-task-id=background-long]')")

  select("Beta")
  check("history fixture exposes its older page", "!!document.querySelector('[data-slot=aui_load_older]')")
  send("LONG_APPROVAL")
  check("foreground approval opens", has("Long foreground approval"))
  foreground_opened <- Sys.time()
  check("active foreground can request older history",
        "!!document.querySelector('[data-slot=aui_load_older]:not([disabled])')")
  check("history pagination is clicked in the viewport",
        "(()=>{const b=document.querySelector('[data-slot=aui_load_older]');if(!b)return false;b.scrollIntoView({block:'center',behavior:'instant'});const r=b.getBoundingClientRect();if(!(r.height>0&&r.top>=0&&r.bottom<=innerHeight))return false;b.click();return true})()")
  wait(function() {
    value <- readRDS(file.path(root, "events.rds"))$pages[[sessions[["Beta"]]]]
    !is.null(value) && value >= 1L
  }, label = "history page requested during live approval")
  check("history paging preserves the live approval", has("Long foreground approval"))
  stop_sidecar("foreground approval")

  select("Delta")
  send("IDLE_APPROVAL")
  check("background turn is armed before approval exists", has("BACKGROUND_APPROVAL_ARMED"))
  wait(function() {
    value <- readRDS(file.path(root, "events.rds"))$done[[sessions[["Delta"]]]]
    !is.null(value) && value >= 1L
  }, label = "background foreground settled")
  select("Gamma")
  select("Delta")
  file.create(file.path(root, paste0("release-permission-", sessions[["Delta"]])))
  check("associated background approval opens after done", has("Long background approval"))
  background_opened <- Sys.time()
  stop_sidecar("background approval")

  select("Gamma")
  send("PARENTED_ONLY")
  check("parented task started", "!!document.querySelector('[data-task-active=true][data-task-id=parented-child]')")
  check("parented Task ends without a top-level Result",
        "!document.querySelector('[data-task-active=true][data-task-id=parented-child]')")
  send("NORMAL")
  check("next foreground is not blocked by a parented-only turn", has("NORMAL_DONE"), timeout = 5)
  stopifnot(!isTRUE(js(has("CHILD_PRIVATE_TEXT"))))
  send("ERROR_RECOVERY")
  check("foreground error is visible", has("Synthetic upstream failure"))
  check("reply written three seconds after the error is recovered", has("RECOVERED_AFTER_ERROR"))
  stopifnot(isTRUE(js(has("Synthetic upstream failure"))))
  send("EXIT_RECOVERY")
  check("EOF is reported rather than leaving the run waiting", has("exited"))
  check("canonical reply before EOF survives connection failure", has("RECOVERED_AFTER_EXIT"))
  send("NORMAL")
  wait(function() {
    value <- readRDS(file.path(root, "events.rds"))$done[[sessions[["Gamma"]]]]
    !is.null(value) && value >= 3L
  }, label = "reconnected foreground")

  select("Alpha")
  send("AFTER_BACKGROUND")
  if (identical(mode, "long")) {
    Sys.sleep(0.5)
    stopifnot(!isTRUE(js(has("AFTER_BACKGROUND_DONE"))))
  }
  check("queued foreground follows the confirmed long background Result",
        has("AFTER_BACKGROUND_DONE"), timeout = seconds + 15)
  check("long background answer remains visible", has("BACKGROUND_COMPLETED_125S"))

  wait(function() as.numeric(Sys.time() - background_opened, units = "secs") >= seconds,
       timeout = seconds + 5, label = "real long approval duration")
  select("Beta")
  stopifnot(as.numeric(Sys.time() - foreground_opened, units = "secs") >= seconds)
  approve("foreground")
  check("foreground approval continues after the long wait", has("APPROVAL_COMPLETED"))
  select("Delta")
  approve("background")
  check("background approval continues after the long wait", has("BACKGROUND_APPROVAL_COMPLETED"))
  send("NORMAL")
  wait(function() {
    value <- readRDS(file.path(root, "events.rds"))$done[[sessions[["Delta"]]]]
    !is.null(value) && value >= 2L
  }, label = "foreground after background approval")

  select("Epsilon")
  send("HISTORY_APPROVAL")
  check("later approval is armed before browser reload", has("BACKGROUND_APPROVAL_ARMED"))
  wait(function() {
    value <- readRDS(file.path(root, "events.rds"))$done[[sessions[["Epsilon"]]]]
    !is.null(value) && value >= 1L
  }, label = "foreground settled before browser reload")
  browser$Page$reload()
  browser$Page$loadEventFired()
  check("widget remounts", "!!document.querySelector('.aui-root')")
  select("Epsilon")
  file.create(file.path(root, paste0("release-permission-", sessions[["Epsilon"]])))
  check("fresh browser receives approval without starting a new foreground run",
        has("Long background approval"))
  approve("cold history")
  check("fresh browser receives the approved background reply",
        has("BACKGROUND_APPROVAL_COMPLETED"))
  select("Gamma")
  check("history restore retains the recovered error answer", has("RECOVERED_AFTER_ERROR"))
  check("history restore retains the EOF answer", has("RECOVERED_AFTER_EXIT"))
  check("history restore has no stale run",
        "document.querySelectorAll('[data-run-phase=running],[data-run-phase=queued],[data-run-phase=connecting]').length===0")
  observations <- lapply(readLines(file.path(root, "peer-events.jsonl"), warn = FALSE),
                         jsonlite::fromJSON)
  kinds <- vapply(observations, `[[`, "", "kind")
  background <- observations[kinds == "background_completed"]
  approvals <- observations[kinds == "permission_decided"]
  cold_approvals <- Filter(function(value) identical(value$session, sessions[["Epsilon"]]), approvals)
  long_approvals <- Filter(function(value) !identical(value$session, sessions[["Epsilon"]]), approvals)
  stopifnot(
    length(background) == 1L, background[[1L]]$seconds >= seconds,
    length(long_approvals) == 2L, length(cold_approvals) == 1L,
    all(vapply(long_approvals, function(value) value$seconds >= seconds && value$allowed, logical(1))),
    isTRUE(cold_approvals[[1L]]$allowed),
    sum(kinds == "stop_rejected") == 2L, sum(kinds == "stop_confirmed") == 2L,
    !any(kinds == "interrupt"),
    console_errors == 0L, runtime_errors == 0L, network_errors == 0L
  )
  report <- list(
    mode = mode, package = as.character(packageVersion("shinyAssistantUI")),
    sdk = as.character(packageVersion("ClaudeAgentSDK")),
    background_seconds = background[[1L]]$seconds,
    approval_seconds = vapply(long_approvals, `[[`, numeric(1), "seconds"),
    cold_history_approval = isTRUE(cold_approvals[[1L]]$allowed),
    console_errors = console_errors, runtime_errors = runtime_errors, network_errors = network_errors,
    events = readRDS(file.path(root, "events.rds"))
  )
  if (nzchar(output)) saveRDS(report, file.path(output, "lifecycle-report.rds"))
  file.create(file.path(root, "stop"))
  app$wait(5000)
  stopifnot(!app$is_alive(), app$get_exit_status() == 0L)
  cleanup()
  cat("LONG_TASK_LIFECYCLE_", toupper(mode),
      "_PASSED console=0 runtime=0 network=0 cleanup=true\n", sep = "")
}

if (sys.nframe() == 0L) run_long_task_lifecycle_verification()
