#!/usr/bin/env ruby
# Keep the backstop's measured CLI test step tied to the built binary.
require "yaml"

root = File.expand_path("..", __dir__)
workflow_path = File.join(root, ".github/workflows/ci-hourly.yml")
workflow = YAML.load_file(workflow_path)
steps = workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps", []) }
step = steps.find { |candidate| candidate["name"] == "CLI tests against the built binary" }
abort "FAIL: missing CLI tests against the built binary step" unless step

run = step.fetch("run", "")
required = [
  'C11_CLI_BIN="$CLI_BINARY" python3 tests/test_cli_window_scope.py',
  'C11_CLI_BIN="$CLI_BINARY" python3 tests/test_mailbox_body_cli.py "$CLI_BINARY"',
  'C11_CLI="$CLI_BINARY" python3 tests_v2/test_send_raw_and_flags.py --offline'
]
missing = required.reject { |command| run.lines.any? { |line| line.strip == command } }
abort "FAIL: CLI step is missing built-binary commands: #{missing.join('; ')}" unless missing.empty?

puts "PASS: backstop CLI test step runs all three harnesses against the built binary"
