# shinyreact 对 shinyAssistantUI 接入 A2UI 的架构调查

**调查日期：2026-09-16**
**调查对象：** `posit-dev/shinyreact`、A2UI v0.9 React renderer、`shinyAssistantUI` 当前架构
**结论状态：** 调查完成；尚未实施依赖或生产迁移

## 1. 执行摘要

`posit-dev/shinyreact` 对 `shinyAssistantUI` 接入 A2UI 有明显参考价值。它系统性解决了 React 前端与 Shiny reactive server 之间的输入、输出、消息、模块 namespace、bookmark hydration、连接状态和协议治理问题，验证了我们此前“React 拥有 UI，R 负责计算和后端状态”的总体方向。

但 `shinyreact` 不是 A2UI renderer，也不是 React 组件库。它面向 **whole-page React client**，而 `shinyAssistantUI` 当前的重要能力之一是作为 native Shiny output 嵌入任意 Shiny/bslib 页面。整体迁移会破坏这一兼容边界，也无法替代 assistant-ui 的 `ExternalStoreRuntime`、thread/history、streaming、tool call、approval、attachment 和 task 协议。

因此推荐：

1. **近期：**直接在现有 `shinyAssistantUI` runtime 中接入 `@a2ui/react/v0_9` 与 `@a2ui/web_core/v0_9`。
2. **同时借鉴：**采用 shinyreact 的 protocol manifest、跨语言 fixture、registry、namespace、bookmark/init hydration 和 wire-level testing。
3. **中期：**增加可选的 shinyreact standalone page adapter，与现有 `assistantUIOutput()` 并存。
4. **暂不：**整体替换当前 output binding、bridge 或 `ExternalStoreRuntime`。

## 2. 调查范围与方法

本次只读检查了：

- `posit-dev/shinyreact`：README、DESIGN、FEATURES、wire protocol、surface manifest、R page/render/message/bookmark 实现、JS hooks/registry/lifecycle 文档与相关 issues。
- A2UI：项目 README、v0.9 React renderer、MessageProcessor、Surface、Catalog、Generic Binder、action/data-model 设计与项目状态。
- `shinyAssistantUI`：`AssistantUI → useShinyRuntime → createShinyBridge` 调用链、native output binding、generative UI channel、thread-scoped callback routing和已有 allowlist。

没有修改或安装 `shinyreact`/A2UI 依赖。

## 3. shinyreact 的定位

### 3.1 核心模型

shinyreact 实现 `ui.tsx-first` 架构：

```text
React client owns the full UI
        │
        ├── useShinyInput / useSetShinyInput
        ├── useShinyOutputValue / status / error
        └── useShinyMessageHandler
        │
Shiny websocket
        │
R/Python server owns reactive computation and data
```

服务器不描述运行时 UI tree，仅提供数据与后端计算。客户端是静态 React 应用，UI layout、component tree、styling 和纯客户端交互均在 client 中完成。

### 3.2 主要能力

| 能力 | shinyreact 实现 | 对我们的价值 |
|---|---|---|
| Client→server | `useShinyInput()`、`useSetShinyInput()` | A2UI action/form event 可复用该模型 |
| Server→client data | `reactive_output()`、`useShinyOutputValue()` | 适合初始 snapshot/data model hydration |
| Server push | `send_message()`、`useShinyMessageHandler()` | 适合有序 A2UI 消息 transport |
| Output lifecycle | pending/ready/recalculating/error | 可驱动 skeleton、stale 和 error UI |
| Connection lifecycle | initialized/busy hooks | 避免过早注册和错误 readiness 假设 |
| Module namespace | `ShinyModuleProvider`、`session$ns()` | 可隔离 module/thread/surface |
| Bookmark restore | config JSON tag → input registry hydration | 可借鉴历史 surface 恢复 |
| Shared React | React 19 由 bundle 提供并允许 externalize | 避免重复 React runtime |
| Traditional output escape hatch | `ShinyOutput`、`ImageOutput` | 支持局部嵌入传统输出 |
| Protocol governance | `1.0`、`surface.json`、shared fixtures | 强烈值得采用 |
| Testing | JS unit、Python E2E、R wire/unit、`wire_tap()` | 可补强我们的跨端协议证据 |

