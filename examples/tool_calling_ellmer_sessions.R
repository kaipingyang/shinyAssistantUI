library(shiny)
library(ellmer)
library(DBI)
library(RSQLite)
devtools::load_all(here::here())

`%||%` <- function(x, y) if (is.null(x)) y else x

# ── 序列化辅助（源自 shinychat/client_state.R，MIT License）─────────────────
# https://github.com/posit-dev/shinychat/blob/main/pkg-r/R/client_state.R
# 不依赖 shinychat 包——直接内嵌逻辑。
# 关键：必须用 serializeJSON/unserializeJSON，不能用 toJSON/fromJSON；
# toJSON 是有损转换，unserializeJSON 才能还原 S7 props 中的 R 特有类型。
ellmer_chat_get_state <- function(chat) {
  recorded   <- lapply(chat$get_turns(), ellmer::contents_record)
  state_json <- jsonlite::serializeJSON(recorded)
  state_str  <- base64enc::base64encode(memCompress(state_json, "gzip"))
  list(version = 1L, state = state_str)
}

ellmer_chat_set_state <- function(chat, state) {
  state_json     <- memDecompress(base64enc::base64decode(state$state), asChar = TRUE)
  recorded       <- jsonlite::unserializeJSON(state_json)
  replayed_turns <- lapply(recorded, ellmer::contents_replay, tools = chat$get_tools())
  chat$set_turns(replayed_turns)
}

# ── SQLite session store ─────────────────────────────────────────────────────
# 单文件数据库；list_sessions 不读 state 列（懒加载），on_session_load 才按需读取。
ellmer_session_store <- function(db_path) {
  dir.create(dirname(db_path), showWarnings = FALSE, recursive = TRUE)
  con <- DBI::dbConnect(RSQLite::SQLite(), db_path, synchronous = "normal")
  DBI::dbExecute(con, "PRAGMA journal_mode = WAL")
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sessions (
      thread_id  TEXT PRIMARY KEY,
      title      TEXT NOT NULL DEFAULT '',
      first_msg  TEXT NOT NULL DEFAULT '',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      state      TEXT NOT NULL
    )
  ")

  list(
    # 保存或更新 session（ON CONFLICT 不覆盖 first_msg / created_at）
    save = function(thread_id, chat, title = "", first_msg = "") {
      state     <- ellmer_chat_get_state(chat)
      state_str <- jsonlite::toJSON(state, auto_unbox = TRUE)
      now       <- as.integer(Sys.time() * 1000)
      DBI::dbExecute(con,
        "INSERT INTO sessions (thread_id, title, first_msg, created_at, updated_at, state)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(thread_id) DO UPDATE SET
           title      = excluded.title,
           updated_at = excluded.updated_at,
           state      = excluded.state",
        list(thread_id, title, first_msg, now, now, state_str)
      )
      invisible(NULL)
    },

    # 列出所有 sessions（不读 state 列，保持低开销）
    list_sessions = function(limit = 100L) {
      rows <- DBI::dbGetQuery(con,
        "SELECT thread_id, title, first_msg, created_at
         FROM sessions ORDER BY updated_at DESC LIMIT ?",
        list(limit)
      )
      lapply(seq_len(nrow(rows)), function(i) list(
        id        = rows$thread_id[[i]],
        title     = rows$title[[i]],
        preview   = rows$first_msg[[i]],
        createdAt = rows$created_at[[i]]
      ))
    },

    # 读取单个 session 的序列化状态
    load = function(thread_id) {
      rows <- DBI::dbGetQuery(con,
        "SELECT state FROM sessions WHERE thread_id = ?",
        list(thread_id)
      )
      if (nrow(rows) == 0) return(NULL)
      jsonlite::fromJSON(rows$state[[1]], simplifyVector = FALSE)
    },

    delete = function(thread_id) {
      DBI::dbExecute(con, "DELETE FROM sessions WHERE thread_id = ?", list(thread_id))
    }
  )
}

# ── Session store 实例（app 级别，跨 Shiny session 共享）────────────────────
store <- ellmer_session_store(
  file.path(here::here(), ".ellmer_sessions", "sessions.db")
)

