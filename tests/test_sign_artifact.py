#!/usr/bin/env python3
"""Synthetic signing runner: executes the producer with fake platform tools."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "scripts/sign_artifact.py"
SIGNER = REPO / "scripts/sign-artifact.sh"
CANARY = "synthetic-secret-canary-312"

TOOL = r'''#!/usr/bin/env python3
import hashlib,json,os,plistlib,sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['CALL_LOG'],'a') as f: f.write(name+' '+(args[0] if args else '')+'\n')
if os.environ.get('FAIL_TOOL') == name: sys.exit(1)
if name == 'xcodebuild':
    if '-version' in args: print('Xcode 26.3\nBuild version fixture')
    else:
        app=Path('build/Build/Products/Release/c11.app/Contents');app.mkdir(parents=True)
        (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.stage11.c11',
            'CFBundleShortVersionString':os.environ.get('FIXTURE_VERSION','0.67.0'),'CFBundleVersion':'131'}))
        for n in ('c11','ghostty'):
            p=app/'Resources/bin'/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('fixture');p.chmod(0o755)
elif name == 'swift': print('synthetic-public-key')
elif name == 'uuidgen': print('synthetic-keychain-password')
elif name == 'ditto': Path(args[-1]).write_bytes(b'synthetic-notary-archive')
elif name == 'create-dmg': Path(args[-1],'c11 fixture.dmg').write_bytes(b'synthetic-dmg')
elif name == 'xcrun' and args[:2] == ['notarytool','submit']:
    print(json.dumps({'status':os.environ.get('NOTARY_STATUS','Accepted'),'id':'synthetic-id'}))
elif name == 'zig': print('0.15.2')
elif name == 'go': print('go version fixture')
'''

DAEMON = r'''#!/usr/bin/env python3
import hashlib,json,sys
from pathlib import Path
a=dict(zip(sys.argv[1::2],sys.argv[2::2]));d=Path(a['--output-dir']);d.mkdir(parents=True)
entries=[];checksums=''
for target in ('darwin-arm64','darwin-amd64','linux-arm64','linux-amd64'):
    name='c11d-remote-'+target;p=d/name;p.write_bytes(target.encode());h=hashlib.sha256(p.read_bytes()).hexdigest()
    entries.append({'assetName':name,'sha256':h,'downloadURL':'https://example.invalid/'+name})
    checksums+=h+'  '+name+'\n'
(d/'c11d-remote-checksums.txt').write_text(checksums)
(d/'c11d-remote-manifest.json').write_text(json.dumps({'appVersion':a['--version'],
    'releaseTag':a['--release-tag'],'entries':entries}))
'''

APPCAST = r'''#!/usr/bin/env python3
import os,plistlib,sys
from pathlib import Path
p=plistlib.loads(Path('build/Build/Products/Release/c11.app/Contents/Info.plist').read_bytes())
Path(sys.argv[3]).write_text('<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
    '<enclosure url="'+os.environ['DOWNLOAD_URL_PREFIX']+'c11-macos.dmg" length="'+str(Path(sys.argv[1]).stat().st_size)+
    '" sparkle:edSignature="synthetic-signature" sparkle:version="'+p['CFBundleVersion']+'"/></item></channel></rss>')
'''


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "source"
        self.root.mkdir()
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.runner = Path(self.tmp.name) / "runner"
        self.runner.mkdir()
        for name in ("xcodebuild", "swift", "uuidgen", "security", "codesign", "xcrun", "ditto", "spctl", "create-dmg", "zig", "go"):
            self.write(self.bin / name, TOOL)
        self.write(self.root / "scripts/download-prebuilt-ghosttykit.sh", "#!/bin/sh\nexit 0\n")
        self.write(self.root / "scripts/build_remote_daemon_release_assets.sh", DAEMON)
        self.write(self.root / "scripts/sparkle_generate_appcast.sh", APPCAST)
        self.write(self.root / "tests/test_cli_version_memory_guard.py", "# synthetic CLI fixture\n")
        for args in (("init", "-q"), ("add", "."), ("-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "commit", "-qm", "fixture")):
            subprocess.run(["git", "-C", str(self.root), *args], check=True)
        self.sha = subprocess.check_output(["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True).strip()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        SIGN_SOURCE_REF="synthetic-branch", SIGN_EXPECTED_SHA=self.sha,
                        SIGN_WORKFLOW_SHA="a" * 40, SIGN_PURPOSE="proof", SIGN_TARGET_TAG="",
                        SIGN_PROOF_BUILD="313", SIGN_PROOF_FEED_BASE="http://127.0.0.1:18731/proof",
                        SIGN_RUN_URL="https://example.invalid/run/1", GITHUB_RUN_ID="1", GITHUB_RUN_ATTEMPT="1",
                        RUNNER_TEMP=str(self.runner), CALL_LOG=str(self.runner / "calls"),
                        GITHUB_ENV=str(self.runner / "env"), GITHUB_STEP_SUMMARY=str(self.runner / "summary"))
        for name in ("APPLE_CERTIFICATE_PASSWORD", "APPLE_SIGNING_IDENTITY", "APPLE_ID", "APPLE_APP_SPECIFIC_PASSWORD", "APPLE_TEAM_ID", "SPARKLE_PRIVATE_KEY"):
            self.env[name] = CANARY
        self.env["APPLE_CERTIFICATE_BASE64"] = base64.b64encode(CANARY.encode()).decode()

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def run_signer(self, success=True):
        result = subprocess.run(["bash", str(SIGNER), str(self.root)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertNotIn(CANARY, result.stdout + result.stderr)
        self.assertFalse((self.runner / "c11-signing.p12").exists())
        self.assertFalse((self.runner / "c11-notary.zip").exists())
        if not success:
            self.assertFalse((self.root / "build/signed-artifact/signing-manifest.json").exists())
        return result

    def test_proof_assets_identity_hashes_and_secret_boundary(self):
        self.run_signer()
        d = self.root / "build/signed-artifact"
        m = json.loads((d / "signing-manifest.json").read_text())
        self.assertEqual(m["bundleID"], "com.stage11.c11.sparkle307")
        self.assertEqual(m["build"], "313")
        self.assertEqual(m["feedURL"], self.env["SIGN_PROOF_FEED_BASE"] + "/appcast.xml")
        self.assertEqual(m["sourceSHA"], self.sha)
        self.assertEqual(len(m["assets"]), 8)
        self.assertEqual(len(list(d.iterdir())), 10)
        for p in d.iterdir():
            self.assertNotIn(CANARY.encode(), p.read_bytes())
        for name, h in m["assets"].items():
            self.assertEqual(hashlib.sha256((d / name).read_bytes()).hexdigest(), h)
        self.assertIn("security delete-keychain", (self.runner / "calls").read_text())
        (d / "c11-macos.dmg").write_bytes(b"tampered")
        result = subprocess.run(["python3", str(HELPER), "verify", str(d)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_candidate_preserves_production_identity_and_final_urls(self):
        self.env.update(SIGN_PURPOSE="candidate", SIGN_TARGET_TAG="v1.0.0", SIGN_PROOF_BUILD="",
                        SIGN_PROOF_FEED_BASE="", FIXTURE_VERSION="1.0.0")
        self.run_signer()
        m = json.loads((self.root / "build/signed-artifact/signing-manifest.json").read_text())
        self.assertEqual(m["bundleID"], "com.stage11.c11")
        self.assertEqual(m["version"], "1.0.0")
        self.assertEqual(m["targetTag"], "v1.0.0")
        self.assertEqual(m["downloadURLPrefix"], "https://github.com/Stage-11-Agentics/c11/releases/download/v1.0.0/")
        self.assertIn("/releases/latest/", m["feedURL"])

    def test_sha_mismatch_fails_before_tools_or_secrets(self):
        self.env["SIGN_EXPECTED_SHA"] = "b" * 40
        self.run_signer(False)
        self.assertFalse((self.runner / "calls").exists())

    def test_proof_cannot_use_production_feed(self):
        self.env["SIGN_PROOF_FEED_BASE"] = "https://github.com/Stage-11-Agentics/c11/releases/latest/download"
        self.run_signer(False)
        self.assertFalse((self.runner / "calls").exists())

    def test_candidate_version_tag_mismatch(self):
        self.env.update(SIGN_PURPOSE="candidate", SIGN_TARGET_TAG="v1.0.0", SIGN_PROOF_BUILD="", SIGN_PROOF_FEED_BASE="")
        self.run_signer(False)

    def test_missing_secret_fails_before_build(self):
        self.env["APPLE_CERTIFICATE_PASSWORD"] = ""
        self.run_signer(False)
        self.assertFalse((self.runner / "calls").exists())

    def test_codesign_failure_cleans_up_without_artifact(self):
        self.env["FAIL_TOOL"] = "codesign"
        self.run_signer(False)
        self.assertIn("security delete-keychain", (self.runner / "calls").read_text())

    def test_notary_rejection_cleans_up_without_artifact(self):
        self.env["NOTARY_STATUS"] = "Invalid"
        self.run_signer(False)
        self.assertIn("security delete-keychain", (self.runner / "calls").read_text())


if __name__ == "__main__":
    unittest.main()
