#!/usr/bin/env ruby
# C11-181: register the agent-launch-picker source + test files in the Xcode project.
# The picker is AppKit/SwiftUI UI → sources compile into the `c11` app target ONLY
# (NOT c11-cli). The model test is pure logic → c11LogicTests (+ c11Tests host) for the
# fast local loop, mirroring c11-178/179. Idempotent.
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../GhosttyTabs.xcodeproj', __dir__)
project = Xcodeproj::Project.open(PROJECT_PATH)

c11        = project.targets.find { |t| t.name == 'c11' }            or abort 'c11 target not found'
c11_tests  = project.targets.find { |t| t.name == 'c11Tests' }       or abort 'c11Tests target not found'
c11_logic  = project.targets.find { |t| t.name == 'c11LogicTests' }  or abort 'c11LogicTests target not found'

sources_group = project.main_group.find_subpath('Sources', false) or abort 'Sources group missing'
tests_group   = project.main_group.find_subpath('c11Tests', false) or abort 'c11Tests group missing'

# AgentPickerView.swift is added by a later pass (it depends on the view being on disk).
SOURCE_FILES = %w[AgentPickerModel.swift AgentPickerView.swift].freeze
TEST_FILES   = %w[AgentPickerModelTests.swift].freeze

def ref_in(group, filename)
  group.files.find { |f| f.path == filename } || group.new_reference(filename)
end

def ensure_member(target, ref)
  return if target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
  target.source_build_phase.add_file_reference(ref)
end

# Only register sources that already exist on disk, so a partial run never breaks the build.
SOURCE_FILES.each do |fn|
  next unless File.exist?(File.expand_path("../Sources/#{fn}", __dir__))
  ref = ref_in(sources_group, fn)
  ensure_member(c11, ref)
end

TEST_FILES.each do |fn|
  next unless File.exist?(File.expand_path("../c11Tests/#{fn}", __dir__))
  ref = ref_in(tests_group, fn)
  ensure_member(c11_tests, ref)
  ensure_member(c11_logic, ref)
end

project.save
puts 'OK — registered existing picker source(s) into c11, test(s) into c11Tests + c11LogicTests'
