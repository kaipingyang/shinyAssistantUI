# A2UI 接入 Generative UI：架构讨论稿

> 状态：讨论文档，不是实现说明。创建于 2026-09-11。
>
> 公开契约 `vignettes/a2ui-shiny-contract.Rmd` 已冻结为 P0-1，但 A2UI 仍是
> **Future plan**，当前没有运行时支持，也没有新增 JavaScript 依赖。

## 1. 已冻结的 P0-1 边界

以下内容已经冻结，后续修改需要新的契约版本：

1. 保留 native Shiny output binding、Shiny WebSocket transport 和自定义
   `ExternalStoreRuntime`；A2UI 不要求 AG-UI。
2. surface 由 `(threadId, surfaceId)` 标识，同一 assistant message 可包含多个 surface。
3. transport envelope 使用 `transportVersion`、`threadId`、可选 `runId`、稳定
   `eventId` 和 thread 内单调递增的 `sequence`。
4. `createSurface` 必须锚定到 active run 的 assistant message；已有 surface 可在之后更新
   或删除。run 外创建新 surface 必须显式启动新的 assistant run。
5. 拟议 R 入口为 `on_a2ui()` 和 `a2ui_action_handler`；A2UI action 不是 user chat
   message。
6. A2UI action 使用独立的 Shiny input；需要权限的工具仍走现有 tool approval。
7. UI history 保存 canonical surface snapshot；synthetic render part 不冒充 agent tool call。
8. 现有 Data UI、Generative UI primitive 和 `PromptUser` 保持兼容，不由 A2UI 替换。
9. 仅有 renderer 的 PoC 不能改为 Supported；生命周期、action、恢复、安全、依赖、R
   测试和 installed-package 浏览器测试都是支持门槛。

P0-1 没有冻结精确依赖版本、数值型资源限制、组件样式或内部 React host。这些是本讨论要
继续决定的实现参数。

## 2. 名称冲突：当前其实有两种“Generative UI”

### 2.1 当前包使用的是 assistant-ui core primitive

本地链路是：

```text
R on_generative_ui(spec)
  -> :generative-ui custom message
  -> bridge.onGenerativeUi({ spec })
  -> runtime 在 active assistant message 末尾追加 part
       { type: "generative-ui", spec }
  -> thread.tsx
       <MessagePrimitive.GenerativeUI
         components={shinyAllowlist}
         Fallback={GenerativeUiFallback}
       />
```

当前 wire shape 是：

```json
{
  "root": {
    "component": "Card",
    "props": { "title": "Example" },
    "children": []
  }
}
```

当前 `shinyAllowlist` 是 plain React component registry，只包含：

```text
Card, Stack, Heading, Text, Stat
```

它是 display-only 路径，没有 `$action`、`$dispatch`、ActionRegistry、surface reducer 或
incremental lifecycle。

### 2.2 A2UI converter 面向的是 @assistant-ui/react-generative-ui IR

上游 `convertSurfaceToUISpec()` 输出 flat IR：

```json
{
  "$type": "Card",
  "title": "Example",
  "children": [
    {
      "$type": "Button",
      "label": "Confirm",
      "$action": {
        "type": "a2ui:action",
        "name": "confirm",
        "surfaceId": "surface-1",
        "sourceComponentId": "confirm-button"
      }
    }
  ]
}
```

它需要：

```text
renderGenerativeUI(node, GenerativeUILibrary, { status, dispatch })
createActionRegistry({ "a2ui:action": handler })
```

`GenerativeUILibrary` 的每个 entry 包含 description、Zod properties schema 和 render
function，不是 plain `ComponentType`。

因此 converter 结果不能直接交给当前 `MessagePrimitive.GenerativeUI`：schema、registry
shape 和 action semantics 都不同。

## 3. 上游 A2UI conversion 的实际范围

当前审阅的 reducer 支持：

```text
createSurface
updateComponents
updateDataModel
deleteSurface
```

并接受 v0.9/v1.0 operation shape。converter 将 basic catalog 映射为：

| A2UI component | Generative UI IR |
|---|---|
| Text | Markdown / Header / Caption |
| Image | Image |
| Row | Row |
| Column | Col |
| Card | Card |
| Divider | Divider |
| Button | Button + `$action` |
| TextField | Input |
| CheckBox | Checkbox |
| template children | ListView / ListViewItem |

converter 提供 cycle、depth、node budget 和 template expansion 防护，但 transport payload、
surface 数量、字符串、URL、Markdown、action replay 和应用授权仍需本包验证。

## 4. 三种接入策略

### 方案 A：把 A2UI IR 转回当前 legacy spec

```text
A2UI operations
  -> converter flat IR
  -> 再转成 {component, props, children}
  -> MessagePrimitive.GenerativeUI
```

问题：

