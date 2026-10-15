#!/usr/bin/env ruby
require "yaml"

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
  abort "#{name} must restore the shared DerivedData cache" unless uses_setup
end

build_steps = jobs.fetch("build").fetch("steps")
%w[logic host].each do |suite|
  step = build_steps.find { |candidate| candidate["name"] == "Build #{suite} test products" }
  abort "build job must prebuild #{suite} test products" unless
    step && step.fetch("run").include?("build-for-testing")
end
save = build_steps.find { |step| step["name"] == "Save exact-head DerivedData for test jobs" }
abort "build job must save exact-head DerivedData" unless
  save && save.fetch("uses").start_with?("actions/cache/save@") &&
    save.fetch("with").fetch("key").include?("env.TARGET_SHA")

test_jobs.each do |name|
  setup_step = jobs.fetch(name).fetch("steps").find { |step| step["uses"] == setup }
  abort "#{name} should use the exact-head cache instead of the general build cache" unless
    setup_step && setup_step.fetch("with").fetch("use-build-cache") == false
  restore = jobs.fetch(name).fetch("steps").find { |step| step["name"] == "Restore exact-head prebuilt products" }
  abort "#{name} must require the exact-head DerivedData cache" unless
    restore && restore.fetch("uses").start_with?("actions/cache/restore@") &&
      restore.fetch("with").fetch("fail-on-cache-miss") == true &&
      restore.fetch("with").fetch("key").include?("env.TARGET_SHA")
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

python_steps = jobs.fetch("python").fetch("steps").map { |step| step["name"] }
abort "Python job must run CLI and shell checks" unless
  python_steps.include?("Locate CLI binary from exact-head build") &&
  python_steps.include?("CLI tests against the built binary") &&
    python_steps.include?("Shell helper lifetime and git reporting")

record = jobs.fetch("record-green")
record_needs = record.fetch("needs")
abort "green status must wait for every test job" unless (test_jobs + ["build", "target"]).all? { |name| record_needs.include?(name) }
record_step = record.fetch("steps").find { |step| step["name"] == "Record green for the tested commit" }
abort "green status must remain success-only" unless record_step && record_step.fetch("run").include?("state=success")

puts "PASS: one exact-head build feeds four independent test jobs; green waits for all four"
