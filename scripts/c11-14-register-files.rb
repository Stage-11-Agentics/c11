#!/usr/bin/env ruby
# C11-14: register new Sources/ + c11Tests/ files in the Xcode project.
# Adds to c11 (app), c11Tests, and c11LogicTests targets. Idempotent.
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'

PROJECT_PATH = File.expand_path('../GhosttyTabs.xcodeproj', __dir__)
project = Xcodeproj::Project.open(PROJECT_PATH)

c11        = project.targets.find { |t| t.name == 'c11' }           or abort 'c11 target not found'
c11_tests  = project.targets.find { |t| t.name == 'c11Tests' }      or abort 'c11Tests target not found'
c11_logic  = project.targets.find { |t| t.name == 'c11LogicTests' } or abort 'c11LogicTests target not found'

sources_group = project.main_group.find_subpath('Sources', false) or abort 'Sources group missing'
tests_group   = project.main_group.find_subpath('c11Tests', false) or abort 'c11Tests group missing'

SOURCE_FILES = %w[
  DefaultAgentConfig.swift
  DefaultAgentResolver.swift
  DefaultAgentProjectConfig.swift
  DefaultAgentSettingsView.swift
].freeze

TEST_FILES = %w[
  DefaultAgentConfigTests.swift
  DefaultAgentResolverTests.swift
].freeze

def add_to_group_and_target(group:, target:, filename:)
  ref = group.files.find { |f| f.path == filename }
  ref ||= group.new_reference(filename)
  unless target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
    target.source_build_phase.add_file_reference(ref)
  end
  ref
end

SOURCE_FILES.each do |fn|
  add_to_group_and_target(group: sources_group, target: c11, filename: fn)
end

TEST_FILES.each do |fn|
  ref = add_to_group_and_target(group: tests_group, target: c11_tests, filename: fn)
  unless c11_logic.source_build_phase.files.any? { |bf| bf.file_ref == ref }
    c11_logic.source_build_phase.add_file_reference(ref)
  end
end

project.save
puts "OK — registered #{SOURCE_FILES.size} sources + #{TEST_FILES.size} tests"
