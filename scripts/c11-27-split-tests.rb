#!/usr/bin/env ruby
# C11-27: mint a new c11LogicTests target and move PURE tests into it.
# Idempotent: re-running finds the existing target instead of duplicating it.
# Strategy is chosen by env var (default B, no per-file edits to existing tests).
#   STRATEGY=B  -> BUNDLE_LOADER points at the c11 host's link artifact, c11 is
#                  a target dep. Because c11 has ENABLE_DEBUG_DYLIB=YES, Debug
#                  points at c11 DEV.app/Contents/MacOS/c11.debug.dylib (with
#                  an rpath so dyld can find it); Release points at the
#                  classic c11.app/Contents/MacOS/c11 stub. See the inline
#                  block at lines 140-152 for the rpath arithmetic.
#   STRATEGY=A  -> dual-compile Sources/ files listed in c11-27-sources.txt.
# INCLUDE_VERIFY_PROMOTE=1 also moves the one VERIFY-PROMOTE test
#   (TerminalControllerSocketSecurityTests).
gem 'xcodeproj', '~> 1.27'
require 'xcodeproj'

STRATEGY = ENV.fetch('STRATEGY', 'B')
abort "STRATEGY must be A or B" unless %w[A B].include?(STRATEGY)

PROJECT_PATH = File.expand_path('../GhosttyTabs.xcodeproj', __dir__)
project = Xcodeproj::Project.open(PROJECT_PATH)

c11_app        = project.targets.find { |t| t.name == 'c11' }      or abort 'c11 not found'
existing_tests = project.targets.find { |t| t.name == 'c11Tests' } or abort 'c11Tests not found'
tests_group    = project.main_group.find_subpath('c11Tests', false) or abort 'c11Tests group not found'

PURE_FILES = %w[
  AgentRestartRegistryTests.swift
  BrowserChromeSnapshotTests.swift
  BrowserFindJavaScriptTests.swift
  BrowserImportMappingTests.swift
  C11ThemeLoaderTests.swift
  ChromeScaleObserverTests.swift
  ChromeScaleSettingsTests.swift
  ChromeScaleTokensTests.swift
  CLIAdvisoryConnectivityTests.swift
  CLIHealthRuntimeTests.swift
  CLIResolutionSnapshotTests.swift
  CommandPaletteSearchEngineTests.swift
  DefaultGridSettingsTests.swift
  DescriptionSanitizerTests.swift
  HealthFlagsTests.swift
  HealthIPSParserTests.swift
  HealthMetricKitParserTests.swift
  HealthSentinelParserTests.swift
  HealthSentryParserTests.swift
  LegacyPrefsMigrationGateTests.swift
  MailboxDispatcherGCTests.swift
  MailboxDispatcherTests.swift
  MailboxDispatchLogTests.swift
  MailboxEnvelopeValidationTests.swift
  MailboxIOTests.swift
  MailboxLayoutTests.swift
  MailboxOutboxWatcherTests.swift
  MailboxSurfaceResolverTests.swift
  MailboxULIDTests.swift
  MetadataPersistencePrecedenceTests.swift
  MetadataPersistenceRoundTripTests.swift
  MetadataPersistenceUncoercibleTests.swift
  MetadataStoreRevisionCounterTests.swift
  PaneInteractionRuntimeTests.swift
  PanelIdentityRestoreTests.swift
  PaneMetadataPersistenceTests.swift
  PaneMetadataStoreTests.swift
  SessionEndShutdownPolicyTests.swift
  SessionPersistenceTests.swift
  SidebarWidthPolicyTests.swift
  SocketControlPasswordStoreTests.swift
  StatusBarButtonDisplayTests.swift
  StatusEntryPersistenceTests.swift
  StdinHandlerFormattingTests.swift
  SurfaceMetadataStoreValidationTests.swift
  TabManagerSessionSnapshotTests.swift
  TCCPrimerTests.swift
  TerminalControllerTelemetryWorkerTests.swift
  ThemeCycleAndInvalidValueTests.swift
  ThemedValueParserTests.swift
  ThemeRegistryTests.swift
  TitlebarSnapshotTests.swift
  TomlSubsetParserFuzzTests.swift
  TomlSubsetParserTests.swift
  WorkspaceApplyChromeScaleTests.swift
  WorkspaceApplyPlanCodableTests.swift
  WorkspaceBlueprintFileCodableTests.swift
  WorkspaceBlueprintMarkdownTests.swift
  WorkspaceBlueprintStoreTests.swift
  WorkspaceContentViewVisibilityTests.swift
  WorkspaceIdentityRestoreTests.swift
  WorkspaceLayoutExecutorAcceptanceTests.swift
  WorkspaceMetadataValidatorTests.swift
  WorkspacePullRequestSidebarTests.swift
  WorkspaceRemoteConnectionTests.swift
  WorkspaceRestartCommandsTests.swift
  WorkspaceSnapshotBrowserMarkdownRoundTripTests.swift
  WorkspaceSnapshotCaptureTests.swift
  WorkspaceSnapshotConverterTests.swift
  WorkspaceSnapshotRoundTripAcceptanceTests.swift
  WorkspaceSnapshotSetCodableTests.swift
  WorkspaceSnapshotStoreSecurityTests.swift
  WorkspaceStressProfileTests.swift
].freeze

# Only candidate left after re-audit; gated on INCLUDE_VERIFY_PROMOTE=1
# (caller has already dropped `import AppKit` and confirmed it builds).
VERIFY_PROMOTE_FILES = %w[
  TerminalControllerSocketSecurityTests.swift
].freeze

