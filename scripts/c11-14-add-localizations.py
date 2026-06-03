#!/usr/bin/env python3
"""C11-14 (post-redesign): authoring + translations for the unified default
agent Settings section. The shape changed mid-flight — terminals are bash,
the A button is agents, one canonical setting governs both the A button and
its right-click picker.

Idempotent: re-running replaces existing entries with the values authored
here. Older keys (the herestring-era `settings.defaultAgent.model.*` etc.)
are now dead weight; this script no longer authors them. They linger in the
catalog as harmless extras and can be swept in a separate cleanup pass.

Translations: English is the source-of-truth (set in source via
`String(localized:defaultValue:)`). The other six (ja, uk, ko, zh-Hans,
zh-Hant, ru) are the standard c11 set per CLAUDE.md."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Resources" / "Localizable.xcstrings"

# (key, en, ja, uk, ko, zh-Hans, zh-Hant, ru)
ENTRIES: list[tuple[str, str, str, str, str, str, str, str]] = [
    # Agent display names — used by the picker, the A-button tooltip, and the
    # per-agent subheading.
    (
        "agentType.claudeCode",
        "Claude Code",
        "Claude Code",
        "Claude Code",
        "Claude Code",
        "Claude Code",
        "Claude Code",
        "Claude Code",
    ),
    (
        "agentType.codex",
        "Codex",
        "Codex",
        "Codex",
        "Codex",
        "Codex",
        "Codex",
        "Codex",
    ),
    (
        "agentType.kimi",
        "Kimi",
        "Kimi",
        "Kimi",
        "Kimi",
        "Kimi",
        "Kimi",
        "Kimi",
    ),
    (
        "agentType.opencode",
        "OpenCode",
        "OpenCode",
        "OpenCode",
        "OpenCode",
        "OpenCode",
        "OpenCode",
        "OpenCode",
    ),
    (
        "agentType.custom",
        "Custom",
        "カスタム",
        "Користувацька",
        "사용자 지정",
        "自定义",
        "自訂",
        "Пользовательский",
    ),
    # Section header + note.
    (
        "settings.section.defaultAgent",
        "default agent",
        "デフォルトエージェント",
        "типовий агент",
        "기본 에이전트",
        "默认代理",
        "預設代理",
        "агент по умолчанию",
    ),
    (
        "settings.defaultAgent.note",
        "the A button on every pane launches this. new terminal still opens bash. drop a `.c11/agents.json` in any repo to override these settings for terminals opened there.",
        "各ペインの A ボタンはこれを起動します。新規ターミナルは引き続き bash を開きます。これらの設定をリポジトリ単位で上書きするには `.c11/agents.json` を置きます。",
        "Кнопка A на кожній панелі запускає це. Новий термінал, як і раніше, відкриває bash. Покладіть `.c11/agents.json` у будь-який репозиторій, щоб перевизначити ці налаштування для терміналів, відкритих у ньому.",
        "각 패널의 A 버튼이 이것을 실행합니다. 새 터미널은 여전히 bash를 엽니다. 그곳에서 열리는 터미널의 설정을 재정의하려면 어떤 저장소에든 `.c11/agents.json`을 넣으세요.",
        "每个窗格上的 A 按钮启动它。新建终端仍打开 bash。在任意仓库放入 `.c11/agents.json` 即可覆盖在该处打开的终端的设置。",
        "每個窗格上的 A 按鈕啟動它。新增終端機仍開啟 bash。在任一儲存庫放入 `.c11/agents.json` 即可覆寫在該處開啟的終端機的設定。",
        "Кнопка A на каждой панели запускает его. Новый терминал по-прежнему открывает bash. Положите `.c11/agents.json` в любой репозиторий, чтобы переопределить эти настройки для терминалов, открытых там.",
    ),
    # Picker.
    (
        "settings.defaultAgent.picker.label",
        "default agent",
        "デフォルトエージェント",
        "типовий агент",
        "기본 에이전트",
        "默认代理",
        "預設代理",
        "агент по умолчанию",
    ),
    # Per-agent subheading: "Agent %@" so the operator always knows which
    # agent's fields they're editing.
    (
        "settings.defaultAgent.subheading.format",
        "Agent %@",
        "%@ エージェント",
        "Агент %@",
        "%@ 에이전트",
        "%@ 代理",
        "%@ 代理",
        "Агент %@",
    ),
    # Command field.
    (
        "settings.defaultAgent.command.label",
        "command",
        "コマンド",
        "команда",
        "명령",
        "命令",
        "指令",
        "команда",
    ),
    (
        "settings.defaultAgent.command.help.format",
        "the shell line that runs when we launch the %@ agent. you can include any parameters to match your specification.",
        "%@ エージェントを起動するときに実行されるシェル行です。仕様に合わせて任意のパラメータを含められます。",
        "Рядок оболонки, який запускається, коли ми запускаємо агента %@. Ви можете включити будь-які параметри відповідно до ваших вимог.",
        "%@ 에이전트를 실행할 때 실행되는 셸 라인입니다. 사양에 맞춰 어떤 매개변수든 포함할 수 있습니다.",
        "启动 %@ 代理时运行的 shell 命令行。可以包含任意符合规范的参数。",
        "啟動 %@ 代理時執行的 shell 指令行。可以包含任意符合規範的參數。",
        "Строка оболочки, выполняемая при запуске агента %@. Можете включить любые параметры согласно вашей спецификации.",
    ),
    # Initial prompt field.
    (
        "settings.defaultAgent.initialPrompt.label",
        "initial prompt",
        "初期プロンプト",
        "початковий запит",
        "초기 프롬프트",
        "初始提示词",
        "初始提示",
        "начальный запрос",
    ),
    (
        "settings.defaultAgent.initialPrompt.help",
        "optional. typed into the agent right after it boots.",
        "省略可。エージェントの起動直後にエージェントに入力されます。",
        "Необов’язково. Вводиться в агент одразу після запуску.",
        "선택. 에이전트가 부팅된 직후에 에이전트에 입력됩니다.",
        "可选。代理启动后立即输入到代理中。",
        "選填。代理啟動後立即輸入到代理中。",
        "Необязательно. Вводится в агент сразу после запуска.",
    ),
    # Env disclosure + help.
    (
        "settings.defaultAgent.env.disclosure",
        "environment overrides — advanced users only",
        "環境変数の上書き — 上級者専用",
        "перевизначення середовища — лише для досвідчених",
        "환경 변수 재정의 — 고급 사용자 전용",
        "环境变量覆盖 — 仅限高级用户",
        "環境變數覆寫 — 僅限進階使用者",
        "переопределения окружения — только для опытных пользователей",
    ),
    (
        "settings.defaultAgent.env.help",
        "one KEY=value per line. injected into the agent's process. leave empty unless you know why you want it.",
        "1 行に 1 つの KEY=value。エージェントのプロセスに注入されます。理由がなければ空のままにしてください。",
        "Один KEY=value на рядок. Інжектується в процес агента. Залиште порожнім, якщо не знаєте, навіщо це потрібно.",
        "한 줄에 하나의 KEY=value. 에이전트 프로세스에 주입됩니다. 이유를 모르면 비워 두세요.",
        "每行一个 KEY=value。注入到代理进程中。如果不清楚原因，请保持为空。",
        "每行一個 KEY=value。注入到代理程序中。如果不清楚原因，請保持空白。",
        "Один KEY=value в строке. Передаётся в процесс агента. Оставьте пустым, если не знаете, зачем это нужно.",
    ),
    # Reset button.
    (
        "settings.defaultAgent.reset",
        "reset agent to defaults",
        "エージェントをデフォルトに戻す",
        "скинути агента до типових",
        "에이전트를 기본값으로 재설정",
        "将代理重置为默认值",
        "將代理重設為預設值",
        "сбросить агента к значениям по умолчанию",
    ),
    # c11 skills section (renamed from "Agent Skills" and moved above
    # default agent).
    (
        "settings.section.c11Skills",
        "c11 skills",
        "c11 スキル",
        "c11 навички",
        "c11 스킬",
        "c11 技能",
        "c11 技能",
        "c11 навыки",
    ),
    # New Settings page entries: Agents (split out from the old combined
    # "Agents & Automation"), and Automation (the rest of what used to live
    # there). Sidebar icon for Agents is `a.circle` — the same A glyph the
    # per-pane button uses.
    (
        "settings.page.agents",
        "Agents",
        "エージェント",
        "Агенти",
        "에이전트",
        "代理",
        "代理",
        "Агенты",
    ),
    (
        "settings.page.agents.helper",
        "the A button on every pane launches an agent. shape what runs and what it knows about c11.",
        "各ペインの A ボタンはエージェントを起動します。何が実行され、c11 について何を知っているかを形作ります。",
        "Кнопка A на кожній панелі запускає агента. Визначте, що запускається і що він знає про c11.",
        "각 패널의 A 버튼이 에이전트를 실행합니다. 무엇이 실행되고 에이전트가 c11에 대해 무엇을 아는지 정합니다.",
        "每个窗格上的 A 按钮启动一个代理。决定运行什么以及它对 c11 了解什么。",
        "每個窗格上的 A 按鈕啟動一個代理。決定執行什麼以及它對 c11 了解什麼。",
        "Кнопка A на каждой панели запускает агента. Определите, что запускается и что он знает о c11.",
    ),
    (
        "settings.page.automation",
        "Automation",
        "オートメーション",
        "Автоматизація",
        "자동화",
        "自动化",
        "自動化",
        "Автоматизация",
    ),
    (
        "settings.page.automation.helper",
        "let external tools drive c11 through its local socket.",
        "外部ツールがローカルソケットを介して c11 を駆動できるようにします。",
        "Дозвольте зовнішнім інструментам керувати c11 через локальний сокет.",
        "외부 도구가 로컬 소켓을 통해 c11을 구동하도록 허용합니다.",
        "允许外部工具通过本地套接字驱动 c11。",
        "允許外部工具透過本機 Socket 驅動 c11。",
        "Позвольте внешним инструментам управлять c11 через локальный сокет.",
    ),
    (
        "settings.c11Skills.note",
        "c11's skill files install into each agent's skill folder (Claude Code, Codex, …) with your approval. linked folders are shown as shared so removing once cannot silently affect another agent.",
        "c11 のスキルファイルは、承認の上で各エージェントのスキルフォルダ (Claude Code、Codex 等) にインストールされます。リンクされたフォルダは共有として表示され、一度の削除が他のエージェントに気付かれず影響することはありません。",
        "Файли навичок c11 встановлюються в папку навичок кожного агента (Claude Code, Codex, …) з вашого схвалення. Зв’язані папки відображаються як спільні, тож одне видалення не може непомітно вплинути на іншого агента.",
        "c11의 스킬 파일은 승인 후 각 에이전트의 스킬 폴더(Claude Code, Codex, …)에 설치됩니다. 연결된 폴더는 공유로 표시되어 한 번의 제거가 다른 에이전트에 조용히 영향을 미칠 수 없습니다.",
        "c11 的技能文件在你批准后会安装到每个代理的技能文件夹中（Claude Code、Codex 等）。已链接的文件夹显示为共享，因此一次移除不会悄无声息地影响其他代理。",
        "c11 的技能檔案在你批准後會安裝到每個代理的技能資料夾中（Claude Code、Codex 等）。已連結的資料夾顯示為共用，因此一次移除不會悄無聲息地影響其他代理。",
        "Файлы навыков c11 устанавливаются в папку навыков каждого агента (Claude Code, Codex, …) с вашего одобрения. Связанные папки отображаются как общие, чтобы одно удаление не могло незаметно затронуть другого агента.",
    ),
]

LANG_ORDER = ["en", "ja", "uk", "ko", "zh-Hans", "zh-Hant", "ru"]


def build_entry(values: tuple[str, ...]) -> dict:
    en, ja, uk, ko, zh_hans, zh_hant, ru = values
    return {
        "extractionState": "manual",
        "localizations": {
            lang: {"stringUnit": {"state": "translated", "value": v}}
            for lang, v in zip(LANG_ORDER, [en, ja, uk, ko, zh_hans, zh_hant, ru])
        },
    }


def main() -> int:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = data["strings"]
    added, updated = 0, 0
    for row in ENTRIES:
        key, *values = row
        entry = build_entry(tuple(values))
        if key in strings:
            updated += 1
        else:
            added += 1
        strings[key] = entry
    CATALOG.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"OK — added {added}, updated {updated} keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())
