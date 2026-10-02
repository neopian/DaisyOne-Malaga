#!/usr/bin/env python3
"""Read-only release gates. No network, build, signing, secrets or publishing.

Exit 0 means these static checks passed, NEVER App Store approval/readiness.
Exit 1 reports unresolved gates. Exit 2 means invalid invocation/input.
"""
import argparse
import hashlib
import ipaddress
import json
import plistlib
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_ICON_SHA256 = '7770183009e914112de7d8ef1d235a6a30c5834424858e0d2f8253f6b8d31926'
FLAGS = ('DEMO_MODE', 'ENABLE_DEV_LOGIN', 'QA_AUTO_LOGIN')
MANUAL = [
    'Build/archive on macOS with Xcode and iOS 26 SDK or later; verify the current Apple requirement again at submission.',
    'Verify authorized signing team, certificate, provisioning, entitlements and registered bundle identifier on the archive.',
    'Run physical iPhone/iPad tests: permissions denied/approximate, photos, Keychain, export, logout, deletion and interrupted requests.',
    'Audit final bundled SDK privacy manifests/signatures and Xcode privacy report; approve actual App Store privacy answers.',
    'Verify live privacy/support/community URLs, contact ownership, moderation staffing, backend TLS, backups and deletion retention.',
    'Complete age rating, accessibility/device screenshots, app metadata, review account/instructions and payment-model decision.',
]


def public_https(value, *, api=False, origin=False):
    """Syntax-only public DNS URL check: deliberately does not contact a host."""
    if not isinstance(value, str) or not value or value != value.strip():
        return False
    if re.search(r'[\s\x00-\x1f\x7f\\]', value):
        return False
    try:
        parsed = urlsplit(value)
        host = (parsed.hostname or '').lower()
        port = parsed.port
        if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.query or parsed.fragment:
            return False
        if port not in (None, 443) or '.' not in host or not re.fullmatch(r'[a-z0-9.-]+', host):
            return False
        if any(not label or len(label) > 63 or label.startswith('-') or label.endswith('-') for label in host.split('.')):
            return False
        if any(host == suffix or host.endswith('.' + suffix) for suffix in ('localhost', 'local', 'internal', 'test', 'invalid', 'example', 'example.com', 'example.org', 'example.net')):
            return False
        try:
            ipaddress.ip_address(host)
            return False
        except ValueError:
            pass
        if api and parsed.path.rstrip('/') != '/api':
            return False
        if origin and parsed.path not in ('', '/'):
            return False
        return True
    except (ValueError, TypeError):
        return False


def is_false(value):
    return value is False or value == 'false'


def public_email(value):
    return (isinstance(value, str)
            and bool(re.fullmatch(r'[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+', value))
            and public_https('https://' + value.split('@')[-1]))


def locked_packages(text):
    result = {}
    for name, block in re.findall(r'^  (\w+):\n(.*?)(?=^  \w+:|^sdks:|\Z)', text, re.M | re.S):
        version = re.search(r'^    version: "(.*?)"$', block, re.M)
        if version:
            result[name] = version.group(1)
    return result


def native_sdk_inventory(root):
    """Inspect resolved package files, not arbitrary versions in a shared cache."""
    config_file = root / '.dart_tool/package_config.json'
    try:
        config = json.loads(config_file.read_text())
    except (OSError, ValueError):
        return []
    inventory = []
    for package in config.get('packages', []):
        uri = urlsplit(urljoin(config_file.as_uri(), package.get('rootUri', '')))
        if uri.scheme != 'file':
            continue
        package_root = Path(unquote(uri.path))
        specs = sorted([*package_root.glob('ios/*.podspec'), *package_root.glob('darwin/*.podspec')])
        if not specs:
            continue
        manifests = sorted([*package_root.glob('ios/**/*.xcprivacy'), *package_root.glob('darwin/**/*.xcprivacy')])
        valid = bool(manifests)
        reasons = []
        for manifest in manifests:
            try:
                data = plistlib.loads(manifest.read_bytes())
                if not isinstance(data, dict):
                    valid = False
                    continue
                for entry in data.get('NSPrivacyAccessedAPITypes', []):
                    reasons.append({'api': entry.get('NSPrivacyAccessedAPIType'), 'reasons': entry.get('NSPrivacyAccessedAPITypeReasons', [])})
            except (OSError, ValueError, plistlib.InvalidFileException, AttributeError):
                valid = False
        missing = []
        for spec in specs:
            for resource in re.findall(r"['\"]([^'\"]+\.xcprivacy)['\"]", spec.read_text()):
                if not (spec.parent / resource).is_file():
                    missing.append(resource)
        inventory.append({'name': package['name'], 'manifest_valid_plist': valid,
                          'manifest_count': len(manifests), 'api_reasons': reasons,
                          'missing_podspec_resources': missing})
    return inventory


