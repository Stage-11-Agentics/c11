# Mermaid upgrade render matrix

This fixture exercises the diagram forms supported by the viewer and Mermaid math inside a label.

## Flowchart

```mermaid
flowchart LR
    A[Panel A builder] -- writes envelope --> OB[(_outbox/)]
    OB -- fsevent --> D{{Dispatcher}}
    D -- atomic move --> P[(_processing/)]
    D -- valid --> IB[(watcher/inbox)]
    D -- malformed --> R[(_rejected/ + .err sidecar)]
    IB -- stdin handler --> B[Panel B watcher PTY]
```

## Sequence

```mermaid
sequenceDiagram
    participant A as Sender panel
    participant FS as _outbox/ to inbox
    participant B as Recipient panel
    A->>FS: c11 mailbox send --to B
    FS->>B: dispatcher routes by panel name
    Note over B: framed message appears in PTY<br/>or waits in inbox until drained
```

## Class

```mermaid
classDiagram
    class Workspace {
      +UUID id
      +String title
    }
    class Panel {
      +UUID id
      +String type
    }
    Workspace "1" o-- "*" Panel : contains
```

## State

```mermaid
stateDiagram-v2
    [*] --> Outbox: atomic write
    Outbox --> Processing: dispatcher move
    Processing --> Delivered: recipient panel found
    Processing --> Rejected: validation fails
    Delivered --> [*]
    Rejected --> [*]: error sidecar written
```

## Gantt

```mermaid
gantt
    title C11-456 validation
    dateFormat YYYY-MM-DD
    axisFormat %b %d
    tickInterval 1day
    section Viewer
    Baseline proof :done, baseline, 2026-10-22, 1d
    Mermaid 12 proof :active, upgrade, after baseline, 1d
```

## Pie

```mermaid
pie title Panel kinds
    "Terminal" : 42
    "Browser" : 21
    "Markdown" : 13
    "Agent" : 8
    "Other" : 5
```

## Math in a label

Mermaid math syntax uses double dollar delimiters.

```mermaid
flowchart LR
    Input["Input: $$x^2 + y^2$$"] --> Output["Result: $$\frac{1}{2} + \sqrt{2}$$"]
```
