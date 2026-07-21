# RStudio addin — workspace (@mention) file/folder index & fuzzy search
# 从 addin.R 拆出（Plan 16 Phase 2，行为不变）：git-aware 索引、缓存、模糊搜索 provider。
# `%||%` / `.atomic_save_rds` 见 handlers.R / 其它包内文件。

# git ls-files -z 的 NUL-safe 解码。system2(stdout=TRUE) 按行读取会破坏含换行的
# 合法文件名，因此先写 raw 临时文件再按 NUL 切分。
.read_nul_paths <- function(path) {
  size <- file.info(path)$size
  if (is.na(size) || size <= 0) return(character(0))
  raw <- readBin(path, what = "raw", n = size)
  ends <- which(raw == as.raw(0L))
  if (!length(ends)) return(character(0))
  starts <- c(1L, head(ends, -1L) + 1L)
  keep <- ends > starts
  vapply(which(keep), function(i) rawToChar(raw[starts[[i]]:(ends[[i]] - 1L)]), character(1))
}

# 构建 tracked + untracked、遵守 gitignore/global excludes 的 workspace index。
# 非 Git 项目诚实返回空列表，不用 list.files() 冒充 ignore-aware 结果。
.addin_workspace_index <- function(project, max_files = 10000L) {
  if (Sys.which("git") == "" || is.null(project) || !dir.exists(project)) return(list())
  project <- normalizePath(project, mustWork = TRUE)
  out <- tempfile("claude-workspace-", fileext = ".nul")
  err <- tempfile("claude-workspace-", fileext = ".err")
  on.exit(unlink(c(out, err)), add = TRUE)
  status <- suppressWarnings(tryCatch(
    system2(
      "git",
      c("-C", shQuote(project), "ls-files", "-z", "--cached", "--others", "--exclude-standard"),
      stdout = out, stderr = err
    ),
    error = function(e) 1L
  ))
  if (!identical(as.integer(status), 0L)) return(list())

  files <- .read_nul_paths(out)
  files <- gsub("\\\\", "/", files)
  files <- files[nzchar(files) & !grepl("^(?:/|[A-Za-z]:|\\.\\.(?:/|$))", files)]
  files <- head(sort(unique(files)), max(0L, as.integer(max_files)))

  # 文件夹推导：先收集到 list（避免循环内 c() 的 O(n^2) 累加），最后一次 unique。
  folder_lists <- lapply(files, function(file) {
    acc <- character(0)
    parent <- dirname(file)
    while (!identical(parent, ".") && nzchar(parent)) {
      acc <- c(acc, paste0(parent, "/"))
      next_parent <- dirname(parent)
      if (identical(next_parent, parent)) break
      parent <- next_parent
    }
    acc
  })
  folders <- sort(unique(unlist(folder_lists, use.names = FALSE)))
  c(
    lapply(folders, function(path) list(kind = "folder", path = path)),
    lapply(files, function(path) list(kind = "file", path = path))
  )
}

# git HEAD 指纹（用于 workspace 索引缓存失效）。非 git/detached/空仓返回 NULL → 不缓存。
.addin_git_head <- function(project) {
  if (Sys.which("git") == "" || is.null(project) || !dir.exists(project)) return(NULL)
  head <- suppressWarnings(tryCatch(
    system2("git", c("-C", shQuote(project), "rev-parse", "HEAD"),
            stdout = TRUE, stderr = FALSE),
    error = function(e) character(0)
  ))
  head <- head[nzchar(head)]
  if (!length(head)) NULL else head[[1L]]
}

# 带缓存的 workspace 索引：按 normalizePath(project)+git HEAD 缓存到 home 的 rds。
# 命中直接读，HEAD 变化或非 git 时重建（非 git 不写缓存）。
.addin_workspace_index_cached <- function(project, cache_path, max_files = 10000L) {
  head <- .addin_git_head(project)
  key <- tryCatch(normalizePath(project, winslash = "/", mustWork = FALSE),
                  error = function(e) as.character(project))
  if (!is.null(head) && file.exists(cache_path)) {
    store <- tryCatch(readRDS(cache_path), error = function(e) list())
    entry <- if (is.list(store)) store[[key]] else NULL
    if (is.list(entry) && identical(entry$head, head) && is.list(entry$index)) {
      return(entry$index)
    }
  }
  index <- .addin_workspace_index(project, max_files = max_files)
  if (!is.null(head)) {
    store <- if (file.exists(cache_path)) tryCatch(readRDS(cache_path), error = function(e) list()) else list()
    if (!is.list(store)) store <- list()
    store[[key]] <- list(head = head, index = index)
    tryCatch(.atomic_save_rds(store, cache_path), error = function(e) NULL)
  }
  index
}

