#!/usr/bin/env ruby
require "yaml"
require "fileutils"
require "open3"
require "tmpdir"

root = File.expand_path("..", __dir__)
workflow = YAML.load_file(File.join(root, ".github/workflows/ci-hourly.yml"))
jobs = workflow.fetch("jobs")
test_jobs = %w[logic host-a host-b python]
expected_jobs = %w[build logic host-a host-b python record-green]
missing = expected_jobs - jobs.keys
abort "backstop is missing jobs: #{missing.join(', ')}" unless missing.empty?
macos_test_jobs = jobs.select do |name, job|
  name != "build" && job["runs-on"] == "macos-15" && Array(job["needs"]).include?("build")
end.keys
abort "expected exactly four macOS test jobs, found #{macos_test_jobs.join(', ')}" unless
  macos_test_jobs.sort == test_jobs.sort

setup = "./.github/actions/c11-macos-backstop-setup"
(test_jobs + ["build"]).each do |name|
  job = jobs.fetch(name)
  abort "#{name} must run on macos-15" unless job["runs-on"] == "macos-15"
  abort "#{name} must wait for the target and build jobs" unless
    job.fetch("needs").include?("target") && (name == "build" || job.fetch("needs").include?("build"))
  uses_setup = job.fetch("steps").any? { |step| step["uses"] == setup }
  abort "#{name} must prepare the macOS backstop toolchain" unless uses_setup
end

build_steps = jobs.fetch("build").fetch("steps")
previous_cache = build_steps.find { |step| step["name"] == "Restore the closest backstop DerivedData" }
restore_keys = previous_cache && previous_cache.fetch("with").fetch("restore-keys").lines.map(&:strip)
broad_restore_key = "c11-backstop-deriveddata-${{ runner.os }}-${{ steps.runner-setup.outputs.xcode-version }}-"
abort "build job must reuse the closest exact-head DerivedData cache" unless
  previous_cache && previous_cache.fetch("uses").start_with?("actions/cache/restore@") &&
    restore_keys.include?(broad_restore_key)
abort "build job must restore and save DerivedData once" unless
  build_steps.count { |step| step.fetch("uses", "").start_with?("actions/cache/restore@") } == 1 &&
    build_steps.count { |step| step.fetch("uses", "").start_with?("actions/cache/save@") } == 1
%w[logic host].each do |suite|
  step = build_steps.find { |candidate| candidate["name"] == "Build #{suite} test products" }
  abort "build job must prebuild #{suite} test products" unless
    step && step.fetch("run").include?("build-for-testing")
end
save = build_steps.find { |step| step["name"] == "Save exact-head DerivedData for test jobs" }
abort "build job must save exact-head DerivedData" unless
  save && save.fetch("uses").start_with?("actions/cache/save@") &&
    save.fetch("with").fetch("key").include?("env.TARGET_SHA") &&
    save.fetch("with").fetch("key").include?("steps.runner-setup.outputs.dependency-key")

test_jobs.each do |name|
  setup_step = jobs.fetch(name).fetch("steps").find { |step| step["uses"] == setup }
  abort "#{name} should use the exact-head cache instead of the general build cache" unless
    setup_step && setup_step.fetch("with").fetch("use-build-cache") == false
  restore = jobs.fetch(name).fetch("steps").find { |step| step["name"] == "Restore exact-head prebuilt products" }
  abort "#{name} must require the exact-head DerivedData cache" unless
    restore && restore.fetch("uses").start_with?("actions/cache/restore@") &&
      restore.fetch("with").fetch("fail-on-cache-miss") == true &&
      restore.fetch("with").fetch("key").include?("env.TARGET_SHA") &&
      restore.fetch("with").fetch("key").include?("steps.runner-setup.outputs.dependency-key")
end

setup_action = YAML.load_file(File.join(root, ".github/actions/c11-macos-backstop-setup/action.yml"))
dependency_output = setup_action.fetch("outputs").fetch("dependency-key")
abort "runner setup must expose its dependency-scoped cache key" unless
  dependency_output.fetch("value").include?("steps.select-xcode.outputs.dependency-key")
select_xcode = setup_action.fetch("runs").fetch("steps").find { |step| step["id"] == "select-xcode" }
dependency_script = select_xcode.fetch("run")
abort "runner setup must calculate the dependency key with the shared helper" unless
  dependency_script.include?("scripts/ci-deriveddata-dependency-key.sh")
cache = setup_action.fetch("runs").fetch("steps").find { |step| step["name"] == "Cache DerivedData" }
abort "the composite must not restore or save a second DerivedData cache" if cache

