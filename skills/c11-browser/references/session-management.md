# Session Management

c11 uses isolated browser contexts per panel. Treat each browser panel as its own session.

**Related**: [authentication.md](authentication.md), [SKILL.md](../SKILL.md)

## Contents

- [Panel-Based Sessions](#panel-based-sessions)
- [Isolation Properties](#isolation-properties)
- [State Persistence](#state-persistence)
- [Common Patterns](#common-patterns)
- [Cleanup](#cleanup)
- [Best Practices](#best-practices)

## Panel-Based Sessions

```bash
# session A
c11 browser open https://app.example.com/login --json
# -> panel:7

# session B
c11 browser open https://example.com --json
# -> panel:8

c11 browser panel:7 get url
c11 browser panel:8 get url
```

## Isolation Properties

Each panel has independent:
- cookies
- localStorage/sessionStorage
- its current page
- navigation history

## State Persistence

### Save State

```bash
c11 browser panel:7 state save /tmp/auth-state.json
```

### Load State

```bash
c11 browser panel:8 state load /tmp/auth-state.json
c11 browser panel:8 goto https://app.example.com/dashboard
```

## Common Patterns

### Reuse Auth Across New Panel

```bash
c11 browser open https://app.example.com/login --json
# login on panel:7 ...
c11 browser panel:7 state save /tmp/auth.json

c11 browser open https://app.example.com --json
# assume panel:8
c11 browser panel:8 state load /tmp/auth.json
c11 browser panel:8 goto https://app.example.com/dashboard
```

### Parallel Multi-Site Tasks

```bash
c11 browser open https://site-a.example --json
c11 browser open https://site-b.example --json
c11 browser open https://site-c.example --json

c11 browser panel:11 get text body > /tmp/a.txt
c11 browser panel:12 get text body > /tmp/b.txt
c11 browser panel:13 get text body > /tmp/c.txt
```

## Cleanup

```bash
c11 close-panel --panel panel:7
c11 close-panel --panel panel:8
rm -f /tmp/auth-state.json
```

## Best Practices

1. Name/log panels in your script output so actions stay attributable.
2. Keep one task per panel to avoid ref churn.
3. Save state after successful auth milestones.
4. Re-snapshot after switching pages inside a panel.