.addin_fuzzy_match <- function(needle, haystack) {
  if (!nzchar(needle)) return(TRUE)
  chars <- strsplit(needle, "", fixed = TRUE)[[1L]]
  text <- strsplit(haystack, "", fixed = TRUE)[[1L]]
  pos <- 1L
  for (ch in chars) {
    if (pos > length(text)) return(FALSE)
    found <- which(text[seq.int(pos, length(text))] == ch)
    if (!length(found)) return(FALSE)
    pos <- pos + found[[1L]]
  }
  TRUE
}

.addin_mention_insert_text <- function(path) {
  if (grepl("[[:space:]]", path)) paste0('@"', gsub('"', '\\"', path, fixed = TRUE), '"')
  else paste0("@", path)
}

# 确定性 fuzzy 排序：basename prefix/substring > path prefix/substring >
# subsequence；同分时浅层路径、folder、短路径、字典序优先。
.addin_workspace_search <- function(index, query = "", kinds = c("file", "folder"), limit = 50L) {
  query <- tolower(trimws(query %||% ""))
  kinds <- intersect(as.character(kinds %||% c("file", "folder")), c("file", "folder"))
  if (!length(kinds)) return(list())
  candidates <- Filter(function(x) is.list(x) && x$kind %in% kinds && nzchar(x$path %||% ""), index)
  scored <- lapply(candidates, function(item) {
    path <- tolower(item$path)
    base <- tolower(basename(sub("/$", "", item$path)))
    score <- if (!nzchar(query)) 0L
      else if (startsWith(base, query)) 0L
      else if (grepl(query, base, fixed = TRUE)) 1L
      else if (startsWith(path, query)) 2L
      else if (grepl(query, path, fixed = TRUE)) 3L
      else if (.addin_fuzzy_match(query, base)) 4L
      else if (.addin_fuzzy_match(query, path)) 5L
      else Inf
    if (!is.finite(score)) return(NULL)
    depth <- lengths(regmatches(item$path, gregexpr("/", item$path, fixed = TRUE)))
    c(item, list(
      label = basename(sub("/$", "", item$path)),
      insertText = .addin_mention_insert_text(item$path),
      .score = score, .depth = depth
    ))
  })
  scored <- Filter(Negate(is.null), scored)
  if (!length(scored)) return(list())
  ord <- order(
    vapply(scored, `[[`, numeric(1), ".score"),
    vapply(scored, `[[`, integer(1), ".depth"),
    vapply(scored, function(x) if (identical(x$kind, "folder")) 0L else 1L, integer(1)),
    vapply(scored, function(x) nchar(x$path), integer(1)),
    vapply(scored, `[[`, character(1), "path")
  )
  result <- head(scored[ord], max(1L, min(100L, as.integer(limit %||% 50L))))
  lapply(result, function(x) x[setdiff(names(x), c(".score", ".depth"))])
}

.make_addin_workspace_search_provider <- function(project, cache_path = NULL) {
  cache_path <- cache_path %||% file.path(
    Sys.getenv("HOME", unset = "~"), ".claude_addin_workspace_cache.rds")
  # project 可为字符串（固定）或函数（动态当前工作目录）。每次查询按当前目录取带缓存的索引，
  # 从而工作目录切换后 @mention 搜索自动跟随。
  dir_provider <- if (is.function(project)) project else function() project
  function(query = "", kinds = c("file", "folder"), limit = 50L) {
    index <- .addin_workspace_index_cached(dir_provider(), cache_path)
    .addin_workspace_search(index, query = query, kinds = kinds, limit = limit)
  }
}
