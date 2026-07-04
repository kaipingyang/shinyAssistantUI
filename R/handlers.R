`%||%` <- function(x, y) if (is.null(x)) y else x

# 把 text + file 类附件拼成注入用的文本上下文（image 类由各 handler 单独处理）。
# file 类（PDF/xlsx/二进制等）内容是 base64，无法直接喂文本模型——这里至少把
# 文件名/类型作为提示注入，让 AI 知道用户上传了文件、能据此回应，而非静默丢弃
# （否则 UI 显示了附件 chip 但 AI 完全无感知，误导用户）。
.attachment_text_sections <- function(atts) {
  text_parts <- vapply(
    Filter(function(a) identical(a$type, "text"), atts),
    function(a) a$data %||% "", character(1)
  )
  file_parts <- vapply(
    Filter(function(a) identical(a$type, "file"), atts),
    function(a) {
      nm <- a$name %||% "unnamed"
      ct <- a$contentType %||% "unknown type"
      sprintf("[Attached file: %s (%s) \u2014 binary content not directly readable]", nm, ct)
    },
    character(1)
  )
  paste(c(text_parts, file_parts), collapse = "\n")
}

# ── ellmer turns → ThreadMessageLike（内部辅助）──────────────────────────────
.ellmer_turns_to_messages <- function(turns) {
  result <- list()
  for (t in turns) {
    role <- tryCatch(t@role, error = function(e) NULL)
    if (is.null(role) || identical(role, "system")) next
    contents   <- tryCatch(t@contents, error = function(e) list())
    text_parts <- Filter(function(c) inherits(c, "ellmer::ContentText"), contents)
    text       <- paste(
      vapply(text_parts, function(c) tryCatch(c@text, error = function(e) ""), character(1)),
      collapse = ""
    )
    if (!nzchar(trimws(text))) next
    msg <- list(
      id      = paste0("h-", format(as.numeric(Sys.time()) * 1e3, scientific = FALSE),
                       "-", sample.int(1e5, 1)),
      role    = role,
      content = list(list(type = "text", text = text))
    )
    if (identical(role, "assistant")) msg$status <- list(type = "complete", reason = "stop")
    result[[length(result) + 1L]] <- msg
  }
  result
}

