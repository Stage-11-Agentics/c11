---
title: Browser Before Agent
---

## Layout

```yaml
layout:
  - direction: horizontal
    split: 50/50
    children:
      - type: browser
        title: Research
        linked_agent: s1
      - id: s1
        type: terminal
        title: Agent
        agent_kind: codex
```
