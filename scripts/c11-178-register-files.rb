#!/usr/bin/env ruby
# C11-178: register the launch-stats-rail source + test files in the Xcode project.
# Source compiles into BOTH c11 (app) and c11-cli (app-down CLI-readable); the
# test file joins c11Tests + c11LogicTests (pure logic → fast local loop). Idempotent.
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../GhosttyTabs.xcodeproj', __dir__)
project = Xcodeproj::Project.open(PROJECT_PATH)

c11        = project.targets.find { |t| t.name == 'c11' }            or abort 'c11 target not found'
c11_cli    = project.targets.find { |t| t.name == 'c11-cli' }        or abort 'c11-cli target not found'
c11_tests  = project.targets.find { |t| t.name == 'c11Tests' }       or abort 'c11Tests target not found'
c11_logic  = project.targets.find { |t| t.name == 'c11LogicTests' }  or abort 'c11LogicTests target not found'

sources_group = project.main_group.find_subpath('Sources', false) or abort 'Sources group missing'
tests_group   = project.main_group.find_subpath('c11Tests', false) or abort 'c11Tests group missing'

SOURCE_FILES = %w[AgentLaunchStats.swift].freeze
TEST_FILES   = %w[AgentLaunchStatsTests.swift].freeze

def ref_in(group, filename)
  group.files.find { |f| f.path == filename } || group.new_reference(filename)
end

def ensure_member(target, ref)
  return if target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
  target.source_build_phase.add_file_reference(ref)
end

SOURCE_FILES.each do |fn|
  ref = ref_in(sources_group, fn)
  ensure_member(c11, ref)
  ensure_member(c11_cli, ref)
end

TEST_FILES.each do |fn|
  ref = ref_in(tests_group, fn)
  ensure_member(c11_tests, ref)
  ensure_member(c11_logic, ref)
end

project.save
puts "OK — registered #{SOURCE_FILES.size} source(s) into c11 + c11-cli, #{TEST_FILES.size} test(s) into c11Tests + c11LogicTests"
