#!/usr/bin/env ruby
# C11-179: register the overlay-composition test file in the Xcode project.
# Pure logic → c11LogicTests ONLY (mirrors DefaultAgentLaunchCompositionTests;
# adding a pure-logic test to the host c11Tests target buys no coverage and
# adds DEV.app launch time). Idempotent.
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../GhosttyTabs.xcodeproj', __dir__)
project = Xcodeproj::Project.open(PROJECT_PATH)

c11_logic = project.targets.find { |t| t.name == 'c11LogicTests' } or abort 'c11LogicTests target not found'
tests_group = project.main_group.find_subpath('c11Tests', false) or abort 'c11Tests group missing'

TEST_FILES = %w[AgentLaunchOverlayCompositionTests.swift].freeze

def ref_in(group, filename)
  group.files.find { |f| f.path == filename } || group.new_reference(filename)
end

def ensure_member(target, ref)
  return if target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
  target.source_build_phase.add_file_reference(ref)
end

TEST_FILES.each do |fn|
  ref = ref_in(tests_group, fn)
  ensure_member(c11_logic, ref)
end

project.save
puts "OK — registered #{TEST_FILES.size} test(s) into c11LogicTests only"