# ── 工具定义 ─────────────────────────────────────────────────────────────────
get_weather <- tool(
  function(city) {
    Sys.sleep(0.3)
    conditions <- c("Sunny", "Partly Cloudy", "Cloudy", "Light Rain",
                    "Rain", "Windy", "Thunderstorm", "Snow")
    days       <- c("TODAY", "MON", "TUE", "WED", "THU")
    cond       <- sample(conditions, 1)
    temp       <- sample(45:85, 1)
    list(
      city        = city,
      temperature = temp,
      unit        = "F",
      condition   = cond,
      high        = temp + sample(4:10, 1),
      low         = temp - sample(4:10, 1),
      humidity    = sample(40:90, 1),
      wind        = sample(5:35, 1),
      forecast    = lapply(seq_along(days), function(i) {
        ft <- temp + sample(-6:6, 1)
        list(day = days[[i]], high = ft + sample(3:7, 1),
             low = ft - sample(3:7, 1), condition = sample(conditions, 1))
      })
    )
  },
  name        = "get_weather",
  description = "Get current weather information for a city",
  arguments   = list(city = type_string("The name of the city")),
  annotations = tool_annotations(title = "Weather Lookup", icon = "cloud-sun")
)

calculate <- tool(
  function(expression) {
    tryCatch(
      as.character(eval(parse(text = expression))),
      error = function(e) stop(conditionMessage(e))
    )
  },
  name        = "calculate",
  description = "Evaluate a mathematical expression (R syntax)",
  arguments   = list(expression = type_string("A valid R expression, e.g. 'sqrt(144)'")),
  annotations = tool_annotations(title = "Calculator", icon = "calculator")
)

APPROVAL_TOOLS <- c("calculate")

# ── Chat 对象池（thread_id → list(chat, current)）────────────────────────────
chats <- list()

get_chat <- function(thread_id) {
  if (!is.null(chats[[thread_id]])) return(chats[[thread_id]])

  chat <- chat_openai_compatible(
    base_url    = Sys.getenv("OPENAI_BASE_URL"),
    model       = Sys.getenv("OPENAI_MODEL"),
    credentials = function() Sys.getenv("OPENAI_API_KEY")
  )
  chat$register_tools(list(get_weather, calculate))

  # 从 SQLite 恢复历史（工具已注册，contents_replay 可正确关联工具定义）
  saved_state <- store$load(thread_id)
  if (!is.null(saved_state)) {
    tryCatch(
      ellmer_chat_set_state(chat, saved_state),
      error = function(e) message("[SESSION] restore failed: ", conditionMessage(e))
    )
    message("[SESSION] Restored thread=", thread_id,
            " turns=", length(chat$get_turns()))
  }

  current <- new.env(parent = emptyenv())
  current$on_tool_call      <- NULL
  current$on_tool_result    <- NULL
  current$wait_for_approval <- NULL

  chat$on_tool_request(coro::async(function(request) {
    needs_approval <- request@name %in% APPROVAL_TOOLS
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
      approved <- coro::await(current$wait_for_approval(request@id))
      if (!approved) ellmer::tool_reject("User denied the tool call.")
    }
  }))

  chat$on_tool_result(function(result) {
    current$on_tool_result(
      tool_call_id = result@request@id,
      result       = if (!is.null(result@error)) result@error else result@value,
      is_error     = !is.null(result@error)
    )
  })

  obj <- list(chat = chat, current = current)
  chats[[thread_id]] <<- obj
  obj
}