#' Create an ellmer streaming handler for assistantUIServer
#'
#' Wraps an `ellmer` chat object into an `assistantUIServer`-compatible
#' handler. Supports per-thread conversation history, tool calling with
#' optional human-in-the-loop approval, attachments, and optional SQLite
#' session persistence.
#'
#' @param chat A zero-argument function returning a new `ellmer` chat object.
#'   Called once per thread on first message. Example:
#'   `function() chat_openai_compatible(...)`.
#' @param tools A list of `ellmer::tool()` objects to register on each chat.
#'   If `NULL`, no tools are registered.
#' @param approval_tools Character vector of tool names that require human
#'   approval before execution. Defaults to `character(0)` (no approval).
#' @param store Optional session store created by [ellmer_session_store()].
#'   When provided, chat state is persisted to SQLite across R restarts.
#'
#' @return A `coro::async` handler function compatible with [assistantUIServer()].
#'
#' @examples
#' \dontrun{
#' store <- ellmer_session_store(".sessions/chat.db")
#'
#' handler <- make_ellmer_handler(
#'   chat           = function() chat_openai_compatible(
#'     base_url    = Sys.getenv("OPENAI_BASE_URL"),
#'     model       = Sys.getenv("OPENAI_MODEL"),
#'     credentials = function() Sys.getenv("OPENAI_API_KEY")
#'   ),
#'   tools          = list(get_weather, calculate),
#'   approval_tools = c("calculate"),
#'   store          = store
#' )
#'
#' assistantUIServer("chat", handler = handler, show_thread_list = TRUE,
#'   on_session_load = make_ellmer_session_loader(store))
#' }
#'
#' @export
make_ellmer_handler <- function(chat,
                                tools          = NULL,
                                approval_tools = character(0),
                                store          = NULL) {
  chats <- list()  # thread_id -> list(chat, current)

  get_chat_obj <- function(thread_id) {
    if (!is.null(chats[[thread_id]])) return(chats[[thread_id]])

    chat_obj <- chat()
    if (!is.null(tools)) chat_obj$register_tools(tools)

    # 从 store 恢复历史
    if (!is.null(store)) {
      saved <- tryCatch(store$load(thread_id), error = function(e) NULL)
      if (!is.null(saved)) {
        tryCatch(
          .ellmer_chat_set_state(chat_obj, saved),
          error = function(e) message("[ELLMER] restore failed: ", conditionMessage(e))
        )
      }
    }

    current <- new.env(parent = emptyenv())
    current$on_tool_call      <- NULL
    current$on_tool_result    <- NULL
    current$wait_for_approval <- NULL

    chat_obj$on_tool_request(coro::async(function(request) {
      needs_approval <- request@name %in% approval_tools
      current$on_tool_call(
        tool_call_id = request@id,
        tool_name    = request@name,
        args         = request@arguments,
        annotations  = c(
          request@tool@annotations %||% list(),
          list(requiresApproval = needs_approval)
        )
      )
      if (needs_approval) {
        decision <- coro::await(current$wait_for_approval(request@id))
        approved <- isTRUE(if (is.list(decision)) decision$approved else decision)
        if (!approved) ellmer::tool_reject("User denied the tool call.")
      }
    }))

    chat_obj$on_tool_result(function(result) {
      current$on_tool_result(
        tool_call_id = result@request@id,
        result       = if (!is.null(result@error)) result@error else result@value,
        is_error     = !is.null(result@error)
      )
    })

    obj <- list(chat = chat_obj, current = current)
    chats[[thread_id]] <<- obj
    obj
  }

  coro::async(function(
    message, thread_id, attachments,
    on_chunk, on_done, on_error,
    on_tool_call, on_tool_result, is_cancelled,
    wait_for_approval, register_cancel
  ) {
    obj     <- get_chat_obj(thread_id)
    chat_obj <- obj$chat
    current  <- obj$current

    current$on_tool_call      <- on_tool_call
    current$on_tool_result    <- on_tool_result
    current$wait_for_approval <- wait_for_approval

    atts <- attachments %||% list()

    img_parts <- lapply(
      Filter(function(a) identical(a$type, "image"), atts),
      function(a) ellmer::content_image_url(a$data)
    )
    text_sections <- .attachment_text_sections(atts)
    full_message <- message
    if (nzchar(text_sections)) full_message <- paste0(text_sections, "\n\n", message)

    ctrl <- ellmer::stream_controller()
    register_cancel(function() ctrl$cancel("User interrupted"))

    stream <- do.call(chat_obj$stream_async,
                      c(list(full_message), img_parts, list(controller = ctrl)))
    had_error <- FALSE
    tryCatch(
      for (chunk in coro::await_each(stream)) {
        if (is_cancelled()) break
        on_chunk(chunk)
      },
      error = function(e) {
        had_error <<- TRUE
        if (!is_cancelled()) on_error(conditionMessage(e))
      }
    )

    if (!had_error) on_done()

    # 持久化到 store
    if (!had_error && !is.null(store) && !is_cancelled() && !ctrl$cancelled) {
      tryCatch({
        store$save(thread_id, chat_obj,
                   title     = substr(message, 1, 40),
                   first_msg = substr(message, 1, 200))
      }, error = function(e) {
        message("[ELLMER] save failed: ", conditionMessage(e))
      })
    }

    current$on_tool_call      <- NULL
    current$on_tool_result    <- NULL
    current$wait_for_approval <- NULL
  })
}

