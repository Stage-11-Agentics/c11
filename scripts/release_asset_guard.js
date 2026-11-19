"use strict";

const IMMUTABLE_RELEASE_ASSETS = [
  "c11-macos.dmg",
  "appcast.xml",
  "c11d-remote-darwin-arm64",
  "c11d-remote-darwin-amd64",
  "c11d-remote-linux-arm64",
  "c11d-remote-linux-amd64",
  "c11d-remote-checksums.txt",
  "c11d-remote-manifest.json",
];
// C11H-392: a release made with --remote-artifacts (scripts/release-local.sh)
// also carries the Linux machine's hc and relay CLI, which its app names by hash
// (scripts/c11-remote-artifacts.sh). They are immutable like the rest.
const LINUX_MACHINE_ASSETS = [
  "herdr-core-linux-x86_64",
  "c11-linux-x86_64",
  "c11-linux-checksums.txt",
];
function releaseAssetNames({ linux = false } = {}) {
  return linux ? [...IMMUTABLE_RELEASE_ASSETS, ...LINUX_MACHINE_ASSETS] : [...IMMUTABLE_RELEASE_ASSETS];
}
const RELEASE_ASSET_GUARD_STATE = Object.freeze({
  CLEAR: "clear",
  PARTIAL: "partial",
  COMPLETE: "complete",
});

function evaluateReleaseAssetGuard({ existingAssetNames, immutableAssetNames = IMMUTABLE_RELEASE_ASSETS }) {
  const immutableAssets = immutableAssetNames || IMMUTABLE_RELEASE_ASSETS;
  const existing = new Set(existingAssetNames || []);
  const conflicts = immutableAssets.filter((assetName) => existing.has(assetName));
  const missingImmutableAssets = immutableAssets.filter((assetName) => !existing.has(assetName));

  let guardState = RELEASE_ASSET_GUARD_STATE.CLEAR;
  if (conflicts.length === immutableAssets.length && immutableAssets.length > 0) {
    guardState = RELEASE_ASSET_GUARD_STATE.COMPLETE;
  } else if (conflicts.length > 0) {
    guardState = RELEASE_ASSET_GUARD_STATE.PARTIAL;
  }

  return {
    conflicts,
    missingImmutableAssets,
    guardState,
    hasPartialConflict: guardState === RELEASE_ASSET_GUARD_STATE.PARTIAL,
    shouldSkipBuildAndUpload: guardState === RELEASE_ASSET_GUARD_STATE.COMPLETE,
    shouldSkipUpload: guardState === RELEASE_ASSET_GUARD_STATE.COMPLETE,
  };
}

module.exports = {
  IMMUTABLE_RELEASE_ASSETS,
  LINUX_MACHINE_ASSETS,
  releaseAssetNames,
  RELEASE_ASSET_GUARD_STATE,
  evaluateReleaseAssetGuard,
};
