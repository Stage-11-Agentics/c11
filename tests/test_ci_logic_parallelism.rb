#!/usr/bin/env ruby
require "yaml"

root = File.expand_path("..", __dir__)
workflow = YAML.load_file(File.join(root, ".github/workflows/ci-hourly.yml"))
steps = workflow.fetch("jobs").fetch("logic").fetch("steps")
logic = steps.find { |step| step["name"] == "Logic tests (gate)" }
abort "ci-hourly.yml has no logic test step" unless logic

run = logic.fetch("run")
abort "logic tests must enable parallel testing" unless run.include?("-parallel-testing-enabled YES")
abort "ci-hourly.yml logic lane must use three workers" unless run.include?("-parallel-testing-worker-count 3")

puts "PASS: ci-hourly c11-logic lane uses three parallel workers"
