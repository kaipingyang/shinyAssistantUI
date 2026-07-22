# RStudio addin — workspace (@mention) file/folder index & fuzzy search
# 从 addin.R 拆出（Plan 16 Phase 2，行为不变）：git-aware 索引、缓存、模糊搜索 provider。
# `%||%` / `.atomic_save_rds` 见 handlers.R / 其它包内文件。

# @mention 索引默认排除的"噪声大户"目录（Option 1：展示所有含 gitignore 的内容，
# 但跳过这些包缓存/依赖目录，否则会卡顿）。未来可由 Settings 自定义。
.WORKSPACE_BLOCK_DIRS <- c(
  "node_modules", ".Rproj.user", "__pycache__", ".venv", "venv", ".cache",
  ".quarto", "_freeze", ".pytest_cache", ".mypy_cache", ".ruff_cache",
  ".ipynb_checkpoints", "renv/library", "renv/staging", "renv/cellar",
  "packrat/lib", "packrat/src", ".git"
)

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
# 非 git 回退：剪枝式 BFS 文件遍历。跳过隐藏项(all.files=FALSE → .git/.Rproj.user 等)
# 与 blocklist 大户(node_modules/renv/library…),封顶 max_files。
# 性能：出队用索引指针(避免 queue[-1] 整段复制)、文件结果收进 list 最后一次 unlist
# (避免 out<-c(out,..) 的 O(n^2))、time_budget 兜底极端超大非黑名单目录。
.addin_fs_walk <- function(root, block_re, max_files, time_budget = 2) {
  root_pref <- paste0(sub("/+$", "", root), "/")
  queue <- root
  qi <- 1L                       # 索引指针出队：O(1),不复制
  collected <- list()            # 每目录文件收进 list,末尾 unlist：O(n)
  n_files <- 0L
  deadline <- Sys.time() + time_budget
  while (qi <= length(queue) && n_files < max_files && Sys.time() < deadline) {
    d <- queue[[qi]]; qi <- qi + 1L
    entries <- list.files(d, all.files = FALSE, full.names = TRUE, no.. = TRUE)
    if (!length(entries)) next
    rel <- sub(root_pref, "", entries, fixed = TRUE)
    keep <- !grepl(block_re, rel)          # 剪枝：blocklist 目录/文件不入队、不收
    if (!any(keep)) next
    entries <- entries[keep]; rel <- rel[keep]
    isdir <- dir.exists(entries)
    fh <- rel[!isdir]
    if (length(fh)) {
      collected[[length(collected) + 1L]] <- fh
      n_files <- n_files + length(fh)
    }
    sd <- entries[isdir]
    if (length(sd)) queue <- c(queue, sd)  # 入队次数 = 目录数(远少于文件),可接受
  }
  head(unlist(collected, use.names = FALSE), max(0L, as.integer(max_files)))
}

