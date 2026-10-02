#!/usr/bin/env python3
"""Linux-safe contract tests. Synthetic fixtures do not represent an iOS build."""
import importlib.util
import json
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

    def prepare_runner_fixture(self, *, flutter_build='exit 0', xcode_build='exit 99'):
        # Exercise the real lane, snapshots and diagnostics with prepared source.
        # Every SDK command is replaced by a stub; no installed SDK is invoked.
        shutil.copytree(ROOT / 'ios', self.root / 'ios',
                        ignore=shutil.ignore_patterns('Pods', '.symlinks', 'ephemeral'))
        for filename in ('pubspec.yaml', 'pubspec.lock'):
            shutil.copy(ROOT / filename, self.root / filename)
        shutil.copy(ROOT / 'scripts/summarize-native-diagnostics.py', self.root / 'scripts')
        self.fake_tool('uname', 'echo Darwin')
        self.fake_tool('xcrun', 'echo 26.0')
        self.fake_tool('xcode-select', 'echo /synthetic/Xcode.app/Contents/Developer')
        self.fake_tool('pod', '''case "${1:-}" in
  --version) echo 1.16.2 ;;
  install) exit 0 ;;
  *) exit 99 ;;
esac''')
        self.native_build_marker = self.root / 'native-build-called'
        self.environment['NATIVE_BUILD_MARKER'] = str(self.native_build_marker)
        self.fake_tool('xcodebuild', '''case "${1:-}" in
  -version) printf 'Xcode 26.0\\nBuild version SYNTHETIC\\n' ;;
  -checkFirstLaunchStatus) exit 0 ;;
  *) touch "$NATIVE_BUILD_MARKER"; ''' + xcode_build + ''' ;;
esac''')
        self.fake_tool('flutter', '''case "${1:-}" in
  --version) echo '{"frameworkVersion":"3.47.5"}' ;;
  config) echo '{"enable-swift-package-manager":false}' ;;
  pub|analyze|test) exit 0 ;;
  build) ''' + flutter_build + ''' ;;
  *) exit 99 ;;
esac''')

    def test_framework_source_mutation_fails_before_native_build(self):
        self.prepare_runner_fixture(flutter_build=
            "printf '\\n<!-- synthetic migration -->\\n' >>ios/Flutter/AppFrameworkInfo.plist")

        result = self.run_script()

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn('Locks or native source changed', result.stderr)
        self.assertFalse(self.native_build_marker.exists(), 'Source drift must stop before native build')
        report = next((self.root / 'reports').glob('run.*'))
        before = json.loads((report / 'source-before.json').read_text())
        after = json.loads((report / 'source-after.json').read_text())
        changed = {path for path in before.keys() | after.keys()
                   if before.get(path) != after.get(path)}
        self.assertEqual(changed, {'ios/Flutter/AppFrameworkInfo.plist'})

    def test_xcode_failure_retains_diagnostics_and_preserves_failure_status(self):
        self.prepare_runner_fixture(xcode_build=
            "printf 'native.c:3:4: warning: synthetic warning\\n"
            "native.c:4:4: error: synthetic failure\\n** BUILD FAILED **\\n'; exit 65")
        resource_marker = self.root / 'resource-check-called'
        self.environment['RESOURCE_CHECK_MARKER'] = str(resource_marker)
        (self.root / 'scripts/verify-ios-resources.py').write_text('''import os
from pathlib import Path
Path(os.environ['RESOURCE_CHECK_MARKER']).touch()
raise SystemExit(99)
''')

        result = self.run_script()

        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertTrue(self.native_build_marker.exists(), 'The synthetic Xcode command must run')
        report = next((self.root / 'reports').glob('run.*'))
        summary = json.loads((report / 'native-diagnostics.json').read_text())
        self.assertEqual(summary['xcode_exit_code'], 65)
        self.assertEqual(summary['assessment'], 'review_required')
        self.assertEqual(summary['diagnostic_counts']['warning'], 1)
        self.assertEqual(summary['diagnostic_counts']['error'], 1)
        self.assertEqual(summary['action_result_markers']['build']['failed'], 1)
        self.assertIn('synthetic failure', (report / 'xcode_build_analyze.log').read_text())
        self.assertFalse(resource_marker.exists(), 'Native failure must stop before resource checks')
        self.assertFalse((report / 'bundled_resources.log').exists())
        self.assertNotIn('resource checks passed', result.stdout)


class ResourceFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.app = Path(self.temp.name) / 'Runner.app'
        self.app.mkdir()
        self.info = {'DTSDKName': 'iphoneos26.0', 'MinimumOSVersion': '15.0',
                     'CFBundleExecutable': 'Runner', 'CFBundleIdentifier': 'test.synthetic.fixture'}
        self.save_info()
        (self.app / 'Runner').write_bytes(b'synthetic fixture, not Mach-O evidence')
        (self.app / 'Assets.car').write_bytes(b'synthetic asset presence fixture')
        self.write_plist('PrivacyInfo.xcprivacy', {'NSPrivacyAccessedAPITypes': []})
        self.write_plist('Frameworks/Flutter.framework/PrivacyInfo.xcprivacy', {})
        for framework, minimum in (('App', '15.0'), ('Flutter', '15.0'), ('test', '13.0')):
            self.write_plist(f'Frameworks/{framework}.framework/Info.plist',
                             {'MinimumOSVersion': minimum})
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
        self.assertEqual(result['minimum_os'], '15.0')
        self.assertEqual({item['path']: item['minimum_os'] for item in result['frameworks']}, {
            'Frameworks/App.framework': '15.0',
            'Frameworks/Flutter.framework': '15.0',
            'Frameworks/test.framework': '13.0',
        })
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

    def test_old_built_sdk_is_rejected_independently_of_supported_devices(self):
        self.info.update(DTSDKName='iphoneos18.5')
        self.save_info()
        errors = RESOURCES.inspect_app(self.app)['errors']
        self.assertTrue(any('26+' in error for error in errors))
        self.assertFalse(any('minimum OS' in error for error in errors))

    def test_built_app_must_preserve_exact_approved_device_floor(self):
        for minimum in ('12.0', '13.0', '14.0', '15.1', '16.0', '', '15..0', 15):
            with self.subTest(minimum=minimum):
                self.info['MinimumOSVersion'] = minimum
                self.save_info()
                errors = RESOURCES.inspect_app(self.app)['errors']
                self.assertTrue(any('approved iOS 15.0 floor' in error for error in errors))
        del self.info['MinimumOSVersion']
        self.save_info()
        self.assertTrue(any('approved iOS 15.0 floor' in error
                            for error in RESOURCES.inspect_app(self.app)['errors']))

    def test_equivalent_zero_patch_version_preserves_approved_floor(self):
        self.info['MinimumOSVersion'] = '15.0.0'
        self.save_info()
        self.assertEqual(RESOURCES.inspect_app(self.app)['errors'], [])

    def test_embedded_framework_cannot_raise_supported_device_floor(self):
        for framework in ('App', 'Flutter', 'test'):
            for minimum in ('15.0.1', '15.1', '16.0'):
                with self.subTest(framework=framework, minimum=minimum):
                    self.write_plist(f'Frameworks/{framework}.framework/Info.plist',
                                     {'MinimumOSVersion': minimum})
                    errors = RESOURCES.inspect_app(self.app)['errors']
                    self.assertTrue(any('requires newer than iOS 15.0' in error
                                        and f'{framework}.framework' in error for error in errors))
            self.write_plist(f'Frameworks/{framework}.framework/Info.plist',
                             {'MinimumOSVersion': '15.0'})

    def test_missing_or_invalid_embedded_framework_metadata_is_rejected(self):
        relative = 'Frameworks/App.framework/Info.plist'
        for value in ({}, {'MinimumOSVersion': '15..0'}, {'MinimumOSVersion': 15}, []):
            with self.subTest(value=value):
                self.write_plist(relative, value)
                self.assertTrue(any('App.framework' in error
                                    for error in RESOURCES.inspect_app(self.app)['errors']))
        (self.app / relative).write_text('not a plist')
        self.assertTrue(any('Cannot parse embedded framework' in error
                            for error in RESOURCES.inspect_app(self.app)['errors']))
        shutil.rmtree(self.app / 'Frameworks/App.framework')
        self.assertTrue(any('Cannot parse embedded framework' in error and 'App.framework' in error
                            for error in RESOURCES.inspect_app(self.app)['errors']))

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
