# OpenAI CUA Runner

This harness drives tagged c11 debug builds through the OpenAI Responses API `computer` tool and a provider-neutral native macOS adapter. It keeps the UI action path visual: screenshots and CoreGraphics input events go through the target app window, while the c11 socket is used for setup, oracle checks, and artifact capture.

Official API reference: <https://developers.openai.com/api/docs/guides/tools-computer-use>

## Layout

- `../mac-adapter`: Swift CLI for macOS window discovery, permission checks, screenshot capture, and input events.
- `openai_cua_runner`: Python scenario runner, artifact writer, Responses API loop, and c11 socket oracle.
- `artifacts/openai-cua-runs/`: ignored runtime output written from the repo root.

## Build

From the repo root:

```bash
swift build --package-path tools/computer-use/mac-adapter
```

Build the tagged c11 app only with a tag:

```bash
./scripts/reload.sh --tag openai-cua
```

The default target values are:

- Bundle id: `com.stage11.c11.debug.openai.cua`
- App: `~/Library/Developer/Xcode/DerivedData/c11-openai-cua/Build/Products/Debug/c11 DEV openai-cua.app`
- Socket: `/tmp/c11-debug-openai-cua.sock`

## Commands

Run from the repo root with `PYTHONPATH` unless installed in a virtualenv:

```bash
PYTHONPATH=tools/computer-use/openai-runner python3 -m openai_cua_runner doctor --tag openai-cua
PYTHONPATH=tools/computer-use/openai-runner python3 -m openai_cua_runner smoke --tag openai-cua
PYTHONPATH=tools/computer-use/openai-runner python3 -m openai_cua_runner scenario launch-window --tag openai-cua
PYTHONPATH=tools/computer-use/openai-runner python3 -m openai_cua_runner scenario create-split --tag openai-cua
PYTHONPATH=tools/computer-use/openai-runner python3 -m openai_cua_runner scenario focus-and-type --tag openai-cua
```

Use `--build` on `smoke` or `scenario` to run `./scripts/reload.sh --tag <tag>` before launch. The runner reads `OPENAI_API_KEY` from the environment only. Override the model with `--model` or `OPENAI_CUA_MODEL`; override the per-request API timeout with `OPENAI_CUA_REQUEST_TIMEOUT`.

## Permissions

The adapter requires macOS Screen Recording and Accessibility permissions for the terminal or host process running it:

- System Settings > Privacy & Security > Screen Recording
- System Settings > Privacy & Security > Accessibility

If either permission is missing, `doctor`, `smoke`, and scenarios stop with a remediation message instead of attempting broad desktop interaction.

## Adapter CLI

```bash
tools/computer-use/mac-adapter/.build/debug/cua-mac-adapter doctor --bundle-id com.stage11.c11.debug.openai.cua
tools/computer-use/mac-adapter/.build/debug/cua-mac-adapter window-list
tools/computer-use/mac-adapter/.build/debug/cua-mac-adapter launch --bundle-id com.stage11.c11.debug.openai.cua --app-path "$HOME/Library/Developer/Xcode/DerivedData/c11-openai-cua/Build/Products/Debug/c11 DEV openai-cua.app"
tools/computer-use/mac-adapter/.build/debug/cua-mac-adapter observe --bundle-id com.stage11.c11.debug.openai.cua --out /tmp/c11-openai-cua.png
```

`act` accepts one JSON action from `--json`, `--json-file`, or stdin. Supported actions are `click`, `double_click`, `move`, `drag`, `scroll`, `type`, `keypress`, `wait`, and `screenshot`.