### 3.3 重要设计取舍

shinyreact 的设计原则与我们的既有判断高度重合：

- UI lives on the client；
- server 只参与数据、模型、凭据和昂贵计算；
- communication bridge 应小且显式；
- client-side visual interaction 不应往返 server；
- build step 是真实存在的，但应由工具管理；
- AI 可以直接生成 React UI，而不是让 AI 先生成 R/Python UI wrappers；
- generated client 必须通过 type check、browser E2E、安全与可访问性验证。

值得注意的是，shinyreact 曾有 server-described JSON wire tree 方向，但当前已收敛为 ui.tsx-first；动态 UI renderer 不再由 shinyreact 本身提供。

## 4. shinyreact 当前成熟度与限制

截至 2026-09-16：

| 项目 | 状态 |
|---|---|
| Lifecycle | Experimental |
| Wire protocol | `1.0`，client 比较 major version |
| 仓库规模 | 约 192 commits、24 open issues、9 stars |
| R/Python/JS parity | 有 feature tree 和 parity fixtures |
| R browser E2E | 尚缺，issue #194 |
| Protocol surface | 已增加 `surface.json`，此前发生过 scope drift，issue #232 |
| UI components | 不提供 |
| Dynamic agent UI | 不提供 |
| Whole-page React | 主要目标 |
| Embedded React widget | 不是主要目标 |

风险主要是：项目仍在快速演进，R E2E 尚未补齐；若把核心 package 直接绑定到 shinyreact 的 whole-page lifecycle，升级风险会传导到现有用户。

## 5. A2UI v0.9 的定位

A2UI 是 agent-generated declarative UI protocol，而不是 Shiny transport。当前生产系列为 v0.9.x，v1.0 specification 处于 release-candidate 阶段，整体仍是 early-stage public preview。

核心对象：

- **MessageProcessor**：处理 agent 发来的有序 JSON messages。
- **Surface**：独立 UI rendering area，以 `surfaceId` 标识。
- **Catalog**：允许 agent 使用的可信组件与 logic function 集合。
- **Data model**：surface 的 reactive 数据。
- **Generic Binder**：解析 dynamic values、setter、actions 和 validation。
- **A2uiSurface**：React renderer。

典型消息：

```text
createSurface
updateComponents
updateDataModel
deleteSurface
```

A2UI v0.9 React renderer 已支持：

- typed Zod component schemas；
- automatic dynamic binding；
- two-way data model；
- action context；
- reactive validation；
- custom catalogs/functions；
- multi-surface；
- basic layout/content/input catalog。

## 6. shinyreact 与 A2UI 的职责边界

```text
A2UI
  = agent UI protocol
  + MessageProcessor
  + Surface/data model
  + trusted Catalog
  + React renderer

shinyreact
  = React client 与 Shiny R/Python reactive server 的通用 bridge
```

组合关系：

```text
Agent / R handler
      │
      │ ordered A2UI messages
      ▼
Shiny transport
  ├── current shinyAssistantUI bridge
  └── optional future shinyreact hooks
      │
      ▼
A2UI MessageProcessor
      │
      ▼
A2uiSurface + shinyAssistant Catalog
```

安装 shinyreact 不会自动获得 A2UI；安装 A2UI renderer 也不会自动处理 Shiny sessions、history 或 agent backend。

## 7. 与 shinyAssistantUI 当前架构的对照

当前调用链：

```text
AssistantUI
  → useShinyRuntime
    → createShinyBridge
      → Shiny custom messages / inputs
```

当前 bridge 已承担：

