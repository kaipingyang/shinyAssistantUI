# Run with the bounded runner's browser mode; each UI arm owns one Chromium.
# A local deterministic CLI peer replaces the model, not the real R SDK.
# Example: AUI_MEMORY_ARMS=shinychat,plugin AUI_MEMORY_EVENTS=1200 \
#   node .kiro/skills/shinyassistantui-verify/scripts/run-verification-bounded.mjs \
#   browser --files tests/verify/compare_sdk_memory.R --timeout 240
# AUI_MEMORY_DEEPSTACK=0 and R_ENABLE_JIT=0 are diagnostic controls, not fixes.

memory_chunk <- function(index) {
  sprintf("MEMORY_%06d_%s\n", index, strrep("x", 48L))
}

memory_proc <- function(pid = Sys.getpid()) {
  path <- sprintf("/proc/%d/smaps_rollup", pid)
  if (!file.exists(path)) stop("Subject disappeared before its memory sample")
  lines <- readLines(path, warn = FALSE)
  field <- function(name) {
    line <- grep(paste0("^", name, ":"), lines, value = TRUE)
    if (length(line) != 1L) stop("Missing /proc metric: ", name)
    as.numeric(sub("^[^:]+:[[:space:]]*([0-9]+).*$", "\\1", line)) * 1024
  }
  c(rss = field("Rss"), pss = field("Pss"),
    private_dirty = field("Private_Dirty"), anonymous = field("Anonymous"))
}

memory_write <- function(value, path) {
  temporary <- paste0(path, ".tmp")
  saveRDS(value, temporary)
  if (!file.rename(temporary, path)) stop("Could not publish benchmark state")
}

memory_check_headroom <- function() {
  root <- "/sys/fs/cgroup"
  current <- as.numeric(readLines(file.path(root, "memory.current"), n = 1L))
  limit <- readLines(file.path(root, "memory.max"), n = 1L)
  if (identical(limit, "max")) return(invisible(TRUE))
  limit <- as.numeric(limit)
  if (!is.finite(current) || !is.finite(limit)) stop("Cgroup memory metrics unavailable")
  if (limit - current < 512 * 1024^2) stop("Insufficient cgroup memory headroom")
  invisible(TRUE)
}

