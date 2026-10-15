#!/usr/bin/env ruby
require "yaml"

root = File.expand_path("..", __dir__)
workflow = YAML.load_file(File.join(root, ".github/workflows/ci-hourly.yml"))
steps = workflow.fetch("jobs").fetch("build").fetch("steps")
logic = steps.find { |step| step["run"]&.include?("-scheme c11-logic") }
abort "ci-hourly.yml has no c11-logic test step" unless logic

run = logic.fetch("run")
abort "logic tests must enable parallel testing" unless run.include?("-parallel-testing-enabled YES")
abort "ci-hourly.yml logic lane must use three workers" unless run.include?("-parallel-testing-worker-count 3")

puts "ci-hourly c11-logic lane uses three parallel workers"