dependency_helper = File.join(root, "scripts/ci-deriveddata-dependency-key.sh")
Dir.mktmpdir("c11-dependency-key-") do |fixture|
  inputs = {
    "Package.resolved" => "root package pins",
    "GhosttyTabs.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" => "workspace package pins",
    "Package.swift" => "package manifest",
    "GhosttyTabs.xcodeproj/project.pbxproj" => "project build settings"
  }
  inputs.each do |relative_path, contents|
    path = File.join(fixture, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  fake_bin = File.join(fixture, "bin")
  FileUtils.mkdir_p(fake_bin)
  fake_git = File.join(fake_bin, "git")
  File.write(fake_git, <<~SH)
    #!/bin/sh
    case "$2" in
      HEAD:ghostty) printf '%s\\n' "$C11_TEST_GHOSTTY_SHA" ;;
      HEAD:vendor/bonsplit) printf '%s\\n' "$C11_TEST_BONSPLIT_SHA" ;;
      *) echo "unexpected git invocation: $*" >&2; exit 2 ;;
    esac
  SH
  FileUtils.chmod(0o755, fake_git)
  fake_env = {
    "PATH" => "#{fake_bin}:#{ENV.fetch('PATH')}",
    "C11_TEST_GHOSTTY_SHA" => "a" * 40,
    "C11_TEST_BONSPLIT_SHA" => "b" * 40
  }
  key_for = lambda do
    stdout, stderr, status = Open3.capture3(fake_env, dependency_helper, fixture)
    abort "dependency-key helper failed: #{stderr}" unless status.success?
    key = stdout.strip
    abort "dependency-key helper returned an invalid digest" unless key.match?(/\A[0-9a-f]{64}\z/)
    key
  end

  previous_key = key_for.call
  inputs.keys.reject { |relative_path| relative_path == "GhosttyTabs.xcodeproj/project.pbxproj" }.each do |relative_path|
    path = File.join(fixture, relative_path)
    File.write(path, File.read(path) + " changed")
    current_key = key_for.call
    abort "DerivedData dependency key ignored #{relative_path}" if current_key == previous_key
    previous_key = current_key
  end
  project_file = File.join(fixture, "GhosttyTabs.xcodeproj/project.pbxproj")
  File.write(project_file, File.read(project_file) + " changed")
  abort "DerivedData dependency key should not change with project.pbxproj" unless key_for.call == previous_key
  %w[C11_TEST_GHOSTTY_SHA C11_TEST_BONSPLIT_SHA].each_with_index do |name, index|
    fake_env[name] = (index == 0 ? "c" : "d") * 40
    current_key = key_for.call
    abort "DerivedData dependency key ignored #{name}" if current_key == previous_key
    previous_key = current_key
  end
end

abort "expected exactly four test jobs" unless test_jobs.length == 4
host_a = jobs.fetch("host-a").fetch("steps").find { |step| step["name"] == "Host A unit tests (gate)" }
host_b = jobs.fetch("host-b").fetch("steps").find { |step| step["name"] == "Host B shortcut-routing tests (gate)" }
logic = jobs.fetch("logic").fetch("steps").find { |step| step["name"] == "Logic tests (gate)" }
abort "host A must exclude shortcut routing" unless
  host_a && host_a.fetch("run").include?("-only-testing:c11Tests") &&
    host_a.fetch("run").include?("-skip-testing:c11Tests/AppDelegateShortcutRoutingTests")
abort "host B must run the shortcut-routing group alone" unless
  host_b && host_b.fetch("run").include?("-only-testing:c11Tests/AppDelegateShortcutRoutingTests")
{ "logic" => logic, "host-a" => host_a, "host-b" => host_b }.each do |name, step|
  abort "#{name} must execute the exact-head prebuilt test products" unless
    step && step.fetch("run").include?("test-without-building")
end

{ "logic" => "c11-logic", "host-a" => "c11-host-a", "host-b" => "c11-host-b" }.each do |name, artifact_name|
  artifact = jobs.fetch(name).fetch("steps").find do |step|
    step.fetch("uses", "").start_with?("actions/upload-artifact@")
  end
  abort "#{name} must upload its xcresult after failure" unless
    artifact && artifact.fetch("if").include?("failure()") &&
      artifact.fetch("with").fetch("name") == "#{artifact_name}-xcresult" &&
      artifact.fetch("with").fetch("path").include?("Logs/Test/*.xcresult")
end

python_steps = jobs.fetch("python").fetch("steps").map { |step| step["name"] }
abort "Python job must run CLI and shell checks" unless
  python_steps.include?("Locate CLI binary from exact-head build") &&
  python_steps.include?("CLI tests against the built binary") &&
    python_steps.include?("Shell helper lifetime and git reporting")

record = jobs.fetch("record-green")
record_needs = record.fetch("needs")
abort "green status must wait for every test job" unless (test_jobs + ["build", "target"]).all? { |name| record_needs.include?(name) }
abort "record-green must retain implicit success gating" if record.fetch("if", "").include?("always()")
record_step = record.fetch("steps").find { |step| step["name"] == "Record green for the tested commit" }
abort "green status must remain success-only" unless record_step && record_step.fetch("run").include?("state=success")

puts "PASS: one exact-head build feeds four independent test jobs; green waits for all four"
