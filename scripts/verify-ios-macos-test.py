#!/usr/bin/env python3
"""Linux-safe contract tests. Synthetic fixtures do not represent an iOS build."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('ios_resources', ROOT / 'scripts/verify-ios-resources.py')
RESOURCES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESOURCES)


class ScriptGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        self.script = self.root / 'scripts/verify-ios-macos.sh'
        shutil.copy(ROOT / 'scripts/verify-ios-macos.sh', self.script)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.marker = self.root / 'sdk-called'
        # The fixture host is explicitly Linux, even if this test runs on a Mac.
        self.fake_tool('uname', 'echo Linux')
        for tool in ('flutter', 'pod', 'xcodebuild', 'xcrun', 'xcode-select'):
            self.fake_tool(tool, 'touch "$SDK_CALL_MARKER"; exit 99')
        self.environment = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                                SDK_CALL_MARKER=str(self.marker), FLUTTER_BIN='flutter',
                                VERIFY_IOS_REPORT_DIR=str(self.root / 'reports'))

    def tearDown(self):
        self.temp.cleanup()

    def fake_tool(self, name, body):
        target = self.bin / name
        target.write_text(f'#!/usr/bin/env bash\n{body}\n')
        target.chmod(0o755)

    def run_script(self, *args):
        return subprocess.run(['bash', str(self.script), *args], env=self.environment,
                              capture_output=True, text=True, check=False)

    def assert_no_sdk_or_report(self):
        self.assertFalse(self.marker.exists(), 'SDK/dependency tool must not run')
        self.assertFalse((self.root / 'reports').exists(), 'Report directory must not be created')

    def test_linux_fails_before_any_tool_or_file_mutation(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 2)
        self.assertIn('native iOS validation did not run', result.stderr)
        self.assert_no_sdk_or_report()

    def test_dry_run_is_inert_and_states_unsigned_locked_plan(self):
        result = self.run_script('--dry-run')
        self.assertEqual(result.returncode, 0)
        for expected in ('DRY RUN ONLY', '--enforce-lockfile', '--deployment', '--no-codesign',
                         'CODE_SIGNING_ALLOWED=NO', 'DEVELOPMENT_TEAM=', 'build analyze',
                         'native-build.invalid/api', 'SDK >=26'):
            self.assertIn(expected, result.stdout)
        self.assert_no_sdk_or_report()

    def test_help_is_inert(self):
        self.assertEqual(self.run_script('--help').returncode, 0)
        self.assert_no_sdk_or_report()

    def test_unknown_or_extra_arguments_fail_without_work(self):
        for args in (('--upload',), ('--dry-run', '--upload'), ('--help', 'extra')):
            self.assertEqual(self.run_script(*args).returncode, 2)
        self.assert_no_sdk_or_report()

    def test_old_xcode_stops_before_flutter(self):
        self.fake_tool('uname', 'echo Darwin')
        self.fake_tool('xcodebuild', "printf 'Xcode 16.4\\nBuild version 16F6\\n'")
        self.fake_tool('xcrun', 'echo 26.0')
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn('Require Xcode 26+', result.stderr)
        self.assert_no_sdk_or_report()

    def test_old_ios_sdk_stops_before_flutter(self):
        self.fake_tool('uname', 'echo Darwin')
        self.fake_tool('xcodebuild', "printf 'Xcode 26.0\\nBuild version 17A1\\n'")
        self.fake_tool('xcrun', 'echo 18.5')
        result = self.run_script()
        self.assertEqual(result.returncode, 1)
        self.assertIn('iOS 26+', result.stderr)
        self.assert_no_sdk_or_report()


class ResourceFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = Path(self.temp.name) / 'Runner.app'
        self.app.mkdir()
        self.info = {'DTSDKName': 'iphoneos26.0', 'MinimumOSVersion': '13.0',
                     'CFBundleExecutable': 'Runner', 'CFBundleIdentifier': 'test.synthetic.fixture'}
        self.save_info()
        (self.app / 'Runner').write_bytes(b'synthetic fixture, not Mach-O evidence')
        (self.app / 'Assets.car').write_bytes(b'synthetic asset presence fixture')
        self.write_plist('PrivacyInfo.xcprivacy', {'NSPrivacyAccessedAPITypes': []})
        self.write_plist('Frameworks/Flutter.framework/PrivacyInfo.xcprivacy', {})
        for bundle in RESOURCES.PLUGIN_BUNDLES:
            self.write_plist(f'Frameworks/test.framework/{bundle}.bundle/PrivacyInfo.xcprivacy', {})

    def tearDown(self):
        self.temp.cleanup()

    def write_plist(self, relative, value):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def save_info(self):
        self.write_plist('Info.plist', self.info)

    def test_complete_structure_fixture_reports_limits(self):
        result = RESOURCES.inspect_app(self.app)
        self.assertEqual(result['errors'], [])
        self.assertEqual(len(result['manifests']), 11)
        self.assertIn('device execution', result['not_verified'])
        self.assertIn('privacy reason correctness', result['not_verified'])

    def test_missing_geocoding_resource_is_rejected(self):
        next(self.app.glob('**/geocoding_ios_privacy.bundle/PrivacyInfo.xcprivacy')).unlink()
        self.assertTrue(any('geocoding_ios_privacy' in error
                            for error in RESOURCES.inspect_app(self.app)['errors']))

    def test_missing_runner_or_engine_manifest_is_rejected(self):
        for relative in ('PrivacyInfo.xcprivacy', 'Frameworks/Flutter.framework/PrivacyInfo.xcprivacy'):
            (self.app / relative).unlink()
        errors = RESOURCES.inspect_app(self.app)['errors']
        self.assertEqual(sum(error.startswith('Missing manifest:') for error in errors), 2)

    def test_invalid_manifest_structure_is_rejected(self):
        self.write_plist('PrivacyInfo.xcprivacy', {'NSPrivacyAccessedAPITypes': ['invalid']})
        self.assertTrue(any('Invalid required-reason' in error
                            for error in RESOURCES.inspect_app(self.app)['errors']))

    def test_old_built_sdk_or_deployment_target_is_rejected(self):
        self.info.update(DTSDKName='iphoneos18.5', MinimumOSVersion='12.0')
        self.save_info()
        errors = RESOURCES.inspect_app(self.app)['errors']
        self.assertTrue(any('26+' in error for error in errors))
        self.assertTrue(any('13+' in error for error in errors))

    def test_missing_executable_and_assets_are_rejected(self):
        (self.app / 'Runner').unlink()
        (self.app / 'Assets.car').unlink()
        self.assertEqual(len(RESOURCES.inspect_app(self.app)['errors']), 2)

    def test_malformed_info_plist_reports_error(self):
        (self.app / 'Info.plist').write_text('not a plist')
        self.assertTrue(any('Cannot parse built Info.plist' in error
                            for error in RESOURCES.inspect_app(self.app)['errors']))


if __name__ == '__main__':
    unittest.main(verbosity=2)
