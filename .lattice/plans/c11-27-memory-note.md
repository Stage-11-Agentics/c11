# C11-27 memory note — Strategy B requires the Debug dylib, not the app binary

C11-27 split `c11Tests` into a hostless logic bundle (`c11LogicTests`) plus the
original host-required bundle. "Strategy B" is the no-rewrite path the plan
chose: leave `@testable import c11` in every moved test, point `BUNDLE_LOADER`
at the host's product, and let dyld find that product via rpath at load time.

The plan's §2.3 spec said `BUNDLE_LOADER = $(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11`
in Debug. **That is wrong on Xcode 16+.** The `c11` target ships with
`ENABLE_DEBUG_DYLIB = YES`, so the Debug build splits app code into a thin
`c11` launcher stub plus `c11.debug.dylib`. The `@testable` Swift symbols live
in the dylib, not the stub — pointing `BUNDLE_LOADER` at the stub breaks
linking. Turning `ENABLE_DEBUG_DYLIB` off on the `c11` target to "match the
spec" is also wrong: it slows every other Debug build of the app to pay for
the test bundle.

The correct settings (live in `scripts/c11-27-split-tests.rb:140-152`):

- **Debug:**
  - `BUNDLE_LOADER = $(BUILT_PRODUCTS_DIR)/c11 DEV.app/Contents/MacOS/c11.debug.dylib`
  - `LD_RUNPATH_SEARCH_PATHS = $(inherited) @loader_path/../../../c11\ DEV.app/Contents/MacOS`
- **Release:**
  - `BUNDLE_LOADER = $(BUILT_PRODUCTS_DIR)/c11.app/Contents/MacOS/c11`
  - `LD_RUNPATH_SEARCH_PATHS = $(inherited) @loader_path/../../../c11.app/Contents/MacOS`

The rpath arithmetic: `xctest` loads the bundle as
`…/Build/Products/Debug/c11LogicTests.xctest/Contents/MacOS/c11LogicTests`.
From that binary, `@loader_path/../../../` resolves back to
`…/Build/Products/Debug/`, where `c11 DEV.app/Contents/MacOS/c11.debug.dylib`
actually sits. Same shape for Release with the un-suffixed app.

**Lesson for the next pbxproj-touching agent:** before writing a Test target
that uses `BUNDLE_LOADER`, check whether the host has `ENABLE_DEBUG_DYLIB = YES`.
If yes, point `BUNDLE_LOADER` at the dylib and add an rpath; don't fight the
build setting.