- per-thread streaming callback routing；
- chunk/done/error/thinking；
- tool call/result/delta；
- history/session restore；
- approval、task、rate limit、status；
- workspace、attachments、IDE context；
- diagnostics/settings/memory protocols；
- `:data-ui` 与 `:generative-ui` channels。

这些是 chat/agent domain protocol，不是 shinyreact 的通用 hooks 能替代的。

### 7.1 高度重叠处

| 当前实现 | shinyreact 对应设计 |
|---|---|
| custom-message registration | `useShinyMessageHandler` + registry |
| Shiny input calls | `useSetShinyInput` |
| readiness logic | `useShinyInitialized` |
| global busy signal | `useShinyBusy` |
| thread/widget namespacing | `ShinyModuleProvider` / resolved ids |
| early-message buffering | registry/init hydration |
| protocol tests | `surface.json` + fixtures |
| initial restore | bookmark config hydration |

### 7.2 不重叠处

| shinyAssistantUI 能力 | shinyreact 是否提供 |
|---|---|
| assistant-ui `ExternalStoreRuntime` | 否 |
| thread repository/history | 否 |
| Claude/ellmer streaming adapter | 否 |
| tool approvals/task cards | 否 |
| agent run correlation | 否 |
| A2UI processor/catalog | 否 |
| artifact/tool result rendering | 否 |
| RStudio addin integration | 否 |

## 8. 是否整体迁移到 shinyreact

### 不建议近期整体迁移

原因：

1. shinyreact 主要拥有整个 page，当前 package 需要嵌入任意 Shiny/bslib 页面。
2. `assistantUIOutput()` 是现有公开兼容契约；替换为 `page_react()` 会是 breaking change。
3. 大部分复杂度位于 assistant-ui runtime 和 agent domain，不在底层 Shiny handler registration。
4. npm build 使用独立安装的 shinyreact client 时要求 protocol config tag；在传统嵌入页面中不能假设存在。
5. shinyreact 与 A2UI 都处于实验/演进期，双重核心依赖会放大升级风险。
6. R browser E2E 尚未完善，而我们的 addin 对真实 Chromium/history path 有更严格要求。

### 可考虑的未来模式

增加可选 standalone adapter，而非替换：

```r
assistantUIReactPage(...)
```

或项目模板：

```text
app.R
src/ui.tsx
www/ui.js
```

该模式使用 shinyreact page/hooks，但与 `assistantUIOutput()` 并存。

## 9. 推荐的 A2UI 接入架构

### 9.1 第一阶段：现有 runtime 内直接嵌入

保留：

```text
assistantUIOutput()
assistantUIServer()
createShinyBridge()
ExternalStoreRuntime
```

引入：

```text
@a2ui/web_core/v0_9
@a2ui/react/v0_9
```

升级现有 generative channel 为严格消息协议，例如：

```ts
interface A2UIBatch {
  version: 1;
  threadId: string;
  surfaceId: string;
  revision: number;
  messages: A2UIMessage[];
}
```

要求：

- exact schema；
- per-thread/per-surface monotonic revision；
- stale/duplicate rejection；
- bounded messages/components/depth/data bytes；
- remount hydration；
- owner cleanup；
- no raw executable code。

### 9.2 Transport 建议

- **Initial/full snapshot：**可以使用 server-authoritative snapshot 思路，类似 `reactive_output`。
- **Streaming A2UI patches：**继续使用 ordered custom messages。

不建议用 reactive output 发送每个 patch，因为 reactive invalidation 可能合并中间状态；A2UI incremental processor 需要明确顺序和 revision。

### 9.3 Trusted Catalog

第一批仅允许：

| 类别 | 组件 |
|---|---|
| Layout | Row、Column、Card、Divider、Tabs |
| Content | Text、Markdown、Badge、Progress |
| Data | Table、KeyValue |
| Input | Button、TextField、ChoicePicker |
| Feedback | Alert、Result |

