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
