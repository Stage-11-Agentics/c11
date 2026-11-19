#!/usr/bin/env python3
"""C11H-385: scripts/check-localization-catalog.py fails when a String(localized:) key in the
sources has no full catalog entry, and passes a complete one. Each case builds a small fake tree."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts" / "check-localization-catalog.py"
LOCALES = ("en", "ja", "uk", "ko", "zh-Hans", "zh-Hant", "ru")


def entry(value, **overrides):
    """A catalog entry with every locale set to `value` (or to an override per locale)."""

    locs = {}
    for loc in LOCALES:
        v = overrides.get(loc.replace("-", "_"), value)
        if v is not None:
            locs[loc] = {"stringUnit": {"state": "translated", "value": v}}
    return {"extractionState": "manual", "localizations": locs}


class CheckLocalizationCatalogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="c11-l10n-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.strings = {
            "app.title": entry("Workspaces"),
            "app.count": entry("%lld panels", ru="%lld панелей"),
            "cli.move": entry("Move %@ before %@", ja="%2$@ の前に %1$@ を移動"),
            "cli.format": entry("inherit · %@"),
        }
        self.write("Sources/App.swift", '''
            let title = String(localized: "app.title", defaultValue: "Workspaces")
            let count = String(localized: "app.count", defaultValue: "\\(n) panels")
            let fmt = String(format: String(localized: "cli.format", defaultValue: "inherit · %@"), x)
            ''')
        self.write("CLI/Main.swift", '''
            throw CLIError(message: String(localized: "cli.move",
                defaultValue: "Move \\(a) before \\("--index")"))
            ''')

    def write(self, rel, text):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def run_check(self, *extra):
        catalog = self.root / "Resources" / "Localizable.xcstrings"
        catalog.parent.mkdir(parents=True, exist_ok=True)
        catalog.write_text(json.dumps({"sourceLanguage": "en", "strings": self.strings, "version": "1.0"},
                                      ensure_ascii=False, indent=2), encoding="utf-8")
        return subprocess.run([sys.executable, str(CHECK), "--root", str(self.root), *extra],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)

    def assert_finding(self, needle):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stdout)
        return result

    def test_complete_catalog_passes(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ok, 4 keys from 4 calls", result.stdout)

    def test_key_with_no_entry_fails(self):
        del self.strings["cli.move"]
        self.assert_finding("cli.move: no catalog entry (used at CLI/Main.swift:2)")

    def test_missing_locale_fails(self):
        self.strings["app.title"] = entry("Workspaces", zh_Hant=None)
        self.assert_finding("app.title: no zh-Hant translation")

    def test_untranslated_state_fails(self):
        self.strings["app.title"]["localizations"]["ko"]["stringUnit"]["state"] = "needs_review"
        self.assert_finding("app.title ko: state 'needs_review', not 'translated'")

    def test_dropped_or_changed_token_fails(self):
        self.strings["app.count"] = entry("%lld panels", uk="панелей")
        self.assert_finding("app.count uk: tokens {} != English {1:%lld}")
        self.strings["app.count"] = entry("%lld panels", ja="%@ パネル")
        self.assert_finding("app.count ja: tokens {1:%@} != English {1:%lld}")

    def test_english_argument_count_must_match_the_call_site(self):
        self.strings["app.title"] = entry("%@ workspaces")
        self.assert_finding("app.title en: format arguments {1:%@} but the call site supplies 0; "
                            "English must use no format arguments")

    def test_a_position_past_the_call_arguments_fails(self):
        # One interpolation, but every locale reads argument 2.
        self.strings["app.count"] = entry("Hello %2$@")
        self.assert_finding("app.count en: format arguments {2:%@} but the call site supplies 1")

    def test_width_and_precision_are_part_of_the_token(self):
        self.write("Sources/Clock.swift",
                   'let t = String(format: String(localized: "clock.minutes", defaultValue: "%02d min · %.1f h"), m, h)\n')
        self.strings["clock.minutes"] = entry("%02d min · %.1f h", ja="分 · %.1f 時間")
        self.assert_finding("clock.minutes ja: tokens {1:%.1f} != English {1:%02d, 2:%.1f}")
        self.strings["clock.minutes"] = entry("%02d min · %.1f h", ko="%d분 · %.1f시간")
        self.assert_finding("clock.minutes ko: tokens {1:%d, 2:%.1f} != English {1:%02d, 2:%.1f}")
        self.strings["clock.minutes"] = entry("%02d min · %.1f h", uk="%2$.1f год · %1$02d хв")
        self.assertEqual(self.run_check().returncode, 0)

    def test_unsupported_conversion_fails(self):
        self.strings["app.title"] = entry("Workspaces", ru="Рабочие области 100%")
        self.assert_finding("app.title ru: unsupported format conversion '%'")
        self.strings["app.title"] = entry("Workspaces", ja="%*d")
        self.assert_finding("app.title ja: unsupported format conversion '%*d'")

    def test_english_unit_must_be_translated(self):
        self.strings["app.title"]["localizations"]["en"]["stringUnit"]["state"] = "new"
        self.assert_finding("app.title en: state 'new', not 'translated'")

    def test_protocol_prefixes_survive_translation(self):
        self.write("Sources/Proto.swift", '''
            let a = String(localized: "proto.error", defaultValue: "ERROR: Invalid workspace id.")
            let b = String(localized: "proto.code", defaultValue: "relay_busy: try again")
            let c = String(localized: "proto.label", defaultValue: "Debug: on")
            let d = String(localized: "proto.ok", defaultValue: "OK sent")
            if reply.hasPrefix("OK ") { }
            ''')
        self.strings.update({
            "proto.error": entry("ERROR: Invalid workspace id.", zh_Hant="錯誤：工作區 id 無效。"),
            "proto.code": entry("relay_busy: try again", zh_Hans="relay_busy：请重试"),
            "proto.label": entry("Debug: on", ja="デバッグ: オン"),
            "proto.ok": entry("OK sent", ko="확인 보냄"),
        })
        result = self.assert_finding("proto.error zh-Hant: must start with English's protocol prefix 'ERROR:'")
        self.assertIn("proto.code zh-Hans: must start with English's protocol prefix 'relay_busy:'", result.stdout)
        self.assertIn("proto.ok ko: must start with English's protocol prefix 'OK '", result.stdout)
        self.assertNotIn("proto.label", result.stdout)  # a translated label is not a protocol prefix

    def test_commented_out_and_quoted_calls_are_not_calls(self):
        self.write("Sources/Old.swift", '''
            // let a = String(localized: "gone.line", defaultValue: "x")
            /* let b = String(localized: "gone.block", defaultValue: "y") /* nested */ */
            let c = "String(localized: \\"gone.quoted\\", defaultValue: \\"z\\")"
            ''')
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_calls_in_interpolations_raw_and_multiline_literals_are_found(self):
        self.write("Sources/More.swift", '''
            let a = "prefix \\(String(localized: "nested.key", defaultValue: "Nested"))"
            let b = String(localized: #"raw.key"#, defaultValue: #"Raw "quoted""#)
            let c = String(localized: "multi.key", defaultValue: """
                Usage: c11 \\(command) [flags]

                Second line.
                """)
            ''')
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        for key in ("nested.key", "raw.key", "multi.key"):
            self.assertIn(f"{key}: no catalog entry", result.stdout)
        listed = {json.loads(line)["key"]: json.loads(line) for line in self.run_check("--list-missing").stdout.splitlines()}
        self.assertEqual(listed["raw.key"]["defaultValue"], 'Raw "quoted"')
        self.assertEqual(listed["multi.key"]["defaultValue"], "Usage: c11 \\(command) [flags]\n\nSecond line.")
        self.assertEqual(listed["multi.key"]["interpolations"], ["command"])

    def test_calls_split_across_lines_or_comments_are_found(self):
        self.write("Sources/Split.swift", '''
            let a = String(
                localized: "split.newline",
                defaultValue: "x")
            let b = String(/* why */ localized: "split.comment", defaultValue: "y")
            let c = String // a note
                ( localized : "split.spaced", defaultValue: "z")
            let d = "\\(String(
                localized: "split.nested",
                defaultValue: "n"))"
            let notACall = String(describing: x)
            let alsoNot = String(localizedDescription: "q")
            ''')
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("split.newline: no catalog entry (used at Sources/Split.swift:2)", result.stdout)
        for key in ("split.comment", "split.spaced", "split.nested"):
            self.assertIn(f"{key}: no catalog entry", result.stdout)
        self.assertIn("4 finding(s) across 8 keys and 8 calls", result.stdout)

    def test_a_key_that_is_an_expression_is_not_a_literal_key(self):
        self.write("Sources/Ternary.swift",
                   'let a = String(localized: "app.title" == selection ? "missing.a" : "missing.b", defaultValue: "Hello")\n')
        self.assert_finding("Sources/Ternary.swift:1: key is not a plain string literal")

    def test_list_missing_includes_entries_that_lack_a_locale(self):
        self.strings["app.title"] = entry("Workspaces", ko=None, ru=None)
        del self.strings["cli.move"]
        rows = [json.loads(line) for line in self.run_check("--list-missing").stdout.splitlines()]
        by_key = {r["key"]: r for r in rows}
        self.assertEqual(sorted(by_key), ["app.title", "cli.move"])
        self.assertEqual(by_key["app.title"]["lacking"], ["ko", "ru"])
        self.assertEqual(by_key["app.title"]["catalogEnglish"], "Workspaces")
        self.assertEqual(by_key["cli.move"]["lacking"], ["entry"])
        self.assertEqual(by_key["cli.move"]["interpolations"], ["a", '"--index"'])

    def test_non_literal_default_value_fails(self):
        self.write("Sources/Dyn.swift", 'let a = String(localized: "app.title", defaultValue: someValue)\n')
        self.assert_finding("Sources/Dyn.swift:1: app.title: defaultValue is not a string literal")

    def test_unreadable_catalog_fails_closed(self):
        self.run_check()
        for broken in ("{ not json", "null", "[]", '{"strings": null}'):
            (self.root / "Resources" / "Localizable.xcstrings").write_text(broken, encoding="utf-8")
            result = subprocess.run([sys.executable, str(CHECK), "--root", str(self.root)],
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
            self.assertEqual(result.returncode, 2, broken + ": " + result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