#' Create an on_session_load callback for ellmer session store
#'
#' Returns a function suitable for the `on_session_load` argument of
#' [assistantUIServer()], restoring chat turns from a [ellmer_session_store()].
#'
#' @param store A session store created by [ellmer_session_store()].
#'
#' @return A function with signature `function(session_id, thread_id, send_thread)`.
#'
#' @export
make_ellmer_session_loader <- function(store) {
  function(session_id, thread_id, send_thread) {
    saved <- tryCatch(store$load(thread_id), error = function(e) NULL)
    if (is.null(saved)) { send_thread(list()); return() }
    turns <- tryCatch({
      state_json <- memDecompress(base64enc::base64decode(saved$state), asChar = TRUE)
      recorded   <- jsonlite::unserializeJSON(state_json)
      lapply(recorded, ellmer::contents_replay, tools = list())
    }, error = function(e) {
      message("[ELLMER] session load failed: ", conditionMessage(e))
      list()
    })
    send_thread(.ellmer_turns_to_messages(turns))
  }
}

# ── ClaudeAgentSDK handler ────────────────────────────────────────────────────

#' Create a ClaudeAgentSDK handler for assistantUIServer
#'
#' Wraps `ClaudeAgentSDK` into an `assistantUIServer`-compatible handler.
#' Supports streaming, tool approval UI, thinking output, attachments,
#' and session persistence across R restarts.
#'
#' @param options A `ClaudeAgentOptions` object. Defaults to
#'   `ClaudeAgentOptions(permission_mode = "default", permission_prompt_tool_name = "stdio", include_partial_messages = TRUE)`.
#' @param session_map_path Path to the `.rds` file used to persist
#'   `thread_id -> session_id` mappings. Defaults to
#'   `".claude_session_map.rds"` in the current working directory.
#'
#' @return A `coro::async` handler function compatible with [assistantUIServer()].
#'
#' @examples
#' \dontrun{
#' handler <- make_claude_handler()
#'
#' server <- function(input, output, session) {
#'   ctrl <- assistantUIServer("chat", handler = handler,
#'                             show_thread_list = TRUE)
#'   # inject sessions into sidebar
#'   shiny::observe({
#'     sessions <- list_claude_sessions()
#'     ctrl$send_sessions(list(sessions = sessions))
#'   })
#' }
#' }
#'
#' @export
make_claude_handler <- function(options       = NULL,
                                session_map_path = ".claude_session_map.rds") {
  if (is.null(options)) {
    options <- ClaudeAgentSDK::ClaudeAgentOptions(
      permission_mode             = "default",
      permission_prompt_tool_name = "stdio",
      include_partial_messages    = TRUE
    )
  }

  # session map 持久化。
  # 磁盘是单一真相源：make_claude_session_loader 在用户导入历史 session 时会写盘，
  # 但它持有独立的内存副本，无法直接同步到本 handler。因此 get_client 在内存
  # miss 时回读磁盘，确保进程内导入的 session 也能 resume（见 read_session_map）。
  session_map <- if (file.exists(session_map_path))
    tryCatch(readRDS(session_map_path), error = function(e) list())
  else list()

  save_session_map <- function() {
    tryCatch(saveRDS(session_map, session_map_path), error = function(e) NULL)
  }

  # 取某线程的 session id：先查内存，miss 则回读磁盘（捕获 loader 的写入）。
  read_session_id <- function(thread_id) {
    sid <- session_map[[thread_id]]
    if (!is.null(sid) && nzchar(sid %||% "")) return(sid)
    if (!file.exists(session_map_path)) return(NULL)
    disk <- tryCatch(readRDS(session_map_path), error = function(e) NULL)
    if (is.null(disk)) return(NULL)
    disk_sid <- disk[[thread_id]]
    if (!is.null(disk_sid) && nzchar(disk_sid %||% "")) {
      session_map[[thread_id]] <<- disk_sid  # 同步进内存缓存
      return(disk_sid)
    }
    NULL
  }

  clients <- list()

  get_client <- function(thread_id) {
    if (!is.null(clients[[thread_id]])) return(clients[[thread_id]])

    stored_sid <- read_session_id(thread_id)

    make_opts <- function(resume_sid = NULL) {
      ClaudeAgentSDK::ClaudeAgentOptions(
        permission_mode             = options$permission_mode %||% "default",
        permission_prompt_tool_name = options$permission_prompt_tool_name %||% "stdio",
        include_partial_messages    = options$include_partial_messages %||% TRUE,
        resume                      = resume_sid
      )
    }

    client <- if (!is.null(stored_sid) && nzchar(stored_sid %||% "")) {
      c <- ClaudeAgentSDK::ClaudeSDKClient$new(make_opts(stored_sid))
      result <- tryCatch({ c$connect(); c }, error = function(e) {
        message("[CLAUDE] resume failed, starting fresh: ", conditionMessage(e))
        session_map[[thread_id]] <<- NULL
        save_session_map()
        NULL
      })
      if (!is.null(result)) result else {
        c2 <- ClaudeAgentSDK::ClaudeSDKClient$new(make_opts())
        c2$connect(); c2
      }
    } else {
      c <- ClaudeAgentSDK::ClaudeSDKClient$new(make_opts())
      c$connect(); c
    }

    clients[[thread_id]] <<- client
    client
  }

  later_promise <- function(delay = 0.05) {
    promises::promise(function(resolve, reject) {
      later::later(function() resolve(NULL), delay = delay)
    })
  }

  persist_session <- function(thread_id, sid) {
    if (is.null(sid) || !nzchar(sid %||% "")) return(invisible(NULL))
    session_map[[thread_id]] <<- sid
    save_session_map()
  }

  # 回收所有 client 子进程（每个 ClaudeSDKClient 持有一个 CLI 子进程）。
  # 通过 attr 暴露给 assistantUIServer，在 session 结束时调用，防止长生命周期
  # Shiny session 不断新建线程导致子进程累积泄漏。
  cleanup <- function() {
    for (tid in names(clients)) {
      tryCatch(clients[[tid]]$disconnect(), error = function(e) NULL)
    }
    clients <<- list()
  }

  handler_fn <- coro::async(function(
    message, thread_id, attachments,
    on_chunk, on_done, on_error,
    on_tool_call, on_tool_result, on_thinking,
    is_cancelled, wait_for_approval,
    on_tool_call_start = NULL, on_tool_call_delta = NULL
  ) {
    client <- tryCatch(
      get_client(thread_id),
      error = function(e) { on_error(conditionMessage(e)); NULL }
    )
    if (is.null(client)) return(invisible(NULL))

    atts <- attachments %||% list()
    img_parts <- lapply(
      Filter(function(a) identical(a$type, "image"), atts),
      function(a) a$data
    )
    text_sections <- .attachment_text_sections(atts)
    full_message <- message
    if (nzchar(text_sections)) full_message <- paste0(text_sections, "\n\n", message)

    if (length(img_parts) > 0)
      client$send_with_images(full_message, img_parts)
    else
      client$send(full_message)

    interrupted      <- FALSE
    chunk_count      <- 0L
    pending_tool_ids <- character(0)
    tb               <- new.env(parent = emptyenv())

    flush_tool_blocks <- function(mark_completed = FALSE) {
      for (key in ls(tb)) {
        blk <- tb[[key]]
        if (isTRUE(blk$approval_handled)) next
        if (!isTRUE(blk$emitted)) next
        if (mark_completed) on_tool_result(blk$id, "Completed", is_error = FALSE)
      }
      rm(list = ls(tb), envir = tb)
    }

    # 中断时清理半截 tool block：on_tool_call_start 已在前端建了卡片，但参数未收完、
    # 未 emit on_tool_call，正常 flush 会跳过它们（emitted=FALSE）导致卡片永久转圈。
    # 这里对所有未审批的 block 发 "Interrupted" result，与前端 onDone 兜底对齐。
    # pending_tool_ids 由调用点负责清理（避免 coro async 内 <<- 的不确定性）。
    interrupt_tool_blocks <- function() {
      for (key in ls(tb)) {
        blk <- tb[[key]]
        if (isTRUE(blk$approval_handled)) next
        on_tool_result(blk$id, "Interrupted", is_error = TRUE)
      }
      rm(list = ls(tb), envir = tb)
    }

    # drain 兜底：interrupt() 后正常应很快收到 ResultMessage 结束 drain。
    # 但若 SDK 子进程崩溃/HTTP 异常终止（poll 返回空），或持续吐非-ResultMessage
    # 垃圾事件（poll 非空但永不收尾），都会导致 repeat 死循环、ExtendedTask 永不
    # resolve、前端永久 running。用墙钟封顶覆盖两种场景（非"连续空轮询"——后者
    # 在持续吐垃圾时会被不断重置而失效）。
    DRAIN_TIMEOUT_SECS <- 10
    drain_start        <- NULL  # interrupted 时记录起点

    repeat {
      if (!interrupted && is_cancelled()) {
        interrupted <- TRUE
        drain_start <- Sys.time()
        tryCatch(client$interrupt(), error = function(e) NULL)
        # 立即清理半截工具卡，不等 drain（drain 只认 ResultMessage，会漏掉它们）
        interrupt_tool_blocks()
        for (tid in pending_tool_ids) on_tool_result(tid, "Interrupted", is_error = TRUE)
        pending_tool_ids <- character(0)
      }

      # 墙钟封顶：无论 poll 空或非空，中断后超时即强制收尾
      if (interrupted && !is.null(drain_start) &&
          as.numeric(Sys.time() - drain_start, units = "secs") >= DRAIN_TIMEOUT_SECS) {
        message("[CLAUDE] drain timeout after interrupt - forcing done")
        break
      }

      msgs <- client$poll_messages()
      if (length(msgs) == 0) {
        coro::await(later_promise(0.05)); next
      }

      done <- FALSE; drain_done <- FALSE

      for (msg in msgs) {
        if (interrupted) {
          if (inherits(msg, "ResultMessage")) {
            persist_session(thread_id, msg$session_id)
            drain_done <- TRUE; break
          }
          next
        }

        if (inherits(msg, "StreamEvent")) {
          evt   <- msg$event
          etype <- evt[["type"]]
          delta <- evt[["delta"]]
          bidx  <- as.character(evt[["index"]] %||% "")

          if (identical(etype, "content_block_start")) {
            blk <- evt[["content_block"]]
            if (identical(blk[["type"]], "tool_use")) {
              tb[[bidx]] <- list(id=blk[["id"]], name=blk[["name"]],
                                 args_buf="", emitted=FALSE, approval_handled=FALSE)
              if (!is.null(on_tool_call_start))
                on_tool_call_start(tool_call_id=blk[["id"]], tool_name=blk[["name"]])
            }

          } else if (identical(etype, "content_block_delta") && is.list(delta)) {
            if (identical(delta[["type"]], "input_json_delta") && nzchar(bidx) && !is.null(tb[[bidx]])) {
              tb[[bidx]]$args_buf <- paste0(tb[[bidx]]$args_buf, delta[["partial_json"]] %||% "")
              if (!is.null(on_tool_call_delta) && nzchar(delta[["partial_json"]] %||% ""))
                on_tool_call_delta(tool_call_id=tb[[bidx]]$id, delta=delta[["partial_json"]])
            }

            if (identical(delta[["type"]], "text_delta") && nzchar(delta[["text"]] %||% "")) {
              if (length(pending_tool_ids) > 0) {
                for (tid in pending_tool_ids) on_tool_result(tid, "Completed", is_error = FALSE)
                pending_tool_ids <- character(0)
              }
              flush_tool_blocks(mark_completed = TRUE)
              chunk_count <- chunk_count + 1L
              on_chunk(delta[["text"]])
            }
            if (identical(delta[["type"]], "thinking_delta") && nzchar(delta[["thinking"]] %||% ""))
              on_thinking(delta[["thinking"]])

          } else if (identical(etype, "content_block_stop") && nzchar(bidx) && !is.null(tb[[bidx]])) {
            blk <- tb[[bidx]]
            if (!isTRUE(blk$approval_handled)) {
              args_parsed <- tryCatch(
                jsonlite::fromJSON(blk$args_buf, simplifyVector = FALSE),
                error = function(e) list()
              )
              on_tool_call(tool_call_id=blk$id, tool_name=blk$name,
                           args=args_parsed, annotations=list())
              tb[[bidx]]$emitted <- TRUE
            }
          }

        } else if (inherits(msg, "PermissionRequestMessage")) {
          for (bidx in ls(tb)) {
            if (identical(tb[[bidx]]$id, msg$request_id)) {
              tb[[bidx]]$approval_handled <- TRUE; break
            }
          }
          on_tool_call(
            tool_call_id = msg$request_id,
            tool_name    = msg$tool_name,
            args         = msg$tool_input,
            annotations  = list(requiresApproval=TRUE, suggestions=msg$suggestions %||% list())
          )

          decision <- coro::await(wait_for_approval(msg$request_id))

          if (!interrupted && is_cancelled()) {
            interrupted <- TRUE
            tryCatch(client$deny_tool(msg$request_id, "Interrupted"), error = function(e) NULL)
            tryCatch(client$interrupt(), error = function(e) NULL)
            on_tool_result(msg$request_id, "Interrupted", is_error = TRUE)
            # 清理其它半截工具卡（parallel tool use 场景）
            interrupt_tool_blocks()
            for (tid in pending_tool_ids) on_tool_result(tid, "Interrupted", is_error = TRUE)
            pending_tool_ids <- character(0)
          } else if (isTRUE(decision$approved)) {
            sidx <- decision$suggestionIdx
            if (!is.null(sidx) && is.numeric(sidx) &&
                sidx >= 0 && sidx < length(msg$suggestions)) {
              sug <- msg$suggestions[[sidx + 1L]]
              if (!is.null(sug)) {
                if (identical(sug$type, "addRules")) {
                  perm <- ClaudeAgentSDK::PermissionUpdate(
                    type        = "addRules",
                    rules       = lapply(sug$rules %||% list(), function(r)
                      ClaudeAgentSDK::PermissionRuleValue(
                        tool_name    = r$toolName %||% r$tool_name %||% "",
                        rule_content = r$ruleContent %||% r$rule_content %||% NULL)),
                    behavior    = sug$behavior %||% "allow",
                    destination = sug$destination %||% "localSettings"
                  )
                  client$approve_tool(msg$request_id, updated_permissions = list(perm))
                } else if (identical(sug$type, "addDirectories")) {
                  perm <- ClaudeAgentSDK::PermissionUpdate(
                    type        = "addDirectories",
                    directories = sug$directories,
                    destination = sug$destination %||% "localSettings"
                  )
                  client$approve_tool(msg$request_id, updated_permissions = list(perm))
                } else {
                  client$approve_tool(msg$request_id)
                }
              } else { client$approve_tool(msg$request_id) }
            } else { client$approve_tool(msg$request_id) }
            pending_tool_ids <- c(pending_tool_ids, msg$request_id)
          } else {
            deny_msg <- decision$customMessage %||% "Denied by user"
            client$deny_tool(msg$request_id, deny_msg)
            on_tool_result(msg$request_id, deny_msg, is_error = TRUE)
          }

        } else if (inherits(msg, "ResultMessage")) {
          for (tid in pending_tool_ids) on_tool_result(tid, "Completed", is_error = FALSE)
          pending_tool_ids <- character(0)
          flush_tool_blocks(mark_completed = TRUE)
          persist_session(thread_id, msg$session_id)
          done <- TRUE; break
        }
      }

      if (drain_done || done) break
      coro::await(later_promise(0.01))
    }

    on_done()
  })

  attr(handler_fn, "cleanup") <- cleanup
  handler_fn
}

