# 权限模式两级切换策略(降权/同级热切换,提权/伪模式重连)。实测依据见 Plan 45。

test_that(".permission_switch_strategy: 提权重连,降权/同级热切换", {
  ss <- shinyAssistantUI:::.permission_switch_strategy
  # 提权(变松)→ reconnect
  expect_identical(ss("default", "bypassPermissions"), "reconnect")
  expect_identical(ss("default", "acceptEdits"), "reconnect")
  expect_identical(ss("plan", "default"), "reconnect")
  expect_identical(ss("acceptEdits", "bypassPermissions"), "reconnect")
  # 降权(变严)→ hot
  expect_identical(ss("bypassPermissions", "default"), "hot")
  expect_identical(ss("bypassPermissions", "acceptEdits"), "hot")
  expect_identical(ss("acceptEdits", "default"), "hot")
  expect_identical(ss("default", "plan"), "hot")
  # 同级 → hot
  expect_identical(ss("default", "default"), "hot")
})

test_that(".permission_switch_strategy: 伪模式(askAll/yolo)恒重连", {
  ss <- shinyAssistantUI:::.permission_switch_strategy
  expect_identical(ss("default", "askAll"), "reconnect")   # 进 Strict
  expect_identical(ss("askAll", "default"), "reconnect")   # 出 Strict
  expect_identical(ss("bypassPermissions", "yolo"), "reconnect")  # 进 YOLO
  expect_identical(ss("yolo", "bypassPermissions"), "reconnect")  # 出 YOLO(即便看似降权)
  expect_identical(ss("yolo", "askAll"), "reconnect")
})

test_that(".permission_mode_rank 单调(严→松)", {
  rk <- shinyAssistantUI:::.permission_mode_rank
  expect_true(rk("askAll") < rk("plan"))
  expect_true(rk("plan") < rk("default"))
  expect_true(rk("default") < rk("acceptEdits"))
  expect_true(rk("acceptEdits") < rk("bypassPermissions"))
  expect_true(rk("bypassPermissions") < rk("yolo"))
  expect_identical(rk("nonsense"), rk("default"))  # 未知按 default
})