默认禁止：

- arbitrary HTML；
- script/style injection；
- agent 指定任意 React component；
- 未审计 iframe/webview；
- 非 allowlisted URL scheme；
- 未注册 action/function；
- 无限制 component count/depth/data model。

### 9.4 Action 回传

建议 exact action envelope：

```ts
interface A2UIActionRequest {
  version: 1;
  threadId: string;
  surfaceId: string;
  surfaceRevision: number;
  actionId: string;
  sourceComponentId: string;
  context: Record<string, SafeScalar | SafeScalar[]>;
}
```

R 端只处理 allowlisted action。action 必须与当前 thread/surface revision 匹配，防止历史或 stale surface 的按钮执行。

### 9.5 History 与恢复

每个 thread 保存：

```text
catalog id/version
surface snapshot or canonical message log
data model
latest revision
terminal/deleted state
```

恢复顺序：

1. 创建 processor；
2. 注册 trusted catalog；
3. hydrate snapshot；
4. 完成 owner binding；
5. 开始接收 live messages；
6. 只接受更高 revision。

## 10. 最值得借鉴的 shinyreact 工程设计

### 10.1 Surface manifest

为 `shinyAssistantUI` 建立类似 `protocol/surface.json`：

```text
custom messages
input ids
input handler suffixes
DOM contract ids
protocol versions
```

新增/改名必须触发 parity test，并显式判断是否需要 major bump。

### 10.2 Shared fixtures

同一 fixture 由 R 与 JS 分别解析/序列化：

```text
A2UI batch
A2UI action
surface snapshot
history hydration
malformed/hostile corpus
```

防止字段名、类型和 optional semantics 漂移。

### 10.3 Registry 与 stable handlers

复用 shinyreact 的思路：

- 每个 message type 注册一个全局 Shiny handler；
- handler 内路由到当前 owner/subscriber；
- React remount 不重复注册不可移除 handler；
- handler ref 更新不触发 deregister/re-register；
- late message 经 owner/revision 拒绝。

### 10.4 Namespace 与 lifecycle

- module/thread/surface 使用明确 namespace；
- initialized 前不发送；
- initial hydration 先于 live stream；
- unmount 清 subscriber，不清其他 surface；
- output status/error 与 A2UI surface fallback 对齐。

### 10.5 Wire-level browser testing

补充：

- transport payload tap；
- R/JS parity；
- bookmark/history hydration；
- output pending/recalculating/error；
- remount/late message；
- multi-surface isolation；
- browser console/runtime/network 0 error；
- malformed/oversize/hostile agent payload。

## 11. 分阶段实施建议

### Phase 0：协议治理，不引入 A2UI dependency

- 建立 surface manifest；
- 给现有 `:generative-ui` 定 version/revision envelope；
- shared R/JS fixtures；
- 固定 size/depth/count limits；
- browser hostile corpus。

**价值：**低风险，立即改善当前自定义 generative UI。

### Phase 1：只读 A2UI POC

- feature flag；
- 单 thread、单 surface；
- Text/Card/Column/Markdown/Table；
- 无 input/action/two-way binding；
- 使用 hardcoded fixtures，不接真实 LLM；
- 测 bundle 增量与 render 性能。

**成功条件：**history restore、streaming update、remount、privacy、zero browser errors。

### Phase 2：受控 Actions 与 Data Model

- Button/TextField/ChoicePicker；
- exact action envelope；
- server allowlist；
- stale revision rejection；
- optimistic state仅限 client-safe field；
- approval/危险 action 仍走现有 permission channel。

### Phase 3：多 surface 与 history

- thread-scoped processor registry；
- surface create/update/delete；
- canonical snapshot persistence；
- archived/deleted thread cleanup；
- bounded processor memory。

### Phase 4：可选 shinyreact standalone adapter