#' List Claude sessions for sidebar injection
#'
#' Helper to fetch sessions from `ClaudeAgentSDK::list_sessions()` and
#' format them for `ctrl$send_sessions()`.
#'
#' @param directory Project directory to filter sessions. Defaults to `here::here()`.
#' @param limit Maximum number of sessions to return.
#'
#' @return A list suitable for `ctrl$send_sessions(list(sessions = ...))`.
#'
#' @export
list_claude_sessions <- function(directory = here::here(), limit = 100L) {
  raw <- tryCatch(
    ClaudeAgentSDK::list_sessions(directory = directory, limit = limit),
    error = function(e) list()
  )
  lapply(raw, function(s) {
    ts <- s$last_modified %||% s$created_at
    ts <- if (!is.null(ts) && !is.na(ts) && is.numeric(ts)) ts else NULL
    list(
      id        = s$session_id,
      title     = s$summary %||% s$first_prompt %||% s$session_id,
      preview   = s$first_prompt %||% "",
      createdAt = ts
    )
  })
}

#' Create an on_session_load callback for ClaudeAgentSDK sessions
#'
#' Returns a function suitable for the `on_session_load` argument of
#' [assistantUIServer()], loading historical messages from Claude session files.
#'
#' @param session_map_path Path to the session map `.rds` file (same path
#'   passed to [make_claude_handler()]).
#'
#' @return A function with signature `function(session_id, thread_id, send_thread)`.
#'
#' @export
make_claude_session_loader <- function(session_map_path = ".claude_session_map.rds") {
  session_map <- if (file.exists(session_map_path))
    tryCatch(readRDS(session_map_path), error = function(e) list())
  else list()

  function(session_id, thread_id, send_thread) {
    # 预填 session_map（使 get_client 能 resume）
    if (!is.null(session_id) && nzchar(session_id %||% "")) {
      session_map[[thread_id]] <<- session_id
      tryCatch(saveRDS(session_map, session_map_path), error = function(e) NULL)
    }

    msgs <- tryCatch(
      ClaudeAgentSDK::get_session_messages(session_id),
      error = function(e) list()
    )
    send_thread(.claude_msgs_to_thread(msgs))
  }
}

