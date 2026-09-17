# A2UI over Shiny: future design contract

## Status

> **Future design, not a supported capability.** `shinyAssistantUI` does
> not currently implement A2UI or AG-UI, does not export the proposed R
> callbacks on this page, and does not install an A2UI or AG-UI adapter.
> This contract records the requirements that must be implemented and
> verified before the public status can change.

[A2UI](https://a2ui.org/) is a declarative protocol in which an agent
sends operations that create, update, or delete a UI surface. Components
come from a host-approved catalog; executable React code does not travel
over the wire. The assistant-ui documentation demonstrates these
operations over AG-UI activity snapshots, but the A2UI state reducer and
surface conversion are separable from that transport.

The selected future direction for this package is therefore **A2UI Core
over Shiny**:

  - retain the native Shiny output binding;
  - retain the custom `ExternalStoreRuntime`;
  - carry A2UI operation batches and actions through Shiny inputs and
    custom messages;
  - evaluate the official A2UI reducer/converter as an exact-version
    build dependency;
  - do not require or claim AG-UI compatibility merely to render A2UI
    surfaces.

## P0 contract freeze

**Contract revision:** P0-1. **Frozen:** 2026-09-10.

“Frozen” means that implementation work may rely on the decisions below.
Changing one requires a new documented contract revision and
compatibility review. It does not mean that A2UI is implemented or
supported.

The following decisions are frozen for the first implementation:

1.  A2UI uses the existing Shiny WebSocket transport and custom
    `ExternalStoreRuntime`; AG-UI is not required.
2.  The browser stores surfaces by `(threadId, surfaceId)` and permits
    multiple surfaces in one assistant message.
3.  The wire envelope uses `transportVersion`, `threadId`, optional
    `runId`, stable `eventId`, and a monotonically increasing per-thread
    `sequence`. An R helper may generate transport metadata, but retries
    must be able to reuse `eventId`.
4.  `createSurface` is anchored to the assistant message of an active
    run. Updates and deletion may target that existing surface later.
    Creating a new surface outside a run requires an explicit new
    assistant run rather than an unowned UI message.
5.  The proposed R entry points are `on_a2ui()` for operation batches
    and `a2ui_action_handler` for actions. An action is not converted
    into a user chat message.
6.  A2UI actions use a dedicated data-bearing Shiny input, while
    privileged tool execution continues through the existing tool-call
    approval path.
7.  UI history persists canonical surface snapshots; synthetic render
    parts are excluded from normal agent tool history unless a backend
    receives state through an explicit contract.
8.  Existing Data UI, Generative UI, and `PromptUser` paths remain
    backward compatible and are not replaced by A2UI.
9.  A renderer-only proof of concept cannot change the public status
    from **Future plan**. Lifecycle, action, recovery, security,
    dependency, R, and installed-package browser gates are mandatory.

P0-1 does not freeze the exact dependency version, numeric payload
limits, component styling, or the internal React host used to render
converted Generative UI. Those implementation parameters must be
recorded and tested before code is merged; they cannot weaken the frozen
lifecycle or security requirements.

## Product reason and non-goals

A2UI is not required for the package’s current chat, data cards, JSON
layouts, tool views, or approval forms. It becomes useful when an
application needs at least one of the following:

  - interoperability with a backend that genuinely emits A2UI
    operations;
  - a standard, stateful surface lifecycle rather than one static JSON
    tree;
  - incremental component or data-model updates;
  - portable user actions that identify their surface and source
    component.

Adoption should be driven by one of these requirements, not by the
presence of an upstream documentation page.

The first supported version would **not** imply:

  - an AG-UI runtime or AG-UI backend adapter;
  - replacement of the Shiny transport;
  - remote or model-supplied component code;
  - automatic permission to execute tools or destructive actions;
  - migration or removal of the existing Data UI and Generative UI
    paths.

## Coexistence with current UI paths

The paths have different contracts and should remain available together.

| Path                     | Intended role                                                                     | Current or future state |
| ------------------------ | --------------------------------------------------------------------------------- | ----------------------- |
| Data UI                  | Small R-driven named views such as `table`, `stat`, `flow`, and `action-progress` | Supported now           |
| Generative UI primitive  | A single JSON layout rendered through the local display allowlist                 | Supported now           |
| Tool UI and `PromptUser` | Tool calls, results, form input, and human approval                               | Supported now           |
| A2UI Core over Shiny     | Standard surface operations, data binding, actions, and persisted surface state   | Future design           |
| AG-UI runtime            | AG-UI events, interrupts, state, steering, and run semantics                      | Not adopted             |

A visible converted component is not proof of complete A2UI semantics.
The package must implement the full lifecycle and restore behavior
described below before claiming support.

## Target architecture

``` text
R backend or application handler
  -> proposed on_a2ui(operations, event_id, sequence)
  -> Shiny custom message
  -> thread-scoped surface store
  -> apply validated A2UI operations
  -> convert each surface to a safe Generative UI specification
  -> render through a fixed host component catalog

A2UI component action
  -> fixed action registry
  -> dedicated Shiny input
  -> proposed R a2ui_action_handler()
  -> direct surface update or an application-owned agent continuation
```

A later AG-UI adapter could translate `ACTIVITY_SNAPSHOT` events with
`activityType: "a2ui-surface"` into the same internal operation
envelope. It must not require the core Shiny implementation to replace
`ExternalStoreRuntime`.

## Proposed operation transport

The operation objects should remain standard A2UI data. Shiny-specific
reliability metadata belongs in an outer envelope. The following is a
design sketch, not a currently accepted message:

``` json
{
  "transportVersion": 1,
  "threadId": "thread-1",
  "runId": "run-1",
  "eventId": "event-12",
  "sequence": 12,
  "operations": [
    {
      "version": "v0.9",
      "updateDataModel": {
        "surfaceId": "order-1",
        "path": "/total",
        "contents": "$42"
      }
    }
  ]
}
```

The fields have distinct responsibilities:

  - `transportVersion` versions the package’s Shiny envelope, not the
    A2UI protocol;
  - `threadId` isolates otherwise identical surface IDs in different
    conversations;
  - `runId`, when present, associates creation with the assistant
    message being produced;
  - `eventId` is a stable idempotency key for retry and reconnect
    handling;
  - `sequence` establishes deterministic order within a thread;
  - `operations` contains unmodified A2UI operations.

The initial implementation should publish and test the exact A2UI
protocol versions it accepts. The currently reviewed upstream reducer
accepts v0.9 and v1.0 shapes, but this page does not promise that
support before the dependency and compatibility review is complete.

## Surface identity and lifecycle

A surface is keyed by `(threadId, surfaceId)`. `surfaceId` must
therefore be stable and unique within a thread. The first successful
`createSurface` anchors a surface part to the assistant message for the
active run; later batches update that part in place rather than adding
duplicate messages.

Required operation behavior is:

  - `createSurface` creates or deliberately resets the named surface
    according to the selected A2UI reducer semantics;
  - `updateComponents` upserts validated component records;
  - `updateDataModel` applies a validated JSON Pointer update;
  - `deleteSurface` removes the rendered part and its live state;
  - an update for a missing surface is rejected with a diagnostic rather
    than creating implicit state;
  - unknown operations, unsupported versions, malformed records, and
    unknown components fail softly without crashing the widget.

For delivery reliability:

  - a repeated `eventId` is a no-op;
  - an older sequence is rejected;
  - a sequence gap is observable and requests snapshot recovery rather
    than being silently accepted;
  - state is isolated when the user switches threads;
  - reconnect restores a canonical snapshot before accepting later
    operations.

These Shiny envelope rules supplement A2UI; they do not redefine the
operation payload itself.

## Proposed R contract

An ergonomic sender can follow the existing handler callback style. The
names below are reserved only by this design document and are not
current exports:

``` r
handler <- function(message, on_chunk, on_done, on_a2ui, ...) {
  on_a2ui(
    operations = list(
      list(
        version = "v0.9",
        createSurface = list(surfaceId = "order-1")
      ),
      list(
        version = "v0.9",
        updateDataModel = list(
          surfaceId = "order-1",
          path = "/",
          contents = list(total = "$42")
        )
      )
    ),
    event_id = "order-1-create",
    sequence = 1
  )
  on_done()
}
```

A2UI actions are not ordinary user chat messages. They need a separate
server entry point so an application can update a surface without
fabricating a user bubble, or explicitly choose to continue an agent
run:

``` r
assistantUIServer(
  "chat",
  handler = handler,
  a2ui_action_handler = function(
    action,
    on_a2ui,
    on_chunk,
    on_done,
    on_error
  ) {
    # Validate action$name and action$input.
    # Return operations directly, or explicitly continue the selected backend.
  }
)
```

The action received by R should contain only JSON-safe data with a
documented shape:

``` json
{
  "transportVersion": 1,
  "actionId": "action-uuid",
  "threadId": "thread-1",
  "surfaceId": "order-1",
  "sourceComponentId": "confirm-button",
  "name": "confirm_order",
  "input": {},
  "clientRevision": 12
}
```

`actionId` provides replay protection. `clientRevision` lets R reject an
action from a stale surface. Browser-supplied timestamps, identifiers,
component names, and input remain untrusted.

## Actions are not approvals

An A2UI action records interaction with a surface. It does not authorize
a backend tool. Safe application actions such as changing a filter or
requesting a refreshed calculation may update a surface directly. An
action that would lead to a privileged tool must enter the existing
tool-call and approval flow:

``` text
A2UI action
  -> R/backend decides that a tool is required
  -> normal tool call
  -> existing approval card and policy
  -> approved tool execution
```

The A2UI action bridge must not directly run shell commands, modify
files, call the R console, delete resources, or bypass backend
permission policy. This keeps `PromptUser` and tool approval as the
single authorization path for privileged tool execution, while A2UI has
its own data-bearing interaction path.

## Persistence, history, and replay

Live operation batches are useful for updates, but a replayable event
log alone is not the preferred UI persistence format. The package should
store a canonical, JSON-safe surface snapshot with the UI message
history, conceptually:

``` json
{
  "type": "a2ui-surface",
  "surfaceId": "order-1",
  "revision": 12,
  "components": [],
  "dataModel": {}
}
```

This is a proposed internal message part, not an exported schema. It
establishes these requirements:

1.  history load can reconstruct the surface without re-running the
    agent;
2.  later operations continue from the restored revision;
3.  reconnect does not apply the same batch twice;
4.  delete removes both live state and the persisted UI part;
5.  thread pagination and switching preserve the original message
    anchor.

UI history and agent history are different. A persisted surface is
required to restore the browser, but a synthetic rendering part must not
be misreported to an agent as a genuine backend tool call. If a backend
needs current A2UI state, it should receive that state through an
explicit backend contract rather than accidental transcript
serialization.

## Component and security boundary

The current five-component display allowlist is too narrow for the A2UI
basic catalog. A future implementation needs a dedicated, reviewed A2UI
component library covering the published supported subset. Unknown
components must be dropped or replaced by a non-interactive diagnostic;
they must never trigger dynamic imports or remote code loading.

At minimum, implementation review and tests must cover:

  - no executable component or JavaScript code over the wire;
  - no unrestricted HTML injection;
  - sanitized Markdown and explicit URL schemes;
  - restrictions on image source, size, and data URI types;
  - limits for payload bytes, operations per batch, surfaces per thread,
    component count, tree depth, template expansion, strings, and
    data-model depth;
  - rejection of unsafe JSON Pointer segments such as `__proto__`,
    `prototype`, and `constructor`;
  - validation of component props and user input on both the browser and
    R boundaries;
  - an allowlist of action names, replay protection, stale-revision
    checks, and rate limiting;
  - thread/session ownership checks before applying updates or actions;
  - error containment so one malformed surface cannot crash the chat
    widget.

The converter’s own traversal bounds and warnings are useful defense in
depth, not a substitute for transport limits and application
authorization.

## Dependency and AG-UI decision

The preferred implementation route is to evaluate the official A2UI
reducer/converter from `@assistant-ui/react-generative-ui`, still using
the Shiny transport. If adopted, it must use an exact version compatible
with the installed assistant-ui packages and pass dependency, license,
bundle-size, clean-build, and security review. R package users would
continue to receive compiled assets and would not install npm packages
themselves.

`@assistant-ui/react-ag-ui` is not required for this route and should
remain absent unless a real AG-UI backend requirement is separately
approved. Rendering A2UI operations over Shiny must not be documented as
AG-UI wire compatibility.

If the official converter cannot satisfy the package’s compatibility or
security requirements, a local subset may be considered, but it must be
named and documented as a subset rather than full A2UI support.

## Delivery and support gates

Work should advance through independently verifiable stages:

1.  **Contract prototype:** freeze the envelope, R callback shape,
    message anchoring, action boundary, snapshot format, and published
    component subset.
2.  **Lifecycle proof of concept:** create, update, and delete a surface
    over Shiny without changing existing UI paths.
3.  **Action round trip:** validate an interactive action in R, update
    the surface, and prove that privileged work still uses tool
    approval.
4.  **Persistence and recovery:** save and restore canonical snapshots,
    switch threads, reconnect, deduplicate events, and continue
    revisions.
5.  **Supported capability:** publish APIs only after compatibility,
    security, and installed-package browser gates pass.

Required evidence includes:

  - reducer and converter unit tests for every supported operation and
    protocol version;
  - malformed, oversized, unknown-component, unsafe-URL, unsafe-pointer,
    and stale-action tests;
  - R serialization, callback validation, and handler error tests;
  - event ordering, duplicate delivery, gap recovery, and thread
    isolation tests;
  - history restore followed by a new update and action;
  - proof that synthetic surface parts are excluded from ordinary agent
    tool history;
  - regression tests for Data UI, the existing Generative UI primitive,
    and `PromptUser` approval;
  - a real Chromium test against the installed R package covering
    create, update, action, delete, and history restore with no React
    exception or console error;
  - clean dependency installation, production build, bundle comparison,
    and dependency snapshot verification.

Until all supported-capability gates pass, the public status remains
**Future plan**. A proof of concept may be described as experimental,
but a renderer-only implementation must not be described as A2UI
support.