- 新示例或独立 API；
- 使用 shinyreact hooks/page；
- 与 embedded output A/B 验证；
- 共享同一 A2UI catalog/processor adapter；
- 不废弃现有 API。

## 12. 风险矩阵

| 风险 | 级别 | 缓解 |
|---|---:|---|
| A2UI v1前协议变化 | 高 | versioned imports、adapter layer、feature flag |
| shinyreact experimental | 中高 | 不作为近期核心依赖 |
| bundle size增加 | 中 | POC 实测、tree shaking、lazy surface chunk |
| duplicate React/runtime | 高 | externalization/peer alignment验证 |
| streaming顺序/丢patch | 高 | custom message + revision + snapshot recovery |
| agent payload XSS/DoS | 高 | strict catalog、limits、sanitization、no raw HTML |
| history schema迁移 | 高 | versioned persisted snapshot与migration fixtures |
| multi-thread串线 | 高 | threadId+surfaceId+owner+revision |
| R/Shiny remount lifecycle | 中高 | registry + ready handshake + browser tests |
| R E2E依赖shinyreact缺口 | 中 | 保持我们自己的Chromium gate |

## 13. 采用决策矩阵

| 方案 | 建议 | 理由 |
|---|---|---|
| 整体迁移到底层 shinyreact | 暂不采用 | breaking、embeddability损失、收益不足 |
| 直接引入 A2UI React renderer | 强烈建议做 POC | 最短路径、保持现有成熟能力 |
| 借鉴 shinyreact protocol/registry/tests | 立即采用 | 高收益、低耦合 |
| `reactive_output` 发送初始 snapshot | 建议 | server-authoritative hydration |
| `reactive_output` 发送每个 streaming patch | 不建议 | ordering/coalescing 风险 |
| shinyreact standalone adapter | 中期建议 | 验证未来 whole-page 模式且不破坏现有用户 |

## 14. 建议的下一步

优先创建独立 A2UI POC 计划，范围严格限制为：

1. protocol manifest 与 R/JS shared fixture；
2. `@a2ui/react/v0_9` bundle/React compatibility spike；
3. 单 surface、只读 basic catalog；
4. 现有 `:generative-ui` channel adapter；
5. history restore 与 real Chromium；
6. bundle size、render latency、memory benchmark；
7. 不修改现有默认 UI，不发布到 Shared/Stable。

只有 POC 证明 React singleton、bundle、history、streaming和安全边界均可控后，再进入 actions/two-way data model。

## 15. 主要来源

- shinyreact repository: <https://github.com/posit-dev/shinyreact>
- shinyreact DESIGN: <https://github.com/posit-dev/shinyreact/blob/main/DESIGN.md>
- shinyreact FEATURES: <https://github.com/posit-dev/shinyreact/blob/main/FEATURES.md>
- shinyreact protocol: <https://github.com/posit-dev/shinyreact/blob/main/protocol/README.md>
- shinyreact protocol surface: <https://github.com/posit-dev/shinyreact/blob/main/protocol/surface.json>
- shinyreact R package: <https://github.com/posit-dev/shinyreact/tree/main/pkg-r>
- shinyreact JS API: <https://posit-dev.github.io/shinyreact/js/>
- shinyreact comparison: <https://posit-dev.github.io/shinyreact/articles/comparison.html>
- R E2E gap, issue #194: <https://github.com/posit-dev/shinyreact/issues/194>
- protocol surface governance, issue #232: <https://github.com/posit-dev/shinyreact/issues/232>
- A2UI repository: <https://github.com/google/A2UI>
- A2UI React renderer: <https://github.com/google/A2UI/tree/main/renderers/react>

---

**最终建议：**保留 `shinyAssistantUI` 当前 embeddable runtime，直接做 A2UI v0.9 renderer POC；将 shinyreact 视为协议、registry、namespace、hydration和测试设计的上游参考，并为未来 whole-page 模式保留可选 adapter，而不是现在重写底座。
