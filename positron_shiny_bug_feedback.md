# Positron 升级请求 — Shiny 首次运行不弹出 Viewer 的已知 bug

## 现象

在包含 `devtools::load_all()` 的 R 脚本中运行 Shiny app（全选代码执行），**首次运行时 Viewer 面板不弹出**；Ctrl+C 后重新运行则正常。

**复现步骤**：

1.  打开含 `devtools::load_all()` + `shinyApp(ui, server)` 的 R 脚本
2.  全选代码，执行
3.  Shiny app 开始运行（控制台有输出），但 Viewer 面板不打开
4.  Ctrl+C 停止，再次全选执行 → Viewer 正常弹出

## 根本原因

Positron 的 URL 检测器（`AppUrlDetector`）监听控制台输出，抓取**第一个出现的 URL**作为 app 地址。

`devtools::load_all()` 在加载包时会打印包文档链接（如 `https://deanattali.com/shinyjs/...`），这些 URL **早于** Shiny 的 `Listening on http://127.0.0.1:PORT` 出现，导致检测到错误 URL 或超时失败。

第二次运行时 `load_all()` 有缓存、输出较少，且 Positron console session 已初始化，因此检测成功。

## 参考

-   GitHub issue：[posit-dev/positron #13229](https://github.com/posit-dev/positron/issues/13229)（已关闭，标记为 bug）
-   关联 PR：[posit-dev/shiny-vscode #108](https://github.com/posit-dev/shiny-vscode/pull/108)（2026-03-31 合并）

## 修复版本

已在 **Positron 2026.05.0**（2026年5月4日发布）中修复。

修复方案：重构 Shiny 运行机制，为每个 Shiny app 创建独立的 sidecar console session，彻底隔离 `devtools::load_all()` 等前置代码的输出流，URL 检测不再受干扰。

## 请求

请将 Posit Workbench 上的 Positron 升级至 **2026.05.0 或更新版本**。

------------------------------------------------------------------------

*临时 workaround（升级前可用）：分两步执行，先运行除最后一行外的所有代码，再单独执行 `shinyApp(ui, server)`。*