- `$action` 没有标准 dispatcher；
- 需要把行为塞进普通 props，形成自有协议；
- `GenerativeUILibrary` schema/streaming 语义丢失；
- 等于先转换一次，再逆向降级；
- 容易出现“能显示但不具备 A2UI semantics”的假支持。

结论：不推荐。

### 方案 B：合成 `present` tool call

这接近官方 AG-UI adapter：每个 surface 变成一个 `a2ui:` 前缀的 synthetic `present`
tool-call part，由 `JSONGenerativeUI.present()` 渲染。

优点：与官方 AG-UI 展示路径接近。

问题：

- 当前 Shiny runtime 没有 Toolkit registration contract；
- 会把纯 UI state 引入 tool grouping、tool history 和 tool ID 规则；
- 必须过滤 synthetic calls，避免发回 backend；
- 可能与真实名为 `present` 的 backend tool 冲突；
- 为了 A2UI 引入并不需要的 frontend-tool semantics。

结论：只有未来真的接入 AG-UI runtime 时再考虑；A2UI over Shiny 不采用。

### 方案 C：专用 A2UI surface host，直接调用低层 Generative UI renderer

```text
on_a2ui operations
  -> A2uiSurfaceController
  -> applyA2uiOperations()
  -> canonical snapshot
  -> convertSurfaceToUISpec()
  -> A2uiSurfaceRenderer
       renderGenerativeUI(spec, a2uiLibrary, {
         status: "done",
         dispatch: a2uiActionRegistry.dispatch
       })
```

这复用上游真正需要的 reducer、converter、renderer 和 action registry，但不实例化
`JSONGenerativeUI.present()`，也不制造 tool call。

结论：推荐。

## 5. message part 如何承载 surface

这里还有两个内部实现选择，P0-1 尚未冻结。

### 5.1 真正增加 `type: "a2ui-surface"`

语义最清楚，但 assistant-ui core 的 `ThreadMessagePart` union 当前没有这个类型。必须先证明
`ExternalStoreRuntime`、history conversion、pagination 和 message primitives 会完整保留未知
part；否则未知 part 可能在 normalization 时丢失。

### 5.2 使用已支持的 `generative-ui` part 作为容器，但走专用 render branch

概念形状：

```json
{
  "type": "generative-ui",
  "id": "a2ui:surface-1",
  "spec": {
    "root": {
      "component": "__A2uiSurfaceSnapshot",
      "props": {
        "surfaceId": "surface-1",
        "revision": 12,
        "components": [],
        "dataModel": {}
      }
    }
  }
}
```

`thread.tsx` 不把这类内部 part 交给 `MessagePrimitive.GenerativeUI`，而是检测受控 marker、
重新验证 snapshot，再调用 `A2uiSurfaceRenderer`。普通 `on_generative_ui()` 创建的 part 没有
内部 `a2ui:` part ID，因此继续走原 renderer。

优点：

- 使用 core 已支持和可持久化的 part 类型；
- stable `id` 可用于原位 update/delete；
- canonical snapshot 是 JSON-safe；
- 不把内部 host 暴露给普通 `shinyAllowlist`。

风险：

- history 是不可信输入，不能只凭 `id` prefix 就信任 snapshot；
- wrapper 是本包内部 persistence schema，需要版本字段；
- 必须证明 edit/reload/history pagination 不会破坏锚点。

当前推荐先验证 5.2；如果 core 确认支持扩展 part，再评估 5.1。两者都不改变公开 R contract。

## 6. 推荐的内部模块边界

```text
srcjs/a2ui/protocol.ts
  envelope/action/snapshot runtime validation

srcjs/a2ui/store.ts
  per-thread sequence/event dedupe/surface anchors/reducer integration

srcjs/a2ui/converter.ts
  applyA2uiOperations + convertSurfaceToUISpec adapter and warnings

srcjs/a2ui/library.tsx
  reviewed A2UI-only GenerativeUILibrary

srcjs/a2ui/surface-renderer.tsx
  renderGenerativeUI + action registry + error boundary

srcjs/a2ui/history.ts
  snapshot serialization, restore, prompt-history exclusion
```

bridge 只负责 JSON-safe transport；runtime 负责把 surface snapshot 原位写入正确 assistant
message；renderer 不拥有 transport state。

## 7. 组件库不能直接复用现有 shinyAllowlist

当前五个组件名称和 A2UI converter 输出不一致：

```text
Stack != Row/Col
Heading != Header
Text != Markdown/Caption
Stat 不是 A2UI basic catalog
```

推荐建立单独的 `a2uiLibrary`，仅暴露 converter 可产生的 keys：

```text
Markdown, Header, Caption, Image,
Row, Col, Card, Divider,
Button, Input, Checkbox,
ListView, ListViewItem
```

视觉 primitive 可以共享，但 registry 和安全权限不能共享。

也不应整体暴露 `defaultGenerativeUILibrary`。默认库还包括 media、fact、form、data、alert、
icon 等 vocabulary；例如 `Card.background` 接受任意 CSS background，Image/Markdown 也需要
URL 和内容安全审查。第一版应 pick/override 确认过的基本组件。