def check_release(root, config):
    checks = []
    def check(key, passed, message):
        checks.append({'id': key, 'status': 'CHECKED' if passed else 'BLOCKED', 'detail': message})
    def read(path):
        return (root / path).read_text() if (root / path).is_file() else ''
    def plist(path):
        try:
            with (root / path).open('rb') as stream:
                return plistlib.load(stream)
        except (OSError, plistlib.InvalidFileException, ValueError):
            return {}

    info = plist('ios/Runner/Info.plist')
    project = read('ios/Runner.xcodeproj/project.pbxproj')
    podfile = read('ios/Podfile')
    podlock = read('ios/Podfile.lock')
    packages = locked_packages(read('pubspec.lock'))
    app = config.get('app', {})
    defines = config.get('dart_defines', {})
    backend = config.get('backend', {})

    name = app.get('display_name', '')
    check('app_name', bool(name and name == info.get('CFBundleDisplayName') and name not in ('Local Qa Concierge', 'local_qa_concierge', 'DaisyOne-Malaga')),
          'Choose the release name and match CFBundleDisplayName; the work folder is not the product name.')
    bundle = app.get('bundle_id', '')
    bundles = set(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);', project))
    check('bundle_id', bool(isinstance(bundle, str) and re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle) and not bundle.startswith(('com.example.', 'org.example.')) and bundles == {bundle, bundle + '.RunnerTests'}),
          'Set an owned registered release bundle ID consistently in Runner and RunnerTests.')
    team = app.get('apple_team_id', '')
    teams = set(re.findall(r'DEVELOPMENT_TEAM = ([^;]+);', project))
    check('signing_team', bool(isinstance(team, str) and re.fullmatch(r'[A-Z0-9]{10}', team) and teams == {team}),
          'Explicitly identify the authorized Apple team and match project settings; a retained team value is not verified signing.')
    icon = root / 'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png'
    check('app_icon', icon.is_file() and hashlib.sha256(icon.read_bytes()).hexdigest() != TEMPLATE_ICON_SHA256,
          'Replace the retained template app icon only after visual identity is chosen; validate all required sizes in Xcode.')
    check('version', bool(re.search(r'^version: \d+\.\d+\.\d+\+\d+$', read('pubspec.yaml'), re.M)),
          'Marketing version and numeric build number are present; App Store Connect build-number uniqueness remains manual.')
    check('permissions', bool(info.get('NSLocationWhenInUseUsageDescription') and info.get('NSPhotoLibraryUsageDescription')),
          'Location and gallery purpose strings exist for current features; localized prompts still need device review.')
    extra_permissions = {'NSLocationAlwaysUsageDescription', 'NSLocationAlwaysAndWhenInUseUsageDescription', 'NSCameraUsageDescription', 'NSMicrophoneUsageDescription'} & info.keys()
    check('minimal_permissions', not extra_permissions and 'location' not in info.get('UIBackgroundModes', []) and 'BYPASS_PERMISSION_LOCATION_ALWAYS=1' in podfile,
          'Current gallery/foreground-location app has no camera, microphone or background-location permission expansion.')
    ats = info.get('NSAppTransportSecurity', {})
    check('ats', not ats,
          'No ATS override; any future exception needs a specific transport/security review, never a blanket allowance.')
    floors = re.findall(r'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);', project)
    check('ios_minimum', bool(floors and all(float(x) >= 13 for x in floors) and "platform :ios, '13.0'" in podfile and plist('ios/Flutter/AppFrameworkInfo.plist').get('MinimumOSVersion') == '13.0'),
          'Runner, Podfile and Flutter framework minimum OS are aligned at iOS 13; this is not the build SDK version.')
    entitlements = [plist('ios/Runner/' + n + '.entitlements') for n in ('DebugProfile', 'Release')]
    check('keychain_entitlements', all(e.get('keychain-access-groups') == [] for e in entitlements) and project.count('CODE_SIGN_ENTITLEMENTS = Runner/DebugProfile.entitlements;') == 2 and project.count('CODE_SIGN_ENTITLEMENTS = Runner/Release.entitlements;') == 1,
          'Default app Keychain entitlements wired for all configurations; archive/device verification is still required.')

    for key in ('API_BASE_URL', 'PRIVACY_POLICY_URL', 'SUPPORT_URL', 'TERMS_URL', 'COMMUNITY_GUIDELINES_URL'):
        check(key.lower(), public_https(defines.get(key), api=key == 'API_BASE_URL'),
              f'{key} must be an explicit public HTTPS URL without credentials/query/fragment; public availability is checked separately.')
    check('support_contact', public_email(defines.get('SUPPORT_EMAIL')), 'Set a real published support/moderation email address; ownership and timely response remain release decisions.')
    for flag in FLAGS:
        check(flag.lower(), flag in defines and is_false(defines[flag]), f'{flag} must be explicitly false in the exact release build defines.')
    app_config = read('lib/core/constants/app_config.dart')
    check('native_release_guard_source', all(value in app_config for value in ('nativeReleaseConfigurationError', 'kReleaseMode', "uri.scheme != 'https'", 'uri.userInfo.isNotEmpty')) and 'AppConfig.configurationError' in read('lib/app/app.dart'),
          'Native release configuration guard is present before router/auth initialization; behavior is covered separately by Flutter tests.')
    check('backend_production', backend.get('NODE_ENV') == 'production', 'Production runtime must explicitly use NODE_ENV=production.')
    check('backend_origin', public_https(backend.get('PUBLIC_BASE_URL'), origin=True), 'Production image/API origin must use public HTTPS.')
    api_url = defines.get('API_BASE_URL', '')
    public_origin = backend.get('PUBLIC_BASE_URL', '')
    check('backend_origin_match', bool(public_https(api_url, api=True) and public_https(public_origin, origin=True) and urlsplit(api_url).netloc == urlsplit(public_origin).netloc),
          'API and signed image URLs must use the reviewed backend host.')
    check('backend_dev_seed', 'ALLOW_DEV_SEED' in backend and is_false(backend['ALLOW_DEV_SEED']), 'Production development seed must be explicitly disabled.')
    check('backend_mail_mode', backend.get('MAIL_MODE') == 'sendmail', 'Production account delivery requires sendmail; disabled/local synthetic sink is not live delivery.')
    check('backend_mail_sender', public_email(backend.get('MAIL_FROM')), 'Choose and verify an owned production account-mail sender; actual MTA delivery remains untested.')
    check('backend_account_url', public_https(backend.get('ACCOUNT_ACTION_URL')), 'Account email must point to the reviewed public HTTPS account flow, without token query parameters in configuration.')
    check('backend_verification_policy', backend.get('EMAIL_VERIFICATION_POLICY') in ('optional', 'required_for_contributions'), 'Operator must explicitly choose the email verification policy; do not infer a choice from development defaults.')
    server = read('backend/src/server.mjs')
    seed = read('backend/src/seed.mjs')
    check('backend_guards_source', all(v in server for v in ('production', 'https:', 'IMAGE_SIGNING_SECRET', 'CORS_ORIGINS')) and all(v in seed for v in ('production', 'ALLOW_DEV_SEED')),
          'Production HTTPS/secret/CORS and development-seed guard markers exist; behavioral backend tests and deployment secrets must be verified separately.')
    mail = read('backend/src/account-mail.mjs')
    check('backend_mail_guards_source', 'loadMailConfig(env,production)' in server and all(v in mail for v in ('production', 'sendmail', 'ACCOUNT_ACTION_URL', 'EMAIL_VERIFICATION_POLICY', 'https:')),
          'Production mail guards are wired into server configuration; source markers alone do not establish live delivery or authorization.')

    checksum = re.search(r'^PODFILE CHECKSUM: (\w+)$', podlock, re.M)
    check('podfile_lock', bool(checksum and hashlib.sha1(podfile.encode()).hexdigest() == checksum.group(1)),
          'Run flutter pub get and pod install on macOS and commit the generated Podfile.lock; do not fabricate native resolution on Linux.')
    pod_names = set(re.findall(r'^  - (\w+) \(from ', podlock, re.M)) - {'Flutter'}
    stale = sorted(pod_names - packages.keys())
    check('pod_lock_packages', not stale, 'CocoaPods entries absent from Dart lockfile: ' + (', '.join(stale) if stale else 'none') + '. Pod versions need not equal Dart versions.')
    inventory = native_sdk_inventory(root)
    generated = root / '.flutter-plugins-dependencies'
    try:
        metadata = json.loads(generated.read_text())
        ios_plugins = {p['name'] for p in metadata['plugins']['ios'] if p.get('native_build', True)}
        check('native_plugin_inventory', ios_plugins == pod_names,
              'Generated native plugin names match Podfile.lock; differences: ' + (', '.join(sorted(ios_plugins ^ pod_names)) or 'none'))
    except (OSError, ValueError, KeyError, TypeError):
        resolved = {package['name'] for package in inventory}
        check('native_plugin_inventory', bool(resolved and resolved == pod_names),
              'Resolved native podspec names compared with Podfile.lock (Flutter platform metadata not generated); differences: ' + (', '.join(sorted(resolved ^ pod_names)) or 'none'))
    check('native_sdk_manifests', bool(inventory and all(p['manifest_valid_plist'] for p in inventory)),
          'Resolved native plugin manifests parse as plists; actual bundled manifests/signatures must still be checked in the archive.')
    missing_resources = [p['name'] + ': ' + resource for p in inventory for resource in p['missing_podspec_resources']]
    check('native_sdk_resource_paths', bool(inventory and not missing_resources),
          'Raw resolved podspec manifest paths missing on disk: ' + ('; '.join(missing_resources) or 'none') + '. The geocoding Podfile repair must be verified by pod install/archive before clearing this source warning.')
    sdk_defaults = [e for p in inventory if p['name'] == 'shared_preferences_foundation' for e in p['api_reasons'] if e['api'] == 'NSPrivacyAccessedAPICategoryUserDefaults']
    check('sdk_defaults_reason_review', any('CA92.1' in e['reasons'] or 'C56D.1' in e['reasons'] for e in sdk_defaults),
          'The resolved preferences SDK declares its own UserDefaults reasons. A group-only 1C8F.1 declaration needs vendor/archive review for this app-private usage; the app manifest cannot substitute for it.')
    app_manifest = root / 'ios/Runner/PrivacyInfo.xcprivacy'
    manifest = plist('ios/Runner/PrivacyInfo.xcprivacy')
    check('app_privacy_manifest', app_manifest.is_file() and bool(manifest) and 'PrivacyInfo.xcprivacy in Resources' in project,
          'Scoped app API manifest is included in Runner resources; this is not a complete data-collection declaration or approval.')
    check('app_privacy_api_scope', manifest.get('NSPrivacyAccessedAPITypes') == [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryUserDefaults', 'NSPrivacyAccessedAPITypeReasons': ['CA92.1']}],
          'Current app-owned API declaration is app-private UserDefaults only; review new API usage before changing this explicit scope.')
    collection = manifest.get('NSPrivacyCollectedDataTypes')
    check('app_privacy_collection_review', isinstance(collection, list) and bool(collection) and isinstance(manifest.get('NSPrivacyTracking'), bool),
          'App collection/tracking declarations remain incomplete until the actual production data inventory is reviewed; an empty no-data list is not valid for this account/UGC app.')
    for plugin in ('flutter_secure_storage', 'share_plus'):
        check(plugin + '_locked', plugin in packages, f'{plugin} must resolve in pubspec.lock; native packaging and behavior remain device gates.')
    return {'scope': 'static source and supplied public configuration only; not App Store approval',
            'checks': checks, 'manual_validation': MANUAL,
            'resolved_native_sdk_inventory': inventory,
            'static_checks_passed': all(c['status'] == 'CHECKED' for c in checks)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, help='Public release metadata/defines JSON, never secrets. Missing values intentionally block.')
    parser.add_argument('--json', action='store_true', help='Print machine-readable results without supplied configuration values.')
    args = parser.parse_args()
    config = {}
    if args.config:
        try:
            config = json.loads(args.config.read_text())
            if not isinstance(config, dict) or any(not isinstance(config.get(k, {}), dict) for k in ('app', 'dart_defines', 'backend')):
                raise ValueError('Expected a JSON object with app/dart_defines/backend objects.')
        except (OSError, ValueError) as error:
            parser.error(str(error))
    report = check_release(ROOT, config)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print('Release preflight: ' + report['scope'])
        for check in report['checks']:
            print(f"[{check['status']}] {check['id']}: {check['detail']}")
        print('\nManual release gates (not executed by this script):')
        for item in report['manual_validation']:
            print('- ' + item)
        blocked = sum(c['status'] == 'BLOCKED' for c in report['checks'])
        print(f'\n{blocked} unresolved static gate(s). Native validation and release decisions remain separate.')
    return 0 if report['static_checks_passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
