#' Declare how a tool call's arguments are rendered in the chat card
#'
#' Builds the `argsView` tool-call annotation that tells the widget how to render
#' a tool call's **arguments** (the region an approver reads), instead of the raw
#' JSON fallback. This is the server-side (R) extension point for tools whose
#' semantics only the author knows — primarily [ellmer::tool()] tools (whose
#' `annotations` are forwarded automatically by [make_ellmer_handler()]) and any
#' custom `handler` that emits `on_tool_call(annotations = ...)`.
#'
#' Claude Code's fixed built-in tools (`Bash`, `Edit`, `Write`, `run_r`, ...) are
#' rendered by built-in rules on the client and do **not** need this.
#'
#' The return value is a plain list; merge it into a tool call's annotations, e.g.
#' `on_tool_call(id, name, args, annotations = assistant_tool_view("code",
#' field = "code", lang = "r"))`, or `c(other_annotations, assistant_tool_view(...))`.
#'
#' @param kind The view kind: `"code"` (syntax-highlighted code block) or
#'   `"diff"` (old/new unified diff).
#' @param field For `kind = "code"`: the argument name holding the code string.
#'   Defaults to `"code"` on the client when omitted.
#' @param lang For `kind = "code"`: the syntax-highlighting language (e.g. `"r"`,
#'   `"sql"`, `"bash"`, `"python"`). Falls back to a neutral language when omitted.
#' @param old_field,new_field,file_field For `kind = "diff"`: the argument names
#'   holding the old text, new text, and file name. Default to `"old_string"`,
#'   `"new_string"`, and `"file_path"` on the client when omitted.
#'
#' @return A named list `list(argsView = <spec>)` suitable for a tool call's
#'   `annotations`.
#'
#' @examples
#' # Render a tool's `code` argument as an R code block:
#' assistant_tool_view("code", field = "code", lang = "r")
#'
#' # A SQL tool whose query lives in the `sql` argument:
#' assistant_tool_view("code", field = "sql", lang = "sql")
#'
#' # A custom edit-style tool rendered as a diff:
#' assistant_tool_view("diff", old_field = "before", new_field = "after")
#'
#' \dontrun{
#' # With ellmer: declare the view in the tool's annotations (forwarded to the card).
#' ellmer::tool(
#'   run_sql,
#'   description = "Run a SQL query",
#'   arguments   = list(sql = ellmer::type_string("SQL to run")),
#'   annotations = assistant_tool_view("code", field = "sql", lang = "sql")
#' )
#' }
#' @export
assistant_tool_view <- function(kind = c("code", "diff"),
                                field = NULL, lang = NULL,
                                old_field = NULL, new_field = NULL,
                                file_field = NULL) {
  kind <- match.arg(kind)
  chk <- function(x, nm) {
    if (!is.null(x) && !(is.character(x) && length(x) == 1L)) {
      stop("`", nm, "` must be a single string or NULL.", call. = FALSE)
    }
  }
  chk(field, "field"); chk(lang, "lang")
  chk(old_field, "old_field"); chk(new_field, "new_field")
  chk(file_field, "file_field")

  view <- list(kind = kind)
  if (identical(kind, "code")) {
    if (!is.null(field)) view$field <- field
    if (!is.null(lang)) view$lang <- lang
  } else {
    # camelCase 对齐客户端 ArgsViewHint(resolve.ts)。
    if (!is.null(old_field)) view$oldField <- old_field
    if (!is.null(new_field)) view$newField <- new_field
    if (!is.null(file_field)) view$fileField <- file_field
  }
  list(argsView = view)
}


# 计算 Edit 工具 old_string 在文件中的 1-based 起始行,供工具卡 diff 显示真实行号。
# 找不到(如历史 edit 已应用、文件缺失)→ NULL,前端退回从 1 计数。内部函数,不导出。
.tool_edit_start_line <- function(file_path, old_string, base_dir = NULL) {
  if (!is.character(file_path) || length(file_path) != 1L || !nzchar(file_path)) return(NULL)
  if (!is.character(old_string) || length(old_string) != 1L || !nzchar(old_string)) return(NULL)
  path <- file_path
  if (!file.exists(path) && !is.null(base_dir) && nzchar(base_dir)) {
    cand <- file.path(base_dir, file_path)
    if (file.exists(cand)) path <- cand
  }
  if (!file.exists(path)) return(NULL)
  info <- tryCatch(file.info(path), error = function(e) NULL)
  if (is.null(info) || is.na(info$size) || info$size > 5e6) return(NULL)  # 5MB 守卫
  flines <- tryCatch(readLines(path, warn = FALSE), error = function(e) NULL)
  if (is.null(flines) || !length(flines)) return(NULL)
  olines <- strsplit(old_string, "\n", fixed = TRUE)[[1]]
  n <- length(olines)
  if (!n || n > length(flines)) {
    # 单行退化匹配
    hit <- which(flines == olines[[1]])
    return(if (length(hit)) hit[[1]] else NULL)
  }
  # 滑窗匹配整段 old_string
  for (i in seq_len(length(flines) - n + 1L)) {
    if (identical(flines[i:(i + n - 1L)], olines)) return(i)
  }
  # 退化:匹配首行
  hit <- which(flines == olines[[1]])
  if (length(hit)) hit[[1]] else NULL
}
