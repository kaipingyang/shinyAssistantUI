# Bug1 / Option 1：@mention 索引现在包含被 gitignore 的内容（如 R_dev/），
# 但排除 node_modules / renv/library 等噪声目录。

make_repo <- function() {
  repo <- normalizePath(tempfile("repo"), winslash = "/", mustWork = FALSE)
  dir.create(repo)
  q <- function(...) suppressWarnings(system2("git", c("-C", shQuote(repo), ...), stdout = FALSE, stderr = FALSE))
  q("init", "-q")
  q("config", "user.email", "t@example.com")
  q("config", "user.name", "t")
  dir.create(file.path(repo, "R"))
  writeLines("x", file.path(repo, "R", "app.R"))                 # tracked
  writeLines(c("R_dev/", "node_modules/", "renv/library/"), file.path(repo, ".gitignore"))
  dir.create(file.path(repo, "R_dev"))
  writeLines("y", file.path(repo, "R_dev", "dev_helper.R"))       # gitignored 但要能搜到
  dir.create(file.path(repo, "node_modules"))
  writeLines("z", file.path(repo, "node_modules", "pkg.js"))      # 噪声，要排除
  dir.create(file.path(repo, "renv", "library"), recursive = TRUE)
  writeLines("w", file.path(repo, "renv", "library", "big.R"))    # 噪声，要排除
  q("add", "R/app.R", ".gitignore")
  q("commit", "-qm", "init")
  repo
}

test_that("index includes gitignored files/folders but excludes noise dirs", {
  skip_if(Sys.which("git") == "", "git not available")
  repo <- make_repo()
  idx <- shinyAssistantUI:::.addin_workspace_index(repo)
  paths <- vapply(idx, `[[`, character(1), "path")

  expect_true("R/app.R" %in% paths)             # 已跟踪
  expect_true("R_dev/dev_helper.R" %in% paths)   # gitignored 文件现在包含
  expect_true("R_dev/" %in% paths)               # 其文件夹被推导
  expect_false(any(grepl("node_modules", paths)))   # 噪声排除
  expect_false(any(grepl("renv/library", paths)))   # 噪声排除
})

test_that("search finds a gitignored dev file by name (underscore ok)", {
  skip_if(Sys.which("git") == "", "git not available")
  repo <- make_repo()
  idx <- shinyAssistantUI:::.addin_workspace_index(repo)
  hits <- shinyAssistantUI:::.addin_workspace_search(idx, "dev_helper", limit = 5)
  expect_true(any(vapply(hits, function(x) grepl("dev_helper.R", x$path), logical(1))))
})

test_that(".addin_fs_walk prunes noise dirs, reaches deep files, and caps at max_files", {
  root <- normalizePath(tempfile("walk"), winslash = "/", mustWork = FALSE)
  dir.create(file.path(root, "a", "b"), recursive = TRUE)
  dir.create(file.path(root, "node_modules"), recursive = TRUE)
  for (i in 1:5) writeLines("x", file.path(root, "a", paste0("f", i, ".R")))
  writeLines("y", file.path(root, "a", "b", "deep.R"))
  writeLines("z", file.path(root, "node_modules", "pkg.js"))
  block_re <- "(^|/)(node_modules)(/|$)"

  all <- shinyAssistantUI:::.addin_fs_walk(root, block_re, 1000L)
  expect_true("a/b/deep.R" %in% all)          # BFS 到达深层文件
  expect_false(any(grepl("node_modules", all)))  # 剪枝
  expect_true(all(grepl("^a/", all)))

  capped <- shinyAssistantUI:::.addin_fs_walk(root, block_re, 2L)
  expect_length(capped, 2L)                    # max_files 封顶
})

test_that("non-git project falls back to a pruned file walk (empty @ index fix)", {
  proj <- normalizePath(tempfile("nogit"), winslash = "/", mustWork = FALSE)
  dir.create(file.path(proj, "R"), recursive = TRUE)
  dir.create(file.path(proj, "node_modules", "pkg"), recursive = TRUE)
  writeLines("x", file.path(proj, "R", "app.R"))
  writeLines("y", file.path(proj, "notes.md"))
  writeLines("z", file.path(proj, "node_modules", "pkg", "index.js"))
  expect_false(dir.exists(file.path(proj, ".git")))          # 确非 git 仓库

  idx <- shinyAssistantUI:::.addin_workspace_index(proj)
  paths <- vapply(idx, `[[`, character(1), "path")
  expect_true("R/app.R" %in% paths)      # 普通文件被索引
  expect_true("notes.md" %in% paths)
  expect_true("R/" %in% paths)           # 文件夹被推导
  expect_false(any(grepl("node_modules", paths)))   # 噪声目录剪枝
})

test_that("search provider memoizes the index within TTL (no per-keystroke git/readRDS)", {
  # Q1 优化 A：同一目录连续按键复用内存索引，不重跑 .addin_workspace_index_cached。
  build_calls <- 0L
  testthat::local_mocked_bindings(
    .addin_workspace_index_cached = function(project, cache_path, max_files = 10000L) {
      build_calls <<- build_calls + 1L
      list(list(kind = "file", path = "R/app.R"))
    }
  )
  provider <- shinyAssistantUI:::.make_addin_workspace_search_provider(
    function() "/tmp/proj", cache_path = tempfile()
  )
  provider("a"); provider("ap"); provider("app")   # 三次连续"按键"
  expect_identical(build_calls, 1L)                 # 只构建一次
})



test_that("workspace provider peek is read-only and never builds a cold index", {
  build_calls <- 0L
  testthat::local_mocked_bindings(
    .addin_workspace_index_cached = function(project, cache_path, max_files = 10000L) {
      build_calls <<- build_calls + 1L
      list(list(kind = "file", path = "subfolder/dm.R"))
    }
  )
  provider <- shinyAssistantUI:::.make_addin_workspace_search_provider(
    function() "/tmp/proj", cache_path = tempfile()
  )
  peek <- attr(provider, "peek_index")

  expect_true(is.function(peek))
  expect_null(peek())
  expect_identical(build_calls, 0L)

  provider("dm")
  expect_identical(build_calls, 1L)
  expect_identical(peek(), list(list(kind = "file", path = "subfolder/dm.R")))
})
