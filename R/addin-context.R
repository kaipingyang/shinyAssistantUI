# RStudio addin — IDE/editor context & file navigation helpers
# 从 addin.R 拆出（Plan 16 Phase 2，行为不变）：相对路径、在编辑器打开文件、
# 活动编辑器上下文采样、上下文文本拼接。`%||%` 见 handlers.R。

# 绝对路径 → 相对项目根(fixed=TRUE 避免正则/Windows 元字符问题;项目外则保留绝对)。
.rel_path <- function(path, project) {
  if (is.null(path) || !nzchar(path) || is.null(project) || !nzchar(project)) return(path)
  p  <- tryCatch(normalizePath(path, mustWork = FALSE),    error = function(e) path)
  pr <- tryCatch(normalizePath(project, mustWork = FALSE), error = function(e) project)
  pr_slash <- if (endsWith(pr, .Platform$file.sep)) pr else paste0(pr, .Platform$file.sep)
  if (startsWith(p, pr_slash)) substring(p, nchar(pr_slash) + 1L) else p
}

# 活动编辑器上下文:list(path, rel, selection, first_line, last_line) 或 NULL。全程 guard。
# 解析点击的文件引用。先走 cwd/显式路径快路径；裸名 miss 后只读取已经热过的
# workspace memo（peek 不得触发索引构建），唯一 basename 命中才使用。其余静默。
.addin_resolve_file_path <- function(path, project = NULL, workspace_index_peek = NULL) {
  if (!is.character(path) || length(path) != 1L || !nzchar(path)) return(NULL)
  is_absolute <- startsWith(path, "/") || grepl("^[A-Za-z]:", path) || startsWith(path, "\\\\")
  candidate <- path
  if (!is_absolute && !is.null(project) && nzchar(project)) candidate <- file.path(project, path)
  candidate <- tryCatch(normalizePath(candidate, winslash = "/", mustWork = FALSE),
                        error = function(e) candidate)
  if (file.exists(candidate)) return(candidate)

  is_bare <- !is_absolute && !grepl("[/\\\\]", path)
  if (!is_bare || is.null(project) || !is.function(workspace_index_peek)) return(NULL)
  index <- tryCatch(workspace_index_peek(), error = function(e) NULL)
  if (!is.list(index)) return(NULL)
  hits <- Filter(function(x) {
    is.list(x) && identical(x$kind, "file") && is.character(x$path) &&
      length(x$path) == 1L && nzchar(x$path) &&
      identical(basename(gsub("\\\\", "/", x$path)), path) &&
      !startsWith(x$path, "/") && !grepl("^[A-Za-z]:|^\\.\\.(?:[/\\\\]|$)", x$path)
  }, index)
  if (length(hits) != 1L) return(NULL)

  resolved <- file.path(project, hits[[1L]]$path)
  resolved <- tryCatch(normalizePath(resolved, winslash = "/", mustWork = FALSE),
                       error = function(e) resolved)
  project_norm <- tryCatch(normalizePath(project, winslash = "/", mustWork = FALSE),
                           error = function(e) project)
  project_prefix <- paste0(sub("/+$", "", project_norm), "/")
  if (!startsWith(resolved, project_prefix) || !file.exists(resolved)) return(NULL)
  resolved
}

# 点击文件引用 / Claude 编辑后揭示 → 在 RStudio 编辑器打开。
# RStudio 可用性已在 addin 启动时计算为 native_picker；这里不再为每次点击重复 RPC。
.addin_open_file <- function(path, line = NULL, project = NULL, workspace_index_peek = NULL) {
  if (!requireNamespace("rstudioapi", quietly = TRUE)) return(invisible(NULL))
  abs_path <- .addin_resolve_file_path(path, project, workspace_index_peek)
  if (is.null(abs_path)) return(invisible(NULL))

  # 已聚焦同一文件则不跳转
  current <- tryCatch(rstudioapi::getSourceEditorContext()$path, error = function(e) NULL)
  if (!is.null(current) && nzchar(current)) {
    current_norm <- tryCatch(normalizePath(current, winslash = "/", mustWork = FALSE),
                             error = function(e) current)
    if (identical(current_norm, abs_path)) return(invisible(NULL))
  }

  ln <- suppressWarnings(as.integer(line))
  if (length(ln) != 1L || is.na(ln) || ln < 1L) ln <- -1L
  tryCatch(rstudioapi::navigateToFile(abs_path, line = ln), error = function(e) NULL)
  invisible(NULL)
}

# 编辑前保存：判定活动文档是否该保存。有路径 + 有 doc id → 返回 id；untitled（无路径）→ NULL
# （不保存，避免 documentSave 弹"另存为"阻塞 gadget）。纯函数，便于单测。
.addin_savable_doc_id <- function(ctx) {
  if (is.null(ctx)) return(NULL)
  path <- tryCatch(ctx$path, error = function(e) "")
  if (is.null(path) || !nzchar(path)) return(NULL)
  id <- tryCatch(ctx$id, error = function(e) NULL)
  if (is.null(id) || !nzchar(id %||% "")) return(NULL)
  id
}