memory_subject <- function(project, root, arm, events, interval, profile,
                           port, identities, deep_stack, quiet_seconds,
                           usage_delay_seconds, post_done_seconds) {
  options(shiny.deepstacktrace = deep_stack)
  Sys.setenv(
    CLAUDE_AGENT_SDK_SKIP_VERSION_CHECK = "1",
    AUI_MEMORY_EVENTS = as.character(events),
    AUI_MEMORY_INTERVAL = as.character(interval),
    AUI_MEMORY_QUIET_SECONDS = as.character(quiet_seconds),
    AUI_MEMORY_USAGE_DELAY_SECONDS = as.character(usage_delay_seconds),
    HOME = root
  )
  for (pkg in names(identities)) {
    stopifnot(identical(normalizePath(find.package(pkg)), identities[[pkg]]))
  }
  suppressPackageStartupMessages(library(ClaudeAgentSDK))
  cli <- file.path(root, "claude")
  stopifnot(file.copy(
    file.path(project, "tests/verify/fixtures/claude_memory_stream.py"), cli
  ))
  Sys.chmod(cli, "0755")
  Sys.setenv(PATH = paste(root, Sys.getenv("PATH"), sep = .Platform$path.sep))
  stopifnot(identical(unname(Sys.which("claude")), cli))
  opts <- ClaudeAgentOptions(
    cli_path = cli, cwd = root, include_partial_messages = TRUE,
    permission_mode = "default"
  )
  state <- new.env(parent = emptyenv())
  state$chunks <- 0L
  state$done <- 0L
  state$semantic_ok <- TRUE
  state$first <- NA_real_
  state$started <- NA_real_
  state$finished <- FALSE
  state$client <- NULL
  state$handler <- NULL
  state$diagnostics <- NULL
  state$phases <- list()
  state$usage_updates <- 0L
  state$context_updates <- 0L
  state$terminal_snapshot <- NULL
  state$terminal_elapsed <- NA_real_
  elapsed <- function() unname(proc.time()[["elapsed"]])
  record_chunk <- function(text) {
    state$chunks <- state$chunks + 1L
    if (is.na(state$first)) state$first <- elapsed()
    state$semantic_ok <- state$semantic_ok &&
      identical(text, memory_chunk(state$chunks))
    invisible(NULL)
  }
  fail <- function(error) {
    text <- if (inherits(error, "condition")) conditionMessage(error) else as.character(error)
    writeLines(text, file.path(root, "failure"))
    stop(text, call. = FALSE)
  }
  begin <- function() {
    stopifnot(is.na(state$started))
    invisible(gc(full = TRUE))
    state$baseline <- memory_proc()
    memory_write(state$baseline, file.path(root, "baseline.rds"))
    if (profile) {
      utils::Rprofmem(file.path(root, "alloc.out"), threshold = 1024)
      utils::Rprof(file.path(root, "cpu.out"), interval = 0.005)
    }
    state$started <- elapsed()
  }
  finish <- function() {
    if (state$finished) return(invisible(NULL))
    state$finished <- TRUE
    if (profile) {
      utils::Rprofmem(NULL)
      utils::Rprof(NULL)
    }
    duration <- state$terminal_elapsed
    stopifnot(state$done == 1L, state$chunks == events, state$semantic_ok)
    before <- memory_proc()
    heap <- gc(full = TRUE)
    after <- memory_proc()
    snapshots <- NULL
    if (!is.null(state$handler)) {
      snapshot <- attr(state$handler, "performance_snapshot")
      if (is.function(snapshot)) snapshots <- snapshot()
    }
    memory_write(list(
      baseline = state$baseline, pre_gc = before, post_gc = after,
      gc = heap,
      heap_used_bytes = sum(heap[, 2L]) * 1024^2,
      heap_trigger_bytes = sum(heap[, 4L]) * 1024^2,
      chunks = state$chunks, done = state$done, semantic_ok = state$semantic_ok,
      first_chunk_seconds = state$first - state$started,
      duration_seconds = duration, handler_snapshot = snapshots,
      observation_seconds = elapsed() - state$started,
      terminal_snapshot = state$terminal_snapshot,
      usage_updates = state$usage_updates, context_updates = state$context_updates,
      phases = state$phases,
      jit_environment = Sys.getenv("R_ENABLE_JIT", unset = "default")
    ), file.path(root, "result.rds"))
    invisible(NULL)
  }
  observe_completion <- function() {
    state$terminal_elapsed <- elapsed() - state$started
    if (!is.null(state$handler)) {
      state$terminal_snapshot <- attr(state$handler, "performance_snapshot")()
    }
    if (post_done_seconds > 0) {
      later::later(finish, post_done_seconds)
    } else {
      finish()
    }
    invisible(NULL)
  }
  new_handler <- function() {
    handler <- shinyAssistantUI::make_claude_handler(
      options = opts, session_map_path = file.path(root, "session-map.rds"),
      memory_guard_config = list(enabled = TRUE)
    )
    state$handler <- handler
    wrapped <- function(...) {
      args <- list(...)
      original_chunk <- args$on_chunk
      original_done <- args$on_done
      original_phase <- args$on_run_phase
      original_usage <- args$on_usage
      args$on_chunk <- function(text) {
        record_chunk(text)
        original_chunk(text)
      }
      args$on_done <- function(...) {
        state$done <- state$done + 1L
        original_done(...)
      }
      args$on_error <- fail
      if (is.function(original_usage)) {
        args$on_usage <- function(...) {
          usage <- list(...)
          state$usage_updates <- state$usage_updates + 1L
          if (!is.null(usage$context_tokens)) {
            state$context_updates <- state$context_updates + 1L
          }
          original_usage(...)
        }
      }
      args$on_run_phase <- function(phase, ...) {
        state$phases[[length(state$phases) + 1L]] <- list(
          phase = phase, seconds = elapsed() - state$started
        )
        if (is.function(original_phase)) original_phase(phase, ...)
      }
      begin()
      result <- do.call(handler, args[names(args) %in% names(formals(handler))])
      promises::then(result, function(value) {
        later::later(observe_completion, 0.2)
        value
      }, fail)
    }
    attributes(wrapped) <- attributes(handler)
    wrapped
  }
  poll_sdk <- function(on_chunk, on_done) {
    state$client <- ClaudeSDKClient$new(opts)
    state$client$connect()
    state$client$send("Run the deterministic local memory fixture.")
    tick <- NULL
    tick <- function() {
      batch <- state$client$poll_messages()
      for (message in batch) {
        if (inherits(message, "StreamEvent")) {
          delta <- message$event$delta
          if (identical(delta$type, "text_delta")) {
            record_chunk(delta$text)
            on_chunk(delta$text)
          }
        } else if (inherits(message, "ResultMessage")) {
          if (isTRUE(message$is_error)) fail("Fixture returned an error")
          state$done <- state$done + 1L
          on_done()
          later::later(observe_completion, 0.2)
          return(invisible(NULL))
        }
      }
      later::later(tick, 0.01)
    }
    later::later(tick, 0)
  }
  on.exit({
    if (profile) {
      utils::Rprofmem(NULL)
      utils::Rprof(NULL)
    }
    if (!is.null(state$client)) state$client$disconnect()
    if (!is.null(state$handler)) attr(state$handler, "cleanup")()
    if (!is.null(state$diagnostics)) state$diagnostics$close()
  }, add = TRUE)

  if (arm %in% c("sdk", "handler")) {
    if (arm == "handler") {
      suppressPackageStartupMessages(library(shinyAssistantUI))
      handler <- new_handler()
    }
    file.create(file.path(root, "ready"))
    while (!file.exists(file.path(root, "go"))) Sys.sleep(0.01)
    if (arm == "sdk") {
      begin()
      poll_sdk(function(text) NULL, function() NULL)
    } else {
      state$promise <- handler(
        message = "Run the deterministic local memory fixture.",
        thread_id = "fixture-thread", attachments = list(),
        on_chunk = function(text) NULL, on_done = function() NULL,
        on_error = fail, on_tool_call = function(...) NULL,
        on_tool_result = function(...) NULL, on_thinking = function(...) NULL,
        is_cancelled = function() FALSE,
        wait_for_approval = function(...) stop("Unexpected fixture approval")
      )
    }
    while (!file.exists(file.path(root, "stop"))) later::run_now(0.05)
    return(invisible(NULL))
  }

  suppressPackageStartupMessages(library(shiny))
  history <- list(
    list(id = "history-user", role = "user",
         content = list(list(type = "text", text = "Synthetic prior question"))),
    list(id = "history-assistant", role = "assistant",
         content = list(list(type = "text", text = "HISTORY_MEMORY_SENTINEL")))
  )
  if (startsWith(arm, "shinychat")) {
    content <- shinychat::chat_ui("chat", messages = lapply(history, function(x) {
      list(role = x$role, content = x$content[[1L]]$text)
    }), enable_cancel = FALSE)
  } else {
    suppressPackageStartupMessages(library(shinyAssistantUI))
    content <- assistantUIOutput("chat", height = "90vh")
  }
  ui <- bslib::page_fluid(
    tags$head(tags$link(rel = "icon", href = "data:,")),
    content
  )
  server <- function(input, output, session) {
    if (startsWith(arm, "shinychat")) {
      handler <- if (arm == "shinychat-handler") new_handler() else NULL
      observeEvent(input$chat_user_input, {
        shinychat::chat_append_message(
          "chat", list(role = "assistant", content = ""), chunk = "start",
          session = session
        )
        append <- function(text) {
          shinychat::chat_append_message(
            "chat", list(role = "assistant", content = text), session = session
          )
        }
        done <- function() {
          shinychat::chat_append_message(
            "chat", list(role = "assistant", content = ""), chunk = "end",
            session = session
          )
        }
        if (is.null(handler)) {
          begin()
          poll_sdk(append, done)
        } else {
          state$promise <- handler(
            message = "Run the deterministic local memory fixture.",
            thread_id = "fixture-thread", attachments = list(),
            on_chunk = append, on_done = done, on_error = fail,
            on_tool_call = function(...) NULL, on_tool_result = function(...) NULL,
            on_thinking = function(...) NULL, is_cancelled = function() FALSE,
            wait_for_approval = function(...) stop("Unexpected fixture approval")
          )
        }
      }, ignoreInit = TRUE)
    } else {
      handler <- if (arm == "plugin-thin") {
        function(message, on_chunk, on_done, ...) {
          begin()
          promises::promise(function(resolve, reject) {
            poll_sdk(on_chunk, function() {
              on_done()
              resolve(NULL)
            })
          })
        }
      } else {
        new_handler()
      }
      if (arm == "plugin-diagnostics") {
        state$diagnostics <- shinyAssistantUI:::.new_diagnostics_service(list(
          enabled = TRUE, directory = file.path(root, "diagnostics")
        ))
        stopifnot(identical(state$diagnostics$snapshot()$state, "started"))
        attr(handler, "diagnostics_service") <- state$diagnostics
      }
      api <- assistantUIServer(
        "chat", handler, persistence = "none", show_thread_list = TRUE,
        on_session_load = function(session_id, thread_id, send_thread, ...) {
          send_thread(history)
        },
        diagnostics = if (arm == "plugin-diagnostics") TRUE else NULL
      )
      session$onFlushed(function() {
        api$send_sessions(list(sessions = list(list(
          id = "memory-history", title = "Memory fixture history"
        ))))
      }, once = TRUE)
    }
    session$onFlushed(function() file.create(file.path(root, "ready")), once = TRUE)
  }
  check_stop <- function() {
    if (file.exists(file.path(root, "stop"))) stopApp() else
      later::later(check_stop, 0.1)
  }
  later::later(check_stop, 0.1)
  runApp(shinyApp(ui, server), host = "127.0.0.1", port = port, launch.browser = FALSE)
}