# Strategy A only: Sources/ files to dual-compile into c11LogicTests.
STRATEGY_A_SOURCES =
  if STRATEGY == 'A'
    sources_path = File.expand_path('../.lattice/plans/c11-27-sources.txt', __dir__)
    abort "STRATEGY=A requires #{sources_path} (run §1.5 audit then derive: awk '{print $3}' c11-27-deps.txt | sort -u > c11-27-sources.txt)" unless File.exist?(sources_path)
    lines = File.readlines(sources_path).map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
    abort "STRATEGY=A: #{sources_path} is empty" if lines.empty?
    lines.freeze
  else
    [].freeze
  end

# Idempotent: re-running finds the existing target.
new_target = project.targets.find { |t| t.name == 'c11LogicTests' } ||
             project.new_target(:unit_test_bundle, 'c11LogicTests', :osx, '14.0', nil)

if STRATEGY == 'B' && new_target.dependencies.none? { |d| d.target == c11_app }
  new_target.add_dependency(c11_app)
end

%w[Debug Release].each do |config_name|
  bc = new_target.build_configurations.find { |c| c.name == config_name }
  bc.build_settings.merge!(
    'GENERATE_INFOPLIST_FILE'    => 'YES',
    'PRODUCT_BUNDLE_IDENTIFIER'  => 'com.stage11.c11.logictests',
    'PRODUCT_NAME'               => '$(TARGET_NAME)',
    'CURRENT_PROJECT_VERSION'    => '101',
    'MARKETING_VERSION'          => '0.47.1',
    'MACOSX_DEPLOYMENT_TARGET'   => '14.0',
    'SWIFT_VERSION'              => '5.0',
    'CODE_SIGN_STYLE'            => 'Automatic',
  )
  bc.build_settings['ONLY_ACTIVE_ARCH'] = (config_name == 'Debug' ? 'YES' : 'NO')
  bc.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG $(inherited)' if config_name == 'Debug'
  # Defensive: explicitly clear; a future xcconfig at the project level
  # could otherwise inject these and re-host the bundle.
  bc.build_settings['TEST_HOST'] = ''
  bc.build_settings.delete('TEST_TARGET_NAME')
  if STRATEGY == 'B'
    # Debug uses ENABLE_DEBUG_DYLIB on the c11 target: the Swift code sits in
    # c11.debug.dylib alongside a small `c11` stub. BUNDLE_LOADER needs to point
    # at the dylib so the linker can resolve `@testable` symbols at link time;
    # rpath then lets dyld find the dylib at test load time.
    if config_name == 'Debug'
      bc.build_settings['BUNDLE_LOADER'] = '$(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11.debug.dylib'
      bc.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @loader_path/../../../c11\ DEV.app/Contents/MacOS'
    else
      bc.build_settings['BUNDLE_LOADER'] = '$(BUILT_PRODUCTS_DIR)/c11.app/Contents/MacOS/c11'
      bc.build_settings['LD_RUNPATH_SEARCH_PATHS'] = '$(inherited) @loader_path/../../../c11.app/Contents/MacOS'
    end
  else
    bc.build_settings['BUNDLE_LOADER'] = ''
  end
end

# Move file membership from c11Tests to c11LogicTests. Idempotent.
verify_promote_kept = (ENV['INCLUDE_VERIFY_PROMOTE'] == '1') ? VERIFY_PROMOTE_FILES : []
moved_count = 0
(PURE_FILES + verify_promote_kept).each do |filename|
  ref = tests_group.files.find { |f| f.path == filename } or abort "missing ref: #{filename}"
  next if new_target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
  build_file = existing_tests.source_build_phase.files.find { |bf| bf.file_ref == ref }
  existing_tests.source_build_phase.remove_build_file(build_file) if build_file
  new_target.source_build_phase.add_file_reference(ref)
  moved_count += 1
end

if STRATEGY == 'A'
  STRATEGY_A_SOURCES.each do |path|
    expected = path.sub(/^\.?\//, '')
    ref = project.files.find { |f| f.real_path.to_s.end_with?('/' + expected) || f.path == expected }
    abort "Strategy A: source not in project: #{path}" if ref.nil?
    next if new_target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
    new_target.source_build_phase.add_file_reference(ref)
  end

  worktree_root = File.expand_path('..', __dir__)
  (PURE_FILES + verify_promote_kept).each do |filename|
    path = File.join(worktree_root, 'c11Tests', filename)
    next unless File.exist?(path)
    content = File.read(path)
    new_content = content
      .gsub(/^@testable import c11(_DEV)?\b.*\n/, '')
      .gsub(/^#if canImport\(c11_DEV\)\n@testable import c11_DEV\n#elseif canImport\(c11\)\n@testable import c11\n#endif\n/, '')
    File.write(path, new_content) if new_content != content
  end

  remaining_testable = (PURE_FILES + verify_promote_kept).select do |filename|
    path = File.join(worktree_root, 'c11Tests', filename)
    File.exist?(path) && File.read(path).match?(/@testable import c11(_DEV)?\b/)
  end
  abort "Strategy A: failed to strip @testable import from: #{remaining_testable.join(', ')}" unless remaining_testable.empty?

  remaining_canimport = (PURE_FILES + verify_promote_kept).select do |filename|
    path = File.join(worktree_root, 'c11Tests', filename)
    File.exist?(path) && File.read(path).match?(/^#if canImport\(c11(_DEV)?\)/)
  end
  abort "Strategy A: orphan #if canImport(c11...) blocks in: #{remaining_canimport.join(', ')}" unless remaining_canimport.empty?
end

project.save
puts "wrote target c11LogicTests under Strategy #{STRATEGY}; moved #{moved_count} new file(s)"