# ── ellmer turns → ThreadMessageLike（用于 on_session_load 侧边栏加载）───────
ellmer_turns_to_messages <- function(turns) {
  result <- list()
  for (t in turns) {
    role <- tryCatch(t@role, error = function(e) NULL)
    if (is.null(role) || identical(role, "system")) next
    contents   <- tryCatch(t@contents, error = function(e) list())
    text_parts <- Filter(function(c) inherits(c, "ContentText"), contents)
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

# ── handler ──────────────────────────────────────────────────────────────────
handler <- coro::async(function(
  message, thread_id, attachments,
  on_chunk, on_done, on_error,
  on_tool_call, on_tool_result, is_cancelled,
  wait_for_approval, register_cancel
) {
  obj     <- get_chat(thread_id)
  chat    <- obj$chat
  current <- obj$current

  current$on_tool_call      <- on_tool_call
  current$on_tool_result    <- on_tool_result
  current$wait_for_approval <- wait_for_approval

  atts <- attachments %||% list()

  img_parts <- lapply(
    Filter(function(a) identical(a$type, "image"), atts),
    function(a) content_image_url(a$data)
  )

  text_sections <- paste(
    vapply(Filter(function(a) identical(a$type, "text"), atts),
           function(a) a$data, character(1)),
    collapse = "\n"
  )
  full_message <- if (nzchar(text_sections)) paste0(text_sections, "\n\n", message) else message

  ctrl        <- ellmer::stream_controller()
  chunk_count <- 0L
  register_cancel(function() {
    message("[INTERRUPT] ctrl$cancel() called")
    ctrl$cancel("User interrupted")
  })

  stream <- do.call(chat$stream_async, c(list(full_message), img_parts, list(controller = ctrl)))
  tryCatch(
    for (chunk in coro::await_each(stream)) {
      if (is_cancelled()) {
        message("[INTERRUPT] is_cancelled() TRUE — chunks=", chunk_count)
        break
      }
      chunk_count <- chunk_count + 1L
      on_chunk(chunk)
    },
    error = function(e) {
      if (!is_cancelled()) on_error(conditionMessage(e))
    }
  )

  on_done()

  # ── 对话完成后持久化到 SQLite ─────────────────────────────────────────────
  if (!is_cancelled() && !ctrl$cancelled) {
    tryCatch({
      first_msg <- substr(message, 1, 200)
      title     <- substr(message, 1, 40)
      store$save(thread_id, chat, title = title, first_msg = first_msg)
      message("[SESSION] Saved thread=", thread_id,
              " turns=", length(chat$get_turns()))
    }, error = function(e) {
      message("[SESSION] Save failed: ", conditionMessage(e))
    })
  }

  current$on_tool_call      <- NULL
  current$on_tool_result    <- NULL
  current$wait_for_approval <- NULL
})

# ── UI ───────────────────────────────────────────────────────────────────────
ui <- tagList(
  tags$head(tags$style(HTML("
    html, body { height: 100%; margin: 0; padding: 0; overflow: hidden; }
  "))),
  assistantUIOutput("chat", height = "100vh")
)

# ── Server ────────────────────────────────────────────────────────────────────
server <- function(input, output, session) {
  ctrl <- assistantUIServer(
    "chat",
    handler          = handler,
    show_thread_list = TRUE,

    on_session_load = function(session_id, thread_id, send_thread) {
      # session_id == thread_id（ellmer session 用 thread_id 直接对应 DB 主键）
      saved_state <- store$load(thread_id)
      if (is.null(saved_state)) {
        send_thread(list())
        return()
      }
      # 仅反序列化 turns 用于 UI 显示；tools = list() 因显示不需要工具关联
      turns <- tryCatch({
        state_json <- memDecompress(
          base64enc::base64decode(saved_state$state), asChar = TRUE
        )
        recorded <- jsonlite::unserializeJSON(state_json)
        lapply(recorded, ellmer::contents_replay, tools = list())
      }, error = function(e) {
        message("[SESSION LOAD] Deserialize failed: ", conditionMessage(e))
        list()
      })
      send_thread(ellmer_turns_to_messages(turns))
      message("[SESSION LOAD] Sent ", length(turns), " turns for thread=", thread_id)
    },

    suggestions = list(
      list(prompt = "What's the weather in San Francisco?",
           text   = "What's the weather in SF?"),
      list(prompt = "Calculate the result of 2^10 / 4",
           text   = "Calculate 2^10 / 4")
    ),

    tools = list(
      list(name = "get_weather", description = "Get current weather for a city"),
      list(name = "calculate",   description = "Evaluate a mathematical expression")
    )
  )

  # 启动时注入历史 sessions 到侧边栏
  shiny::observe({
    sessions_data <- tryCatch(
      store$list_sessions(limit = 100L),
      error = function(e) {
        message("[SESSIONS] list_sessions error: ", conditionMessage(e))
        list()
      }
    )
    ctrl$send_sessions(list(sessions = sessions_data))
    message("[SESSIONS] Sent ", length(sessions_data), " sessions to sidebar")
  })
}

shinyApp(ui, server)
