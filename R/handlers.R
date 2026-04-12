#' Ellmer Streaming Handler Factory
#'
#' Creates an `assistantUIServer` handler backed by an `ellmer` chat object,
#' with per-thread conversation history and async streaming support.
#'
#' Each thread gets its own chat object (created on demand via `factory`),
#' so multi-turn conversation context is preserved within a thread across
#' multiple user messages.
#'
#' @param factory A zero-argument function that returns a new `ellmer` chat
#'   object (e.g. `chat_openai_compatible(...)`, `chat_openai(...)`, etc.).
#'   Called once per thread the first time a message arrives on that thread.
#'
#' @return A handler function compatible with [assistantUIServer()], with
#'   signature `function(message, thread_id, on_chunk, on_done, on_error)`.
#'
#' @examples
#' \dontrun{
#' handler <- ellmer_stream_handler(function() {
#'   ellmer::chat_openai_compatible(
#'     base_url    = "https://your-endpoint/v1",
#'     model       = "your-model",
#'     credentials = function() Sys.getenv("DATABRICKS_TOKEN")
#'   )
#' })
#'
#' assistantUIServer("chat", handler = handler, show_thread_list = TRUE)
#' }
#'
#' @export
ellmer_stream_handler <- function(factory) {
  chats <- list()  # thread_id -> ellmer chat object

  function(message, thread_id, on_chunk, on_done, on_error) {
    # 按需创建 chat 对象（第一次访问该线程时）
    if (is.null(chats[[thread_id]])) {
      chats[[thread_id]] <<- factory()
    }
    chat <- chats[[thread_id]]

    # 异步流式调用
    coro::async(function() {
      stream <- chat$stream_async(message, stream = "text")
      coro::for_(chunk %in% stream, {
        on_chunk(chunk)
      })
      on_done()
    })()
  }
}