# 提交前保存活动编辑器文档（有路径的），让 Claude 的 Edit/Write 基于最新已保存内容、
# 且不丢用户未保存改动。untitled 脚本跳过。全程 guard，非 RStudio 为 no-op。
.addin_save_dirty_docs <- function() {
  if (!requireNamespace("rstudioapi", quietly = TRUE) ||
      !isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE), error = function(e) FALSE))) return(invisible(NULL))
  ctx <- tryCatch(rstudioapi::getSourceEditorContext(), error = function(e) NULL)
  id <- .addin_savable_doc_id(ctx)
  if (!is.null(id)) tryCatch(rstudioapi::documentSave(id), error = function(e) NULL)
  invisible(NULL)
}

# 无选区时的光标上下文：取 contents 中光标行 ±radius 的窗口。纯函数，便于单测。
.addin_cursor_window <- function(contents, row, radius = 10L) {
  if (!length(contents)) return(NULL)
  row <- suppressWarnings(as.integer(row))
  if (length(row) != 1L || is.na(row)) return(NULL)
  n <- length(contents)
  row <- max(1L, min(row, n))
  lo <- max(1L, row - as.integer(radius))
  hi <- min(n, row + as.integer(radius))
  list(start_line = lo, end_line = hi, cursor_line = row,
       text = paste(contents[lo:hi], collapse = "\n"))
}

# 只采样第一段 selection，确保文本与行范围属于同一个选区。
.addin_editor_context <- function(project = NULL) {
  if (!requireNamespace("rstudioapi", quietly = TRUE) ||
      !isTRUE(tryCatch(rstudioapi::isAvailable(child_ok = TRUE), error = function(e) FALSE))) return(NULL)
  ctx <- tryCatch(rstudioapi::getSourceEditorContext(), error = function(e) NULL)
  if (is.null(ctx)) return(NULL)
  path <- tryCatch(ctx$path, error = function(e) "")
  if (is.null(path) || !nzchar(path)) path <- NULL
  ranges <- tryCatch(ctx$selection, error = function(e) NULL)
  sel <- ""; a <- NULL; b <- NULL
  if (length(ranges)) {
    first <- ranges[[1L]]
    sel <- tryCatch(first$text %||% "", error = function(e) "")
    rg <- tryCatch(first$range, error = function(e) NULL)
    if (!is.null(rg)) { a <- tryCatch(rg$start[[1]], error = function(e) NULL)
                        b <- tryCatch(rg$end[[1]],   error = function(e) NULL) }
  }
  if (is.null(path) && !nzchar(sel)) return(NULL)
  # 无选区时补光标位置 + 周围窗口，让"这里是啥/解释一下"在未选中时也有定位。
  cursor <- NULL
  if (!nzchar(sel) && !is.null(a)) {
    contents <- tryCatch(ctx$contents, error = function(e) NULL)
    if (length(contents)) cursor <- .addin_cursor_window(contents, a, radius = 10L)
  }
  list(path = path, rel = if (!is.null(path)) .rel_path(path, project) else NULL,
       selection = if (nzchar(sel)) sel else NULL, first_line = a, last_line = b,
       cursor_line = if (!is.null(cursor)) cursor$cursor_line else NULL,
       cursor_text = if (!is.null(cursor)) cursor$text else NULL,
       cursor_start = if (!is.null(cursor)) cursor$start_line else NULL,
       cursor_end = if (!is.null(cursor)) cursor$end_line else NULL)
}

# 纯函数:把编辑器上下文拼成要 append 到 Claude Code 预设提示词的文本。
# selection 截断到 ~4000 字符,避免提示词膨胀。
.addin_context_text <- function(ctx, project) {
  lines <- c(paste0("You are assisting a user inside the RStudio IDE.",
                    " Project root (your working directory): ", project, "."))
  if (!is.null(ctx)) {
    if (!is.null(ctx$rel))
      lines <- c(lines, paste0("The user's active editor file is `", ctx$rel, "`."))
    if (!is.null(ctx$selection)) {
      sel <- ctx$selection
      if (nchar(sel) > 4000L) sel <- paste0(substr(sel, 1L, 4000L), "\n... (truncated)")
      loc <- if (!is.null(ctx$first_line) && !is.null(ctx$last_line))
        paste0(" (lines ", ctx$first_line, "-", ctx$last_line, ")") else ""
      lines <- c(lines,
                 paste0("They have selected this code", loc, ":\n```\n", sel, "\n```"))
    }
  }
  lines <- c(lines,
             paste0("Use your file tools (Read/Edit/Bash/Grep) on the project as needed;",
                    " prefer paths relative to the project root."))
  paste(lines, collapse = "\n")
}
