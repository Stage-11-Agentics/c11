#!/usr/bin/env ruby
# Keep the parallel CLI checks tied to the binary built for this exact head.
require "yaml"

root = File.expand_path("..", __dir__)
workflow_path = File.join(root, ".github/workflows/ci-hourly.yml")
workflow = YAML.load_file(workflow_path)
python_job = workflow.fetch("jobs").fetch("python")
steps = python_job.fetch("steps")
build_step = steps.find { |candidate| candidate["name"] == "Locate CLI binary from exact-head build" }
abort "FAIL: missing exact-head CLI lookup step in the Python job" unless build_step
step = steps.find { |candidate| candidate["name"] == "CLI tests against the built binary" }
abort "FAIL: missing CLI tests against the built binary step" unless step

build_run = build_step.fetch("run", "")
abort "FAIL: exact-head CLI lookup must export CLI_BINARY for following steps" unless
  build_run.include?('CLI_BINARY=') && build_run.include?('"$GITHUB_ENV"')
abort "FAIL: CLI lookup must not build independently" if build_run.include?("xcodebuild")
abort "FAIL: Python job must restore the exact-head prebuilt-products cache" unless
  steps.any? { |step| step["name"] == "Restore exact-head prebuilt products" }

run = step.fetch("run", "")
required = [
  'launch_cli_test ssh-shell env C11_CLI_BIN="$CLI_BINARY" python3 tests/test_cli_ssh_shell_bootstrap.py',
  'launch_cli_test focus-history env C11_CLI_BIN="$CLI_BINARY" python3 tests/test_cli_focus_history.py',
  'launch_cli_test window-scope env C11_CLI_BIN="$CLI_BINARY" python3 tests/test_cli_window_scope.py',
  'launch_cli_test activity-analysis env C11_CLI_BIN="$CLI_BINARY" python3 tests/test_cli_activity_analysis.py',
  'launch_cli_test mailbox-body env C11_CLI_BIN="$CLI_BINARY" python3 tests/test_mailbox_body_cli.py "$CLI_BINARY"',
  'launch_cli_test send-raw env C11_CLI="$CLI_BINARY" python3 tests_v2/test_send_raw_and_flags.py --offline'
]
missing = required.reject { |command| run.lines.any? { |line| line.strip == command } }
abort "FAIL: CLI step is missing built-binary commands: #{missing.join('; ')}" unless missing.empty?
abort "FAIL: CLI scripts must run in the background with per-script logs" unless
  run.include?('"$@" > "$log" 2>&1 &') && run.include?('logs+=("$log")')
abort "FAIL: CLI step must wait for every process and collect all exit statuses" unless
  run.include?('wait "${pids[$i]}"') && run.include?('failures=$((failures + 1))')
abort "FAIL: CLI step must print every script log" unless run.include?('cat "${logs[$i]}"')
abort "FAIL: CLI step must not re-query Xcode build settings" if run.include?("-showBuildSettings")

puts "PASS: Python job runs all six scripts concurrently against the exact-head CLI build"
