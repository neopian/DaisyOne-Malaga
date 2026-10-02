#!/usr/bin/env python3
"""Focused failure-gate tests; uses synthetic configuration, no service calls."""
import importlib.util
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


if __name__ == '__main__':
    unittest.main()
