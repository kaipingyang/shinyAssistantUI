# ── ellmer chat 状态序列化辅助 ───────────────────────────────────────────────
# 源自 shinychat/client_state.R（MIT License）
# 必须用 serializeJSON/unserializeJSON，toJSON 是有损转换

.ellmer_chat_get_state <- function(chat) {
  recorded   <- lapply(chat$get_turns(), ellmer::contents_record)
  state_json <- jsonlite::serializeJSON(recorded)
  state_str  <- base64enc::base64encode(memCompress(state_json, "gzip"))
  list(version = 1L, state = state_str)
}

.ellmer_chat_set_state <- function(chat, state) {
  state_json     <- memDecompress(base64enc::base64decode(state$state), asChar = TRUE)
  recorded       <- jsonlite::unserializeJSON(state_json)
  replayed_turns <- lapply(recorded, ellmer::contents_replay, tools = chat$get_tools())
  chat$set_turns(replayed_turns)
}

#' SQLite-backed session store for ellmer chats
#'
#' Creates a session store backed by a SQLite database. Supports saving,
#' listing, loading, and deleting per-thread chat state. Designed to be
#' shared across Shiny sessions (app-level singleton).
#'
#' @param db_path Path to the SQLite database file. Parent directory is
#'   created automatically.
#'
#' @return A list with `save`, `list_sessions`, `load`, and `delete` functions.
#'
#' @examples
#' \dontrun{
#' store <- ellmer_session_store(".sessions/chat.db")
#'
#' handler <- make_ellmer_handler(
#'   chat  = function() chat_openai_compatible(...),
#'   store = store
#' )
#' }
#'
#' @export
ellmer_session_store <- function(db_path) {
  dir.create(dirname(db_path), showWarnings = FALSE, recursive = TRUE)
  con <- DBI::dbConnect(RSQLite::SQLite(), db_path, synchronous = "normal")
  DBI::dbExecute(con, "PRAGMA journal_mode = WAL")
  # 多进程并发写（Posit Connect 多 worker 共享同一 .sqlite）时，WAL 允许多读单写，
  # 但写-写仍需排他锁。busy_timeout 让落后的写在锁释放前重试，避免立即 SQLITE_BUSY 丢数据。
  DBI::dbExecute(con, "PRAGMA busy_timeout = 5000")
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS sessions (
      thread_id  TEXT PRIMARY KEY,
      title      TEXT NOT NULL DEFAULT '',
      first_msg  TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      state      TEXT NOT NULL
    )
  ")
  reg.finalizer(environment(), function(e) {
    tryCatch(DBI::dbDisconnect(con), error = function(x) NULL)
  }, onexit = TRUE)

  list(
    save = function(thread_id, chat, title = "", first_msg = "") {
      state     <- .ellmer_chat_get_state(chat)
      state_str <- jsonlite::toJSON(state, auto_unbox = TRUE)
      now       <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
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

    load = function(thread_id) {
      rows <- DBI::dbGetQuery(con,
        "SELECT state FROM sessions WHERE thread_id = ?",
        list(thread_id)
      )
      if (nrow(rows) == 0) return(NULL)
      # 损坏/截断的 state 优雅降级为 NULL，而非崩溃（调用方据此回退新会话）
      tryCatch(
        jsonlite::fromJSON(rows$state[[1]], simplifyVector = FALSE),
        error = function(e) {
          warning("ellmer_session_store: failed to parse state for thread ", thread_id,
                  ": ", conditionMessage(e))
          NULL
        }
      )
    },

    delete = function(thread_id) {
      DBI::dbExecute(con, "DELETE FROM sessions WHERE thread_id = ?", list(thread_id))
    }
  )
}
