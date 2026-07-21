# 存储整合到 ~/.claude_addin/ 目录（原来散落 $HOME 根的 .claude_addin_*.rds）+ 旧文件迁移。

test_that(".claude_addin_path 指向 ~/.claude_addin/<name>", {
  home <- tempfile("home"); dir.create(home)
  expect_identical(shinyAssistantUI:::.claude_addin_path("projects.rds", home),
                   file.path(home, ".claude_addin", "projects.rds"))
})

test_that(".migrate_addin_storage 把旧 dotfile 搬进新目录、保内容、不覆盖已存在", {
  home <- tempfile("home"); dir.create(home)
  saveRDS(c("/p/a"), file.path(home, ".claude_addin_projects.rds"))
  saveRDS(list(t1 = "sid"), file.path(home, ".claude_addin_session_map.rds"))

  shinyAssistantUI:::.migrate_addin_storage(home)

  dir <- file.path(home, ".claude_addin")
  expect_true(dir.exists(dir))
  expect_identical(readRDS(file.path(dir, "projects.rds")), c("/p/a"))
  expect_identical(readRDS(file.path(dir, "session_map.rds")), list(t1 = "sid"))
  # 旧文件已移走
  expect_false(file.exists(file.path(home, ".claude_addin_projects.rds")))

  # 新文件已存在时不覆盖
  saveRDS(c("/new"), file.path(dir, "projects.rds"))
  saveRDS(c("/old"), file.path(home, ".claude_addin_projects.rds"))
  shinyAssistantUI:::.migrate_addin_storage(home)
  expect_identical(readRDS(file.path(dir, "projects.rds")), c("/new"))   # 未被旧值覆盖
})