run_sdk_memory_comparison <- function(
    arms = c("sdk", "handler", "shinychat", "plugin"),
    events = 1200L, interval = 0.001, profile = FALSE,
    output = tempfile("sdk-memory-comparison-"), timeout = 90,
    deep_stack = TRUE, pss_limit_bytes = 2 * 1024^3,
    quiet_seconds = 0, usage_delay_seconds = 0, post_done_seconds = 0) {
  stopifnot(
    length(events) == 1L, events >= 1L, events <= 20000L,
    is.finite(timeout), timeout > 0,
    is.finite(pss_limit_bytes), pss_limit_bytes > 0,
    length(quiet_seconds) == 1L, is.finite(quiet_seconds),
    quiet_seconds >= 0, quiet_seconds <= 120,
    length(usage_delay_seconds) == 1L, !is.na(usage_delay_seconds),
    usage_delay_seconds >= 0,
    is.infinite(usage_delay_seconds) || usage_delay_seconds <= 40,
    length(post_done_seconds) == 1L, is.finite(post_done_seconds),
    post_done_seconds >= 0, post_done_seconds <= 40,
    all(arms %in% c("sdk", "handler", "shinychat", "shinychat-handler",
                   "plugin", "plugin-thin", "plugin-diagnostics"))
  )
  project <- normalizePath(".")
  script <- file.path(project, "tests/verify/compare_sdk_memory.R")
  cli <- file.path(project, "tests/verify/fixtures/claude_memory_stream.py")
  Sys.chmod(cli, "0755")
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  identities <- setNames(lapply(
    c("ClaudeAgentSDK", "shinyAssistantUI", "shinychat"),
    function(pkg) normalizePath(find.package(pkg))
  ), c("ClaudeAgentSDK", "shinyAssistantUI", "shinychat"))
  saveRDS(identities, file.path(output, "installed-identities.rds"))
  function_hash <- function(fn) {
    path <- tempfile("sdk-function-")
    on.exit(unlink(path), add = TRUE)
    writeLines(deparse(body(fn)), path)
    unname(tools::md5sum(path))
  }
  saveRDS(list(
    versions = lapply(names(identities), function(pkg) as.character(packageVersion(pkg))),
    sdk_transport = function_hash(get("SubprocessCLITransport",
                                     asNamespace("ClaudeAgentSDK"))$public_methods$read_available_messages),
    handler_factory = function_hash(shinyAssistantUI::make_claude_handler),
    foreground_pump = function_hash(shinyAssistantUI:::.claude_foreground_pump)
  ), file.path(output, "implementation-fingerprints.rds"))
  source(file.path(project, "tests/verify/owned_process_cleanup.R"), local = TRUE)
  run_arm <- function(arm) {
    memory_check_headroom()
    root <- tempfile(paste0("aui-memory-", arm, "-"))
    dir.create(root, mode = "0700")
    subject <- browser <- NULL
    cleanup <- make_verification_cleanup(function() browser, function() subject)
    on.exit({
      cleanup()
      unlink(root, recursive = TRUE)
    }, add = TRUE)
    out <- file.path(root, "subject.out")
    err <- file.path(root, "subject.err")
    port <- httpuv::randomPort()
    subject <- callr::r_bg(function(script, args) {
      scope <- new.env(parent = globalenv())
      sys.source(script, scope)
      do.call(scope$memory_subject, args)
    }, args = list(script = script, args = list(
      project = project, root = root, arm = arm, events = as.integer(events),
      interval = interval, profile = profile, port = port, identities = identities,
      deep_stack = deep_stack, quiet_seconds = quiet_seconds,
      usage_delay_seconds = usage_delay_seconds, post_done_seconds = post_done_seconds
    )), stdout = out, stderr = err, supervise = TRUE,
    user_profile = FALSE, system_profile = FALSE)
    deadline <- Sys.time() + timeout
    console_errors <- 0L
    network_errors <- 0L
    samples <- list()
    check_subject <- function() {
      memory_check_headroom()
      failure <- file.path(root, "failure")
      if (!subject$is_alive() || file.exists(failure) || Sys.time() > deadline) {
        cat(paste(readLines(err, warn = FALSE), collapse = "\n"), "\n")
        stop("Comparison subject failed or timed out: ", arm)
      }
    }
    wait_until <- function(predicate) {
      repeat {
        check_subject()
        if (isTRUE(predicate())) return(invisible(TRUE))
        Sys.sleep(0.05)
      }
    }
    if (arm %in% c("sdk", "handler")) {
      wait_until(function() file.exists(file.path(root, "ready")))
      file.create(file.path(root, "go"))
    } else {
      wait_until(function() any(grepl(
        "Listening on", readLines(err, warn = FALSE), fixed = TRUE
      )))
      chromote::set_chrome_args(unique(c(
        chromote::default_chrome_args(), "--disable-dev-shm-usage",
        "--no-sandbox", "--disable-gpu"
      )))
      browser <- chromote::ChromoteSession$new(width = 1100, height = 800)
      browser$Runtime$enable()
      browser$Network$enable()
      browser$Runtime$consoleAPICalled(callback_ = function(event) {
        if (identical(event$type, "error")) console_errors <<- console_errors + 1L
      })
      browser$Runtime$exceptionThrown(callback_ = function(event) {
        console_errors <<- console_errors + 1L
      })
      browser$Network$loadingFailed(callback_ = function(event) {
        if (!isTRUE(event$canceled)) network_errors <<- network_errors + 1L
      })
      browser$Network$responseReceived(callback_ = function(event) {
        if (event$response$status >= 400) network_errors <<- network_errors + 1L
      })
      js <- function(code) {
        value <- browser$Runtime$evaluate(code, returnByValue = TRUE)
        if (!is.null(value$exceptionDetails)) stop("Browser evaluation failed")
        value$result$value
      }
      browser$Page$navigate(paste0("http://127.0.0.1:", port))
      wait_until(function() file.exists(file.path(root, "ready")))
      js("window.memoryDeepText=function(root=document.body){let s='';for(const n of root.childNodes){if(n.nodeType===3)s+=n.textContent;else if(n.nodeType===1&&!['SCRIPT','STYLE'].includes(n.tagName)){s+=memoryDeepText(n);if(n.shadowRoot)s+=memoryDeepText(n.shadowRoot)}}return s;}; true")
      if (!startsWith(arm, "shinychat")) {
        wait_until(function() isTRUE(js("Array.from(document.querySelectorAll('button')).some(e=>e.textContent.includes('Memory fixture history'))")))
        js("Array.from(document.querySelectorAll('button')).find(e=>e.textContent.includes('Memory fixture history')).click(); true")
      }
      wait_until(function() isTRUE(js("memoryDeepText().includes('HISTORY_MEMORY_SENTINEL')")))
      wait_until(function() isTRUE(js("(function find(root){for(const e of root.querySelectorAll('textarea,[contenteditable=\"true\"]')){if(e.getBoundingClientRect().height>0&&!e.disabled){e.focus();return true}}for(const e of root.querySelectorAll('*'))if(e.shadowRoot&&find(e.shadowRoot))return true;return false})(document)")))
      browser$Input$insertText("Run the deterministic local memory fixture.")
      browser$Input$dispatchKeyEvent(type = "keyDown", key = "Enter", code = "Enter",
                                     windowsVirtualKeyCode = 13L)
      browser$Input$dispatchKeyEvent(type = "keyUp", key = "Enter", code = "Enter",
                                     windowsVirtualKeyCode = 13L)
    }
    wait_until(function() {
      sample <- memory_proc(subject$get_pid())
      if (sample[["pss"]] > pss_limit_bytes) stop("Subject reached its PSS safety limit")
      samples[[length(samples) + 1L]] <<- sample
      file.exists(file.path(root, "result.rds"))
    })
    value <- readRDS(file.path(root, "result.rds"))
    if (!is.null(browser)) {
      marker <- sprintf("MEMORY_%06d_", events)
      wait_until(function() isTRUE(js(sprintf(
        "memoryDeepText().includes('%s')", marker
      ))))
      stopifnot(console_errors == 0L, network_errors == 0L)
    }
    saveRDS(value, file.path(output, paste0(arm, "-result.rds")))
    if (length(value$phases)) {
      write.table(
        do.call(rbind, lapply(value$phases, as.data.frame)),
        file.path(output, paste0(arm, "-phases.tsv")),
        sep = "\t", row.names = FALSE, quote = FALSE
      )
    }
    write.table(do.call(rbind, samples), file.path(output, paste0(arm, "-samples.tsv")),
                sep = "\t", row.names = FALSE, quote = FALSE)
    if (profile) {
      stopifnot(file.copy(file.path(root, "alloc.out"),
                         file.path(output, paste0(arm, "-alloc.out"))))
      stopifnot(file.copy(file.path(root, "cpu.out"),
                         file.path(output, paste0(arm, "-cpu.out"))))
    }
    file.create(file.path(root, "stop"))
    subject$wait(5000)
    stopifnot(!subject$is_alive(), subject$get_exit_status() == 0L)
    cleanup()
    data.frame(
      arm = arm, deep_stack = deep_stack, events = events,
      done = value$done, chunks = value$chunks,
      semantic_ok = value$semantic_ok, cleanup_confirmed = !subject$is_alive(),
      first_chunk_seconds = value$first_chunk_seconds,
      duration_seconds = value$duration_seconds,
        observation_seconds = value$observation_seconds,
      pss_baseline_bytes = value$baseline[["pss"]],
      pss_peak_bytes = max(vapply(samples, `[[`, numeric(1), "pss"),
                           value$pre_gc[["pss"]]),
      pss_pre_gc_bytes = value$pre_gc[["pss"]],
      pss_post_gc_bytes = value$post_gc[["pss"]],
      rss_post_gc_bytes = value$post_gc[["rss"]],
      r_heap_used_bytes = value$heap_used_bytes,
      r_heap_trigger_bytes = value$heap_trigger_bytes,
      console_errors = console_errors, network_errors = network_errors
    )
  }
  results <- list()
  for (arm in arms) {
    cat(sprintf("[ARM] %s events=%d deepStack=%s profile=%s\n",
                arm, events, deep_stack, profile))
    results[[arm]] <- run_arm(arm)
    print(results[[arm]], row.names = FALSE)
    write.table(do.call(rbind, results), file.path(output, "summary.tsv"),
                sep = "\t", row.names = FALSE, quote = FALSE)
  }
  cat("EVIDENCE ", normalizePath(output), "\n", sep = "")
  do.call(rbind, results)
}

