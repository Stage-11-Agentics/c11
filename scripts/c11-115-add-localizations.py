#!/usr/bin/env python3
"""C11-115: authoring + translations for the new-workspace sheet redesign
(recents-as-panel, letter-cell layout icons, pin/keyboard/drag-drop/empty-state,
2 x 3 blueprint, last-layout memory).

Idempotent: re-running replaces existing entries with the values authored
here.

English is the source-of-truth (set in source via
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
    (
        "createWorkspace.baseDirectory.label",
        "Base directory for your new workspace",
        "新しいワークスペースのベースディレクトリ",
        "Базова директорія для нового робочого простору",
        "새 워크스페이스의 기본 디렉터리",
        "新工作区的基础目录",
        "新工作區的基礎目錄",
        "Базовая директория для нового рабочего пространства",
    ),
    (
        "createWorkspace.recents.caption",
        "or select from your recent directories:",
        "または最近のディレクトリから選択:",
        "або виберіть з нещодавніх директорій:",
        "또는 최근 디렉터리에서 선택:",
        "或从最近的目录中选择：",
        "或從最近的目錄中選擇：",
        "или выберите из недавних директорий:",
    ),
    (
        "createWorkspace.recents.sort.recent",
        "Most recent",
        "最新順",
        "Найновіші",
        "최근순",
        "最近的",
        "最近的",
        "По новизне",
    ),
    (
        "createWorkspace.recents.sort.opened",
        "Most opened",
        "開いた回数順",
        "Найчастіше відкривані",
        "가장 많이 연 순",
        "打开次数最多",
        "開啟次數最多",
        "По частоте",
    ),
    (
        "createWorkspace.recents.hint.click",
        "Click or",
        "クリックまたは",
        "Клацніть або",
        "클릭 또는",
        "点击或",
        "點擊或",
        "Щелчок или",
    ),
    (
        "createWorkspace.recents.hint.toSelect",
        "to select",
        "で選択",
        "щоб вибрати",
        "선택",
        "选择",
        "選擇",
        "для выбора",
    ),
    (
        "createWorkspace.recents.hint.openHint",
        "or double-click opens with your last layout",
        "またはダブルクリックで前回のレイアウトで開きます",
        "або подвійний клік відкриває з останнім розкладом",
        "또는 더블 클릭으로 마지막 레이아웃으로 열기",
        "或双击使用上次的布局打开",
        "或雙擊使用上次的版面開啟",
        "или двойной клик откроет с прошлым макетом",
    ),
    (
        "createWorkspace.recents.empty.title",
        "No recent directories yet",
        "最近のディレクトリはまだありません",
        "Поки що немає нещодавніх директорій",
        "아직 최근 디렉터리가 없습니다",
        "暂无最近的目录",
        "暫無最近的目錄",
        "Недавних директорий пока нет",
    ),
    (
        "createWorkspace.recents.empty.hint",
        "Pick a directory above, browse to one, or drag a folder here.",
        "上でディレクトリを選択するか、参照するか、フォルダをここにドラッグしてください。",
        "Виберіть директорію вище, перегляньте файлову систему або перетягніть папку сюди.",
        "위에서 디렉터리를 선택하거나, 찾아보거나, 폴더를 여기로 드래그하세요.",
        "在上方选择目录，浏览查找，或将文件夹拖到此处。",
        "在上方選擇目錄，瀏覽查找，或將資料夾拖到此處。",
        "Выберите директорию выше, найдите её через обзор или перетащите папку сюда.",
    ),
    (
        "createWorkspace.recents.justNow",
        "just now",
        "たった今",
        "щойно",
        "방금",
        "刚刚",
        "剛剛",
        "только что",
    ),
    (
        "createWorkspace.recents.openedOnce",
        "opened 1 time",
        "1 回開いた",
        "відкрито 1 раз",
        "1번 열림",
        "已打开 1 次",
        "已開啟 1 次",
        "открыто 1 раз",
    ),
    (
        "createWorkspace.recents.openedMany",
        "opened %d times",
        "%d 回開いた",
        "відкрито %d разів",
        "%d번 열림",
        "已打开 %d 次",
        "已開啟 %d 次",
        "открыто %d раз",
    ),
    (
        "createWorkspace.recents.pin",
        "Pin to top",
        "トップに固定",
        "Закріпити вгорі",
        "맨 위에 고정",
        "置顶",
        "置頂",
        "Закрепить наверху",
    ),
    (
        "createWorkspace.recents.unpin",
        "Unpin",
        "固定解除",
        "Відкріпити",
        "고정 해제",
        "取消置顶",
        "取消置頂",
        "Открепить",
    ),
    (
        "createWorkspace.dropTarget",
        "Drop folder to set base directory",
        "フォルダをドロップしてベースディレクトリを設定",
        "Перетягніть папку, щоб встановити базову директорію",
        "폴더를 드롭하여 기본 디렉터리 설정",
        "拖放文件夹以设置基础目录",
        "拖放資料夾以設定基礎目錄",
        "Перетащите папку, чтобы задать базовую директорию",
    ),
    (
        "createWorkspace.legend.agent",
        "agent",
        "エージェント",
        "агент",
        "에이전트",
        "代理",
        "代理",
        "агент",
    ),
    (
        "createWorkspace.legend.terminal",
        "terminal",
        "ターミナル",
        "термінал",
        "터미널",
        "终端",
        "終端機",
        "терминал",
    ),
    (
        "createWorkspace.legend.browser",
        "browser",
        "ブラウザー",
        "браузер",
        "브라우저",
        "浏览器",
        "瀏覽器",
        "браузер",
    ),
    (
        "createWorkspace.legend.markdown",
        "markdown",
        "マークダウン",
        "розмітка",
        "마크다운",
        "Markdown",
        "Markdown",
        "разметка",
    ),
    (
        "createWorkspace.customBlueprints.helpHint",
        "What is a custom blueprint?",
        "カスタムブループリントとは?",
        "Що таке користувацький blueprint?",
        "사용자 정의 블루프린트란?",
        "什么是自定义蓝图？",
        "什麼是自訂藍圖？",
        "Что такое пользовательский blueprint?",
    ),
    (
        "createWorkspace.customBlueprints.empty",
        "No custom blueprints yet.",
        "カスタムブループリントはまだありません。",
        "Користувацьких blueprint поки що немає.",
        "사용자 정의 블루프린트가 아직 없습니다.",
        "暂无自定义蓝图。",
        "暫無自訂藍圖。",
        "Пользовательских blueprint пока нет.",
    ),
    (
        "createWorkspace.customBlueprints.count",
        "%d blueprints",
        "%d 個のブループリント",
        "%d blueprint",
        "%d개의 블루프린트",
        "%d 个蓝图",
        "%d 個藍圖",
        "blueprint: %d",
    ),
    (
        "createWorkspace.customBlueprints.help.body1",
        "Saved pane and surface layouts you can launch a workspace from.",
        "ワークスペースの起動に使える、保存されたペインとサーフェスのレイアウトです。",
        "Збережені компонування панелей і поверхонь, з яких можна запустити робочий простір.",
        "워크스페이스를 시작할 수 있는 저장된 패널 및 서피스 레이아웃입니다.",
        "可用于启动工作区的已保存窗格和表面布局。",
        "可用於啟動工作區的已儲存窗格和表面版面。",
        "Сохранённые компоновки панелей и поверхностей, из которых можно запустить рабочее пространство.",
    ),
    (
        "createWorkspace.customBlueprints.help.body2",
        "c11 is agent-first software, so we didn't build a UI to make these. Just ask your agent. It can write a blueprint file to your blueprints folder, and it'll show up here.",
        "c11 はエージェントファーストのソフトウェアなので、作成 UI は用意していません。エージェントに頼んでください。エージェントが blueprint ファイルをフォルダに書き込めば、ここに表示されます。",
        "c11 — це програмне забезпечення, орієнтоване на агентів, тож ми не створювали UI для цього. Просто попросіть свого агента. Він може записати файл blueprint у вашу папку, і він з’явиться тут.",
        "c11은 에이전트 우선 소프트웨어이므로 이를 만들 UI를 만들지 않았습니다. 에이전트에게 요청하세요. 에이전트가 블루프린트 파일을 폴더에 작성하면 여기에 표시됩니다.",
        "c11 是代理优先的软件，因此我们没有为此构建 UI。让你的代理来做。它可以将蓝图文件写入你的蓝图文件夹，然后就会显示在这里。",
        "c11 是代理優先的軟體，因此我們沒有為此建立 UI。讓你的代理來做。它可以將藍圖檔案寫入你的藍圖資料夾，然後就會顯示在這裡。",
        "c11 — это программное обеспечение, ориентированное на агентов, поэтому мы не создавали UI для этого. Просто попросите своего агента. Он может записать файл blueprint в вашу папку, и он появится здесь.",
    ),
    (
        "createWorkspace.customBlueprints.help.reveal",
        "Reveal blueprints folder",
        "blueprint フォルダを表示",
        "Показати папку blueprints",
        "블루프린트 폴더 표시",
        "显示蓝图文件夹",
        "顯示藍圖資料夾",
        "Показать папку blueprints",
    ),
    (
        "createWorkspace.starter.single.label",
        "Single",
        "シングル",
        "Один",
        "단일",
        "单一",
        "單一",
        "Один",
    ),
    (
        "createWorkspace.starter.single.description",
        "One terminal pane filling the workspace.",
        "ワークスペース全体を埋めるターミナルペイン 1 つ。",
        "Одна термінальна панель, що заповнює робочий простір.",
        "워크스페이스를 채우는 터미널 패널 하나.",
        "一个填满工作区的终端窗格。",
        "一個填滿工作區的終端機窗格。",
        "Одна терминальная панель, заполняющая рабочее пространство.",
    ),
    (
        "createWorkspace.starter.threeColumns.label",
        "Three columns",
        "3 カラム",
        "Три колонки",
        "세 컬럼",
        "三栏",
        "三欄",
        "Три колонки",
    ),
    (
        "createWorkspace.starter.threeColumns.description",
        "Three terminals side by side.",
        "ターミナル 3 つを横並びで。",
        "Три термінали поряд.",
        "터미널 세 개를 나란히.",
        "三个终端并排。",
        "三個終端機並排。",
        "Три терминала рядом.",
    ),
    (
        "createWorkspace.starter.twoByThree.label",
        "2 × 3",
        "2 × 3",
        "2 × 3",
        "2 × 3",
        "2 × 3",
        "2 × 3",
        "2 × 3",
    ),
    (
        "createWorkspace.starter.twoByThree.description",
        "Six terminal panes in 2 columns, 3 rows. External 27-inch+ monitor suggested.",
        "ターミナル 6 つを 2 カラム 3 行で。27 インチ以上の外部モニター推奨。",
        "Шість термінальних панелей у 2 колонки, 3 рядки. Рекомендовано зовнішній монітор 27 дюймів і більше.",
        "터미널 6개를 2열 3행으로. 27인치 이상 외부 모니터 권장.",
        "六个终端窗格，2 列 3 行。建议使用 27 英寸以上的外部显示器。",
        "六個終端機窗格，2 欄 3 列。建議使用 27 吋以上的外接顯示器。",
        "Шесть терминальных панелей в 2 колонки, 3 строки. Рекомендуется внешний монитор 27 дюймов и больше.",
    ),
    (
        "createWorkspace.starter.threeByTwo.label",
        "3 × 2",
        "3 × 2",
        "3 × 2",
        "3 × 2",
        "3 × 2",
        "3 × 2",
        "3 × 2",
    ),
    (
        "createWorkspace.starter.threeByTwo.description",
        "Six terminals in 3 columns, 2 rows.",
        "ターミナル 6 つを 3 カラム 2 行で。",
        "Шість терміналів у 3 колонки, 2 рядки.",
        "터미널 6개를 3열 2행으로.",
        "六个终端，3 列 2 行。",
        "六個終端機，3 欄 2 列。",
        "Шесть терминалов в 3 колонки, 2 строки.",
    ),
    (
        "createWorkspace.starter.quad.label",
        "2 × 2",
        "2 × 2",
        "2 × 2",
        "2 × 2",
        "2 × 2",
        "2 × 2",
        "2 × 2",
    ),
    (
        "createWorkspace.starter.quad.description",
        "Four terminals in a 2 × 2 grid.",
        "ターミナル 4 つを 2 × 2 グリッドで。",
        "Чотири термінали в сітці 2 × 2.",
        "터미널 4개를 2 × 2 격자로.",
        "四个终端，2 × 2 网格。",
        "四個終端機，2 × 2 格線。",
        "Четыре терминала в сетке 2 × 2.",
    ),
    (
        "createWorkspace.name.hint",
        "Defaults to the directory name. Override to give this workspace a custom label.",
        "ディレクトリ名がデフォルトです。このワークスペースにカスタムラベルを付ける場合は上書きしてください。",
        "За замовчуванням — назва директорії. Перевизначте, щоб дати робочому простору власну мітку.",
        "기본값은 디렉터리 이름입니다. 이 워크스페이스에 사용자 정의 레이블을 지정하려면 재정의하세요.",
        "默认为目录名称。如要为该工作区指定自定义标签，请覆盖。",
        "預設為目錄名稱。如要為該工作區指定自訂標籤，請覆寫。",
        "По умолчанию — имя директории. Переопределите, чтобы задать этому рабочему пространству своё имя.",
    ),
    (
        "createWorkspace.layouts",
        "Layouts",
        "レイアウト",
        "Розкладки",
        "레이아웃",
        "布局",
        "版面",
        "Макеты",
    ),
    (
        "createWorkspace.starter.twoColumns.label",
        "Two columns",
        "2 カラム",
        "Дві колонки",
        "두 컬럼",
        "两栏",
        "兩欄",
        "Две колонки",
    ),
    (
        "createWorkspace.starter.twoColumns.description",
        "Two terminals split side by side. Agent left, terminal right.",
        "ターミナル 2 つを横並びで分割。左にエージェント、右にターミナル。",
        "Два термінали поруч. Агент ліворуч, термінал праворуч.",
        "터미널 두 개를 나란히 분할. 왼쪽 에이전트, 오른쪽 터미널.",
        "两个终端并排分割。左侧代理，右侧终端。",
        "兩個終端機並排分割。左側代理，右側終端機。",
        "Два терминала бок о бок. Агент слева, терминал справа.",
    ),
    (
        "createWorkspace.starter.quad.description",
        "Four terminal panes in a 2 × 2 grid. Agent in the top-left.",
        "ターミナル 4 つを 2 × 2 グリッドで。左上にエージェント。",
        "Чотири термінальні панелі в сітці 2 × 2. Агент у верхньому лівому куті.",
        "터미널 4개를 2 × 2 격자로. 왼쪽 상단에 에이전트.",
        "四个终端窗格，2 × 2 网格。代理在左上角。",
        "四個終端機窗格，2 × 2 格線。代理在左上角。",
        "Четыре терминальные панели в сетке 2 × 2. Агент в левом верхнем углу.",
    ),
    (
        "createWorkspace.launchAgent",
        "Launch your default coding agent in the first pane",
        "最初のペインでデフォルトのコーディングエージェントを起動",
        "Запустити вашого стандартного агента програмування на першій панелі",
        "첫 번째 패널에서 기본 코딩 에이전트 실행",
        "在第一个窗格中启动你的默认编码代理",
        "在第一個窗格中啟動你的預設編碼代理",
        "Запустить вашего стандартного агента-программиста в первой панели",
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
