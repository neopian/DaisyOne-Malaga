#!/usr/bin/env python3
"""Focused failure-gate tests; uses synthetic configuration, no service calls."""
import importlib.util
import hashlib
import json
import plistlib
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('preflight', Path(__file__).with_name('release-preflight.py'))
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class ReleasePreflightTests(unittest.TestCase):
    def test_rejects_insecure_placeholder_or_ambiguous_urls(self):
        for value in (None, '', 'http://api.daisy.test/api', 'https://localhost/api',
                      'https://api.local/api', 'https://127.0.0.1/api', 'https://[::1]/api',
                      'https://api.example.com/api', 'https://api.invalid/api',
                      'https://user:secret@travel.invalid/api', 'https://api.openai.com/api?token=secret',
                      'https://api.openai.com/api#fragment', 'https://api.openai.com:8080/api',
                      'https://api.openai.com\\@evil.com/api', 'https://api..openai.com/api',
                      ' https://api.openai.com/api', 'https://api.openai.com/other'):
            with self.subTest(value=value):
                self.assertFalse(preflight.public_https(value, api=True))

    def test_accepts_syntactic_https_without_contacting_it(self):
        self.assertTrue(preflight.public_https('https://api.openai.com/api', api=True))
        self.assertTrue(preflight.public_https('https://openai.com/policies/privacy-policy/'))
        self.assertTrue(preflight.public_https('https://openai.com', origin=True))
        self.assertFalse(preflight.public_https('https://openai.com/path', origin=True))

    def test_only_explicit_false_disables_release_flags(self):
        self.assertTrue(preflight.is_false(False))
        self.assertTrue(preflight.is_false('false'))
        for value in (None, '', 'FALSE', '0', 0, True, 'true', []):
            self.assertFalse(preflight.is_false(value))

    def test_rejects_unresolved_or_header_injected_contact(self):
        for value in (None, '', 'support@example.com', 'support@localhost',
                      'support@openai.com\nBcc: other@openai.com',
                      'Support <support@openai.com>'):
            self.assertFalse(preflight.public_email(value))
        self.assertTrue(preflight.public_email('support@openai.com'))

    def test_missing_release_configuration_is_blocked(self):
        report = preflight.check_release(preflight.ROOT, {})
        blocked = {c['id'] for c in report['checks'] if c['status'] == 'BLOCKED'}
        self.assertFalse(report['static_checks_passed'])
        self.assertTrue({'app_name', 'bundle_id', 'signing_team', 'api_base_url',
                         'privacy_policy_url', 'terms_url', 'support_contact',
                         'demo_mode', 'enable_dev_login', 'qa_auto_login',
                         'backend_production', 'backend_dev_seed', 'backend_mail_mode',
                         'backend_mail_sender', 'backend_account_url',
                         'backend_verification_policy'} <= blocked)

    def test_repository_preserves_approved_native_source_baseline(self):
        # The aggregate runner allows unrelated release gates to remain blocked.
        # These adopted native gates must therefore fail their own regression test.
        report = preflight.check_release(preflight.ROOT, {})
        checks = {check['id']: check['status'] for check in report['checks']}
        for key in ('ios_minimum', 'ios_scene_lifecycle', 'podfile_lock', 'pod_lock_packages'):
            with self.subTest(key=key):
                self.assertEqual(checks[key], 'CHECKED')

    def test_rejects_ats_and_background_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'ios/Runner').mkdir(parents=True)
            with (root / 'ios/Runner/Info.plist').open('wb') as stream:
                plistlib.dump({'NSAppTransportSecurity': {'NSAllowsArbitraryLoads': True},
                               'UIBackgroundModes': ['location']}, stream)
            report = preflight.check_release(root, {})
            checks = {c['id']: c['status'] for c in report['checks']}
            self.assertEqual(checks['ats'], 'BLOCKED')
            self.assertEqual(checks['minimal_permissions'], 'BLOCKED')

    def test_report_does_not_repeat_supplied_secrets(self):
        secret = 'SYNTHETIC_SECRET_DO_NOT_ECHO'
        report = preflight.check_release(preflight.ROOT, {'dart_defines': {
            'API_BASE_URL': f'https://user:{secret}@api.openai.com/api'},
            'backend': {'IMAGE_SIGNING_SECRET': secret}})
        self.assertNotIn(secret, json.dumps(report))

    def test_pod_version_is_not_assumed_to_equal_dart_version(self):
        self.assertEqual(preflight.locked_packages('packages:\n  plugin:\n    dependency: transitive\n    version: "2.5.4"\nsdks:\n  dart: any\n'), {'plugin': '2.5.4'})

    def test_existing_manifest_with_broken_resource_path_is_flagged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.dart_tool').mkdir()
            package = root / 'package'
            (package / 'ios/Sources/plugin').mkdir(parents=True)
            (root / '.dart_tool/package_config.json').write_text(json.dumps({
                'packages': [{'name': 'plugin', 'rootUri': package.as_uri()}]}))
            (package / 'ios/plugin.podspec').write_text("s.resource_bundles = {'privacy' => ['Sources/PrivacyInfo.xcprivacy']}")
            (package / 'ios/Sources/plugin/PrivacyInfo.xcprivacy').write_bytes(
                plistlib.dumps({'NSPrivacyAccessedAPITypes': []}))
            inventory = preflight.native_sdk_inventory(root)
            self.assertTrue(inventory[0]['manifest_valid_plist'])
            self.assertEqual(inventory[0]['missing_podspec_resources'], ['Sources/PrivacyInfo.xcprivacy'])

    def test_api_only_manifest_is_not_complete_collection_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'ios/Runner').mkdir(parents=True)
            (root / 'ios/Runner/PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps({
                'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType':
                    'NSPrivacyAccessedAPICategoryUserDefaults',
                    'NSPrivacyAccessedAPITypeReasons': ['CA92.1']}]}))
            report = preflight.check_release(root, {})
            checks = {c['id']: c['status'] for c in report['checks']}
            self.assertEqual(checks['app_privacy_collection_review'], 'BLOCKED')


class IosBaselineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for directory in ('ios/Runner', 'ios/Runner.xcodeproj', 'ios/Flutter'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        self.project = self.root / 'ios/Runner.xcodeproj/project.pbxproj'
        self.project.write_text('IPHONEOS_DEPLOYMENT_TARGET = 15.0;\n' * 3)
        self.podfile = self.root / 'ios/Podfile'
        self.podfile.write_text("platform :ios, '15.0'\n")
        self.framework = self.root / 'ios/Flutter/AppFrameworkInfo.plist'
        self.framework.write_bytes(plistlib.dumps({'CFBundleExecutable': 'App'}))
        self.info = {'UIApplicationSceneManifest': {
            'UIApplicationSupportsMultipleScenes': False,
            'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                'UISceneClassName': 'UIWindowScene',
                'UISceneConfigurationName': 'flutter',
                'UISceneDelegateClassName': 'FlutterSceneDelegate',
                'UISceneStoryboardFile': 'Main',
            }]},
        }}
        self.save_info()
        self.delegate = self.root / 'ios/Runner/AppDelegate.swift'
        self.delegate.write_text('''import Flutter
import UIKit
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
''')

    def tearDown(self):
        self.temp.cleanup()

    def save_info(self):
        (self.root / 'ios/Runner/Info.plist').write_bytes(plistlib.dumps(self.info))

    def status(self, key):
        report = preflight.check_release(self.root, {})
        return next(check['status'] for check in report['checks'] if check['id'] == key)

    def test_approved_floor_accepts_sdk_generated_framework_minimum(self):
        self.assertEqual(self.status('ios_minimum'), 'CHECKED')
        self.assertEqual(self.status('ios_scene_lifecycle'), 'CHECKED')

    def test_rejects_reverted_mixed_raised_or_invalid_project_targets(self):
        for targets in (['13.0'] * 3, ['14.0'] * 3,
                        ['15.0', '13.0', '15.0'], ['15.0', '16.0', '15.0'],
                        ['16.0'] * 3, ['15.0'] * 2, ['15.0', '15.0', '15..0'], []):
            with self.subTest(targets=targets):
                self.project.write_text(''.join(f'IPHONEOS_DEPLOYMENT_TARGET = {value};\n'
                                               for value in targets))
                self.assertEqual(self.status('ios_minimum'), 'BLOCKED')

    def test_rejects_podfile_target_drift_or_missing_platform(self):
        for value in ("platform :ios, '13.0'\n", "platform :ios, '14.0'\n",
                      "platform :ios, '16.0'\n", "# platform :ios, '15.0'\n", '',
                      "platform :ios, '15.0'\nplatform :ios, '13.0'\n"):
            with self.subTest(value=value):
                self.podfile.write_text(value)
                self.assertEqual(self.status('ios_minimum'), 'BLOCKED')

    def test_source_framework_minimum_must_be_generated_not_reintroduced(self):
        for value in ('13.0', '14.0', '15.0', '16.0'):
            with self.subTest(value=value):
                self.framework.write_bytes(plistlib.dumps({
                    'CFBundleExecutable': 'App', 'MinimumOSVersion': value}))
                self.assertEqual(self.status('ios_minimum'), 'BLOCKED')

    def test_missing_or_malformed_framework_is_not_treated_as_generated_style(self):
        for content in (b'not a plist', plistlib.dumps([]), plistlib.dumps({})):
            with self.subTest(content=content):
                self.framework.write_bytes(content)
                self.assertEqual(self.status('ios_minimum'), 'BLOCKED')
        self.framework.unlink()
        self.assertEqual(self.status('ios_minimum'), 'BLOCKED')

    def test_scene_lifecycle_rejects_missing_or_multiple_scenes(self):
        for value in (None, {}, {'UIApplicationSupportsMultipleScenes': True},
                      {'UIApplicationSupportsMultipleScenes': False, 'UISceneConfigurations': {}}):
            with self.subTest(value=value):
                self.info['UIApplicationSceneManifest'] = value
                if value is None:
                    del self.info['UIApplicationSceneManifest']
                self.save_info()
                self.assertEqual(self.status('ios_scene_lifecycle'), 'BLOCKED')

    def test_scene_lifecycle_rejects_wrong_delegate_storyboard_or_multiwindow(self):
        original = plistlib.dumps(self.info)
        for key, value in (('UISceneDelegateClassName', 'UnreviewedSceneDelegate'),
                           ('UISceneStoryboardFile', 'Missing')):
            with self.subTest(key=key):
                self.info = plistlib.loads(original)
                scene = self.info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]
                scene[key] = value
                self.save_info()
                self.assertEqual(self.status('ios_scene_lifecycle'), 'BLOCKED')
        for value in (True, 0):
            self.info = plistlib.loads(original)
            self.info['UIApplicationSceneManifest']['UIApplicationSupportsMultipleScenes'] = value
            self.save_info()
            self.assertEqual(self.status('ios_scene_lifecycle'), 'BLOCKED')

    def test_scene_lifecycle_rejects_old_missing_or_duplicate_plugin_registration(self):
        original = self.delegate.read_text()
        for value in (original.replace(', FlutterImplicitEngineDelegate', ''),
                      original.replace('engineBridge.pluginRegistry', 'self'),
                      original.replace('GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)', ''),
                      original.replace('didInitializeImplicitFlutterEngine', 'wrongCallback'),
                      original + '\nGeneratedPluginRegistrant.register(with: self)\n'):
            with self.subTest(value=value):
                self.delegate.write_text(value)
                self.assertEqual(self.status('ios_scene_lifecycle'), 'BLOCKED')

    def test_comment_only_podfile_change_requires_updated_checksum(self):
        lock = self.root / 'ios/Podfile.lock'
        original_checksum = hashlib.sha1(self.podfile.read_bytes()).hexdigest()
        lock.write_text(f'PODFILE CHECKSUM: {original_checksum}\n')
        self.assertEqual(self.status('podfile_lock'), 'CHECKED')
        self.podfile.write_text('# Approved iOS 15 baseline\n' + self.podfile.read_text())
        self.assertEqual(self.status('podfile_lock'), 'BLOCKED')
        updated_checksum = hashlib.sha1(self.podfile.read_bytes()).hexdigest()
        lock.write_text(f'PODFILE CHECKSUM: {updated_checksum}\n')
        self.assertEqual(self.status('podfile_lock'), 'CHECKED')


if __name__ == '__main__':
    unittest.main()