.addin_workspace_index <- function(project, max_files = 10000L) {
  if (is.null(project) || !dir.exists(project)) return(list())
  project <- normalizePath(project, mustWork = TRUE)
  # 黑名单正则：git 结果兜底过滤 + 非 git 遍历时剪枝,两处共用。
  block_re <- paste0("(^|/)(",
                     paste(gsub(".", "\\.", .WORKSPACE_BLOCK_DIRS, fixed = TRUE), collapse = "|"),
                     ")(/|$)")

  files <- NULL
  if (Sys.which("git") != "") {
    out <- tempfile("claude-workspace-", fileext = ".nul")
    err <- tempfile("claude-workspace-", fileext = ".err")
    on.exit(unlink(c(out, err)), add = TRUE)
    # Option 1：包含被 gitignore 的内容（去掉 --exclude-standard），用 pathspec 让 git
    # 直接跳过"噪声大户"（不遍历 → 快）；R 侧再用黑名单兜底保证正确。
    pathspecs <- unlist(lapply(.WORKSPACE_BLOCK_DIRS, function(d)
      c(shQuote(paste0(":(exclude,glob)", d, "/**")),
        shQuote(paste0(":(exclude,glob)**/", d, "/**")))), use.names = FALSE)
    status <- suppressWarnings(tryCatch(
      system2(
        "git",
        c("-C", shQuote(project),
          # 共享盘上仓库常属于别的用户 → git "dubious ownership" 会拒绝。对只读查询放行；
          # 同时禁用 fsmonitor,堵掉 safe.directory=* 下恶意仓库经 fsmonitor 钩子执行代码的向量。
          "-c", shQuote("safe.directory=*"), "-c", shQuote("core.fsmonitor=false"),
          "ls-files", "-z", "--cached", "--others", pathspecs),
        stdout = out, stderr = err
      ),
      error = function(e) 1L
    ))
    if (identical(as.integer(status), 0L)) files <- .read_nul_paths(out)
  }
  # 无 git / 非 git 仓库 / ls-files 失败 → 剪枝遍历回退（普通文件夹也能 @ 搜）。
  if (is.null(files)) files <- .addin_fs_walk(project, block_re, max_files)

  files <- gsub("\\\\", "/", files)
  files <- files[nzchar(files) & !grepl("^(?:/|[A-Za-z]:|\\.\\.(?:/|$))", files)]
  files <- files[!grepl(block_re, files)]
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
    system2("git", c("-C", shQuote(project), "-c", shQuote("safe.directory=*"),
                     "rev-parse", "HEAD"),
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
# 向量化实现（Q1 优化 C+D）：整列小写 + 向量化 startsWith/grepl，fuzzy 只对未命中子集，
# 去掉 per-item lapply 与 5×vapply 排序，重项目下每次按键的搜索成本大幅下降。
.addin_workspace_search <- function(index, query = "", kinds = c("file", "folder"), limit = 50L) {
  query <- tolower(trimws(query %||% ""))
  kinds <- intersect(as.character(kinds %||% c("file", "folder")), c("file", "folder"))
  if (!length(kinds)) return(list())
  cand <- Filter(function(x) is.list(x) && x$kind %in% kinds && nzchar(x$path %||% ""), index)
  n <- length(cand)
  if (!n) return(list())

  paths <- vapply(cand, function(x) x$path, character(1))
  lpath <- tolower(paths)
  lbase <- tolower(basename(sub("/$", "", paths)))
  score <- rep(Inf, n)

  if (!nzchar(query)) {
    score[] <- 0L
  } else {
    hit <- startsWith(lbase, query);                 score[hit] <- pmin(score[hit], 0L)
    rem <- is.infinite(score) & grepl(query, lbase, fixed = TRUE); score[rem] <- 1L
    rem <- is.infinite(score) & startsWith(lpath, query);         score[rem] <- 2L
    rem <- is.infinite(score) & grepl(query, lpath, fixed = TRUE); score[rem] <- 3L
    # fuzzy（subsequence）最贵 —— 只对仍未命中的子集逐项算
    idx_rem <- which(is.infinite(score))
    if (length(idx_rem)) {
      fb <- vapply(idx_rem, function(i) .addin_fuzzy_match(query, lbase[i]), logical(1))
      score[idx_rem[fb]] <- 4L
      idx_rem2 <- idx_rem[!fb]
      if (length(idx_rem2)) {
        fp <- vapply(idx_rem2, function(i) .addin_fuzzy_match(query, lpath[i]), logical(1))
        score[idx_rem2[fp]] <- 5L
      }
    }
  }

  keep <- which(is.finite(score))
  if (!length(keep)) return(list())
  kpaths <- paths[keep]
  depth <- nchar(gsub("[^/]", "", kpaths))                 # "/" 个数 = 路径深度（向量化）
  folder_first <- vapply(cand[keep], function(x) if (identical(x$kind, "folder")) 0L else 1L, integer(1))
  ord <- order(score[keep], depth, folder_first, nchar(kpaths), tolower(kpaths))
  cap <- max(1L, min(100L, as.integer(limit %||% 50L)))
  sel <- keep[ord][seq_len(min(length(ord), cap))]
  lapply(sel, function(i) {
    x <- cand[[i]]
    list(
      kind = x$kind,
      path = x$path,
      label = basename(sub("/$", "", x$path)),
      insertText = .addin_mention_insert_text(x$path)
    )
  })
}

.make_addin_workspace_search_provider <- function(project, cache_path = NULL) {
  cache_path <- cache_path %||% .claude_addin_path("workspace_cache.rds")
  # project 可为字符串（固定）或函数（动态当前工作目录）。每次查询按当前目录取带缓存的索引，
  # 从而工作目录切换后 @mention 搜索自动跟随。
  dir_provider <- if (is.function(project)) project else function() project
  # Q1 优化 A：内存级 memo。同一目录 head_ttl 秒内的连续按键直接复用内存索引，
  # 跳过每键的 git rev-parse 子进程 + readRDS 磁盘反序列化（重项目的主要卡顿源）。
  memo <- new.env(parent = emptyenv())
  head_ttl <- 5
  get_index <- function(dir) {
    now <- as.numeric(Sys.time())
    entry <- get0(dir, envir = memo, inherits = FALSE)
    if (is.list(entry) && (now - entry$checked_at) < head_ttl) return(entry$index)  # 纯内存命中
    head <- .addin_git_head(dir)
    if (is.list(entry) && identical(entry$head, head)) {                            # HEAD 未变 → 复用，免 readRDS
      assign(dir, list(index = entry$index, head = head, checked_at = now), envir = memo)
      return(entry$index)
    }
    idx <- .addin_workspace_index_cached(dir, cache_path)                            # 真正重建/读盘（少见）
    assign(dir, list(index = idx, head = head, checked_at = now), envir = memo)
    idx
  }
  function(query = "", kinds = c("file", "folder"), limit = 50L) {
    index <- get_index(dir_provider())
    .addin_workspace_search(index, query = query, kinds = kinds, limit = limit)
  }
}