## 8. Action 接入 Shiny

converter 生成的 action payload 为：

```json
{
  "type": "a2ui:action",
  "name": "confirm",
  "surfaceId": "surface-1",
  "sourceComponentId": "button-1",
  "context": {}
}
```

host 注册唯一 action type：

```text
createActionRegistry({
  "a2ui:action": ({ payload }) => bridge.sendA2uiAction(...)
})
```

bridge 再增加：

```text
sendA2uiAction(actionId, threadId, surfaceId, revision, payload)
  -> ${inputId}_a2ui_action
```

发送前必须验证：

- payload surfaceId 与当前 host 相同；
- sourceComponentId 存在于当前 revision；
- action name 在应用允许范围内；
- `actionId` 未处理；
- revision 不是 stale；
- payload 和 `$input` 在大小限制内。

R handler 收到 action 后可以：

1. 返回新的 `on_a2ui()` operations；或
2. 显式启动一次没有新 user bubble 的 agent continuation；或
3. 如果需要工具权限，产生正常 tool call 并进入既有 approval。

A2UI action 本身绝不等于工具批准。

## 9. 一个重要的上游交互缺口：表单值并不会自动完整工作

当前 converter 只把 `$action` 放到 Button 上。TextField/CheckBox 被转换为 Input/Checkbox，
但没有 action；Button 普通点击只发送自己的 action payload，不会收集旁边输入框的值。

`@assistant-ui/react-generative-ui` 的表单收集依赖 `Card(asForm = TRUE)` 或 Form + submit
button；而当前 A2UI Card converter 没有映射 `asForm`/confirm。即使 Button 映射了
`submit = TRUE`，没有 ancestor form 时也不能收集字段。

因此第一版不能笼统声称“支持交互表单”。需要在下面两条中选择：

### 范围 1：display + stateless Button actions

- 支持 surface lifecycle、展示组件和 Button action；
- TextField/CheckBox 暂不进入 supported catalog，或明确为无提交语义的实验组件；
- 最接近上游当前 converter 的可靠能力，风险最低。

### 范围 2：实现 host-managed binding/draft state

- 保留 A2UI component ID 和 binding JSON Pointer；
- Input/Checkbox 更新 client draft data model；
- action 携带受限的 `$input` 或 data-model delta；
- R 返回 authoritative `updateDataModel` 进行 reconcile；
- 需要 stale revision、validation、cancel/reset 和 history 语义。

这比“加几个组件”复杂得多，应单独形成第二阶段契约，不能用启发式把所有 Card 强制改成
form。

当前建议：P1 先选择范围 1，完整表单作为 P2 单独设计。

## 10. 是否迁移现有 on_generative_ui()

`renderGenerativeUI()` 的 normalizer 可以理解 legacy `component` node，因此理论上可以把
现有 `spec.root` 改由新 renderer 渲染。但首次 A2UI 实现不建议同时迁移：

- unknown component 的行为会从可见 fallback 变成 drop + dev console error；
- plain component registry 要改成带 Zod schema 的 GenerativeUILibrary；
- 需要证明当前视觉、children、unknown fallback 和 client history 完全兼容；
- A2UI 本身已经有 lifecycle/action/history 风险，不应同时扩大回归面。

推荐迁移边界：

- `on_generative_ui()` + `MessagePrimitive.GenerativeUI` 保持不变；
- A2UI 使用独立 `A2uiSurfaceRenderer`；
- 二者只共享无状态视觉 primitives 和安全工具；
- A2UI 稳定后，再通过单独 RFC 评估统一 renderer。

## 11. 需要下次继续讨论的决策

1. 是否批准精确固定 `@assistant-ui/react-generative-ui`，而不是维护本地 protocol subset？
2. 第一版选择 display + Button actions，还是必须同时完成双向表单 binding？
3. 内部 message part 先使用 core-recognized `generative-ui` container，还是验证真正扩展 part？
4. safe A2UI library 是 pick/override upstream vocabulary，还是完全使用本地视觉实现？
5. action continuation 的 backend-neutral R contract 如何表达“直接更新”和“启动 agent run”？
6. canonical snapshot 由 client persistence 保存、由 R session store 保存，还是两边都保存并定义
   authoritative source？
7. P1 是否允许只标 Experimental；哪些完整 gates 达成后才改为 Supported？

## 12. 当前推荐摘要

```text
A2UI protocol/lifecycle
  -> official reducer + converter
  -> dedicated A2UI GenerativeUILibrary
  -> renderGenerativeUI()
  -> Shiny-specific action registry
  -> existing Shiny transport
```

不使用 AG-UI runtime，不合成 `present` tool call，不把 converter 结果塞给当前 core primitive，
不替换现有 Data UI/Generative UI/PromptUser，不在完整恢复和安全测试前声称支持。
