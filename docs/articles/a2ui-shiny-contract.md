# Experimental A2UI over Shiny

## Status

> **Experimental capability.** `shinyAssistantUI` accepts a reviewed
> subset of A2UI v0.9 and v0.9.1 operations over the existing Shiny
> WebSocket transport. It is not an AG-UI runtime, client, or server,
> and it does not replace the package’s custom `ExternalStoreRuntime`.

[A2UI](https://a2ui.org/) is declarative: a backend sends operations
that create, update, or delete UI surfaces from a host-approved
component catalog. Executable React code does not travel over the wire.
This package bundles the exact-version assistant-ui reducer/converter
and a fixed renderer in its compiled assets; R package users do not
install npm packages.

The implemented architecture is **A2UI Core over Shiny**:

``` text
R handler
  -> on_a2ui(operations, event_id, sequence)
  -> strict R validation + per-thread sequencer/ledger
  -> Shiny custom message
  -> strict browser validation + transactional reducer
  -> standard assistant-ui present tool part
  -> fixed local component library

A2UI action
  -> dedicated Shiny input
  -> current surface/epoch/revision/action checks
  -> a2ui_action_handler()
  -> optional on_a2ui() update
```

A standard AG-UI `ACTIVITY_SNAPSHOT` can enter the same authority
through `on_ag_ui_activity()` or `send_ag_ui_activity()`. This is an
event adapter only; other AG-UI run, message, state, interrupt,
steering, HTTP, and SSE contracts are not implemented.

## Supported wire contract

The Shiny envelope is package-owned reliability metadata around standard
A2UI operations:

``` json
{
  "transportVersion": 1,
  "threadId": "thread-1",
  "runId": "run-1",
  "eventId": "event-12",
  "sequence": 12,
  "operations": [
    {
      "version": "v0.9.1",
      "updateDataModel": {
        "surfaceId": "order-1",
        "path": "/total",
        "value": "$42"
      }
    }
  ]
}
```

The browser and R server enforce the same per-thread sequence and
recent-event contract. Exact retries reuse the accepted event;
conflicting IDs fail closed; gaps request an inclusive recovery range.
Create is anchored to the assistant message of the matching active run.
Later update/delete may arrive outside that run. A background atomic
replacement may delete and recreate an existing surface while preserving
its message anchor, but a genuinely new or tombstoned surface still
requires a matching active run.

Accepted operation versions are raw `v0.9` and `v0.9.1`; persisted
canonical snapshots use v0.9. The supported operations are
`createSurface`, `updateComponents`, `updateDataModel`, and
`deleteSurface`. A missing-surface update, unsupported version/catalog,
malformed pointer, unsafe object, unknown component, or invalid
lifecycle is rejected rather than guessed.

`sendDataModel`/`attachDataModel = true`, A2UI v1.0, remote catalogs,
executable components, and model-supplied JavaScript remain unsupported.

## R handler API

Use `on_a2ui()` inside a normal handler. `sequence` is optional;
normally let the server allocate it and reuse a stable `event_id` when
retrying.

``` r
assistantUIServer(
  "chat",
  handler = function(message, on_a2ui, on_done, ...) {
    on_a2ui(
      list(
        list(
          version = "v0.9.1",
          createSurface = list(
            surfaceId = "order-1",
            catalogId = "urn:shinyassistantui:a2ui:catalog:v1",
            sendDataModel = FALSE
          )
        ),
        list(
          version = "v0.9.1",
          updateComponents = list(
            surfaceId = "order-1",
            components = list(
              list(id = "root", component = "Column", children = list("title")),
              list(id = "title", component = "Text", text = "Order summary")
            )
          )
        ),
        list(
          version = "v0.9.1",
          updateDataModel = list(
            surfaceId = "order-1", path = "/", value = list(total = "$42")
          )
        )
      ),
      event_id = "order-1-create"
    )
    on_done()
  }
)
```

The invisible controller returned by `assistantUIServer()` also
provides:

``` r
controls$send_a2ui(operations, thread_id, run_id, event_id = NULL, sequence = NULL)
controls$send_ag_ui_activity(event, thread_id, run_id,
                             event_id = NULL, sequence = NULL)
controls$a2ui_checkpoint(thread_id)
controls$a2ui_capabilities()
```

After a run ends, `send_ag_ui_activity()` may replace or delete existing
surfaces. It rejects a complete merged activity projection that would
create any new surface without the matching active run; this check
includes surfaces reintroduced from another bucket.

## Standard AG-UI activity adapter

The accepted standard event shape is:

``` json
{
  "type": "ACTIVITY_SNAPSHOT",
  "activityType": "a2ui-surface",
  "messageId": "activity-message-1",
  "replace": true,
  "content": {
    "a2ui_operations": [
      { "version": "v0.9.1", "createSurface": { "surfaceId": "order-1" } }
    ]
  }
}
```

Use it from a handler:

``` r
handler <- function(message, on_ag_ui_activity, on_done, ...) {
  on_ag_ui_activity(
    list(
      type = "ACTIVITY_SNAPSHOT",
      activityType = "a2ui-surface",
      messageId = "activity-message-1",
      content = list(a2ui_operations = list(
        list(version = "v0.9.1",
             createSurface = list(surfaceId = "order-1"))
      ))
    ),
    event_id = "activity-event-1"
  )
  on_done()
}
```

Activity snapshots are reduced from empty and must be self-contained.
Buckets are keyed by `messageId`; an absent `replace` means replace,
while `replace = FALSE` ignores an already-known bucket. Replacing a
bucket moves it to the latest bucket position, and the last bucket wins
when multiple buckets contain the same surface. Repeated `createSurface`
within one snapshot resets that surface while retaining its Map
position; delete then recreate moves it to the end. The adapter projects
the merged buckets atomically through the same A2UI sequencer and action
authority.

Bucket bookkeeping is live-session state. Canonical surface snapshots
and checkpoints persist, but historical AG-UI bucket membership is not
inferred after a new Shiny session. A later activity may replace
matching restored surface IDs; applications should use stable
message/surface IDs and send a complete snapshot for the resumed
activity.

## Actions and authorization

Buttons may declare an A2UI event action. The server callback receives
validated, JSON-safe fields:

``` r
assistantUIServer(
  "chat",
  handler = handler,
  a2ui_action_handler = function(
    name, input, context, thread_id, surface_id,
    source_component_id, on_a2ui, on_error, ...
  ) {
    if (!identical(name, "confirm_order")) return(on_error("Unsupported action"))
    on_a2ui(list(
      list(
        version = "v0.9.1",
        updateDataModel = list(
          surfaceId = surface_id, path = "/status", value = "Confirmed"
        )
      )
    ), event_id = "confirm-order-update")
  }
)
```

The server checks widget owner, action ID replay, rate limit, current
thread/surface, epoch, revision, source component, declared action name,
and declared context bindings. Browser-provided values remain untrusted.

An A2UI action is not tool approval. Shell commands, file changes,
R-console execution, resource deletion, and other privileged work must
still enter the normal backend tool-call and approval flow. The only
supported local side-effect function is Basic Catalog `openUrl`: it
accepts one HTTP(S) URL without credentials and opens `_blank` with
`noopener,noreferrer`. `javascript:`, `data:`, `file:`, malformed,
credential-bearing, and oversized URLs are rejected. Validation `checks`
are not claimed because the bundled upstream public renderer does not
expose that contract (`validationChecks = FALSE`).

## Persistence and history

New UI history writes use assistant-ui’s standard synthetic present tool
part:

``` json
{
  "type": "tool-call",
  "toolName": "present",
  "toolCallId": "a2ui:order-1",
  "args": { "$type": "Markdown", "value": "..." },
  "result": {},
  "artifact": {
    "a2ui": ["canonical v0.9 snapshot operations"],
    "shinyA2ui": { "kind": "surface", "surfaceId": "order-1" }
  }
}
```

`artifact.a2ui` must exactly match the marker snapshot. The marker
stores schema/protocol versions, epoch, revision, last sequence, recent
event IDs, digest, and message anchor. `args` is derived display data,
never restore authority. History hydration rebuilds the surface from the
snapshot and rejects poisoned or inconsistent metadata.

Readers permanently dual-read the earlier `{type: "generative-ui", a2ui:
marker}` format and the standard present format; writers emit only
present. Server, client, and disabled persistence paths keep their
ownership rules. Tombstone-only checkpoints survive delete-all/client
reload, live surface anchors stay pinned across the bounded browser
message window, and older-page parts are rebuilt from their snapshots
before rendering. Synthetic `a2ui:` present parts are UI-only and are
not reported to the backend as genuine tool work.

## Component and security boundary

The fixed runtime library covers the published package subset, including
text, media, controls, layout, list, Markdown, Slider, and CheckboxGroup
mappings. Unsupported components/props are dropped or produce a
contained diagnostic. Images accept reviewed HTTPS or bounded safe data
sources; the actual `<img>` uses `referrerPolicy="no-referrer"`.

Important limits include 256 KiB envelopes/images, 64 operations/recent
events, 16 live surfaces, 500 components, depth 32, 100 template/option
items, 16 KiB strings, 64 KiB action payloads, 128 tombstones, 64 live
activity buckets, and a five-second gap-recovery timeout. Unsafe JSON
Pointer segments (`__proto__`, `prototype`, `constructor`), non-finite
values, duplicate object keys, unsupported fields, and cyclic/oversized
component trees fail closed.

## What this does not claim

  - No general AG-UI runtime, transport, client, server, interrupts,
    steering, shared state, or SSE.
  - No A2UI v1.0, dynamic/remote catalog code, unrestricted HTML, or
    executable payloads.
  - No automatic migration or deletion of old history.
  - No replacement of Data UI, the legacy Generative UI primitive, tool
    UI, or `PromptUser`.
  - No permission bypass: A2UI and activity events remain data-bearing
    UI updates.

The implementation is covered by protocol, runtime, R authority,
full-suite, installed-package Chromium, history, action, recovery,
malformed-input, and zero-browser-error gates. It remains experimental
so the wire subset and application ergonomics can evolve with upstream
A2UI releases.