if (sys.nframe() == 0L) {
  arms <- strsplit(Sys.getenv("AUI_MEMORY_ARMS", "sdk,handler,shinychat,plugin"), ",")[[1L]]
  invisible(run_sdk_memory_comparison(
    arms = arms,
    events = as.integer(Sys.getenv("AUI_MEMORY_EVENTS", "1200")),
    interval = as.numeric(Sys.getenv("AUI_MEMORY_INTERVAL", "0.001")),
    profile = identical(Sys.getenv("AUI_MEMORY_PROFILE"), "1"),
    output = Sys.getenv("AUI_MEMORY_OUT", tempfile("sdk-memory-comparison-")),
    timeout = as.numeric(Sys.getenv("AUI_MEMORY_TIMEOUT", "90")),
    deep_stack = !identical(Sys.getenv("AUI_MEMORY_DEEPSTACK"), "0"),
    quiet_seconds = as.numeric(Sys.getenv("AUI_MEMORY_QUIET_SECONDS", "0")),
    usage_delay_seconds = as.numeric(Sys.getenv("AUI_MEMORY_USAGE_DELAY_SECONDS", "0")),
    post_done_seconds = as.numeric(Sys.getenv("AUI_MEMORY_POST_DONE_SECONDS", "0"))
  ))
}