# ── ClaudeAgentSDK JSONL → ThreadMessageLike（内部辅助）──────────────────────
.claude_msgs_to_thread <- function(msgs) {
  result <- list()
  for (m in msgs) {
    if (m$type == "user") {
      raw  <- m$message$content
      text <- if (is.character(raw)) raw
              else {
                tb2 <- Filter(function(b) identical(b[["type"]], "text"), raw)
                if (!length(tb2)) next
                paste(vapply(tb2, function(b) b[["text"]] %||% "", character(1)), collapse = "")
              }
      if (!nzchar(trimws(text))) next
      result[[length(result) + 1L]] <- list(
        id      = paste0("h-", m$uuid),
        role    = "user",
        content = list(list(type = "text", text = text))
      )
    } else if (m$type == "assistant") {
      raw   <- m$message$content
      parts <- list()
      if (is.character(raw) && nzchar(raw)) {
        parts[[1L]] <- list(type = "text", text = raw)
      } else if (is.list(raw)) {
        for (blk in raw) {
          if (identical(blk[["type"]], "text") && nzchar(blk[["text"]] %||% ""))
            parts[[length(parts) + 1L]] <- list(type = "text", text = blk[["text"]])
          else if (identical(blk[["type"]], "tool_use")) {
            args_val <- if (is.list(blk[["input"]])) blk[["input"]] else list()
            parts[[length(parts) + 1L]] <- list(
              type       = "tool-call",
              toolCallId = blk[["id"]] %||% paste0("h-tool-", length(parts)),
              toolName   = blk[["name"]] %||% "unknown",
              args       = args_val,
              argsText   = tryCatch(jsonlite::toJSON(args_val, auto_unbox=TRUE), error=function(e) "{}"),
              result     = "Session ended",
              isError    = FALSE
            )
          }
        }
      }
      if (!length(parts)) next
      result[[length(result) + 1L]] <- list(
        id      = paste0("h-", m$uuid),
        role    = "assistant",
        content = parts,
        status  = list(type = "complete", reason = "stop")
      )
    }
  }
  result
}
