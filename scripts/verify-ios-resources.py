#!/usr/bin/env python3
"""Inspect an unsigned built Runner.app; presence is not privacy compliance."""
import hashlib
import json
import plistlib
from pathlib import Path
import re
import sys


PLUGIN_BUNDLES = (
    'flutter_secure_storage', 'geocoding_ios_privacy',
    'geolocator_apple_privacy', 'image_picker_ios_privacy',
    'package_info_plus_privacy', 'path_provider_foundation_privacy',
    'share_plus_privacy', 'shared_preferences_foundation_privacy',
    'url_launcher_ios_privacy',
)
IOS_MINIMUM = (15, 0, 0)


def os_version(value):
    """Parse plist versions numerically; 15.0 and 15.0.0 denote one floor."""
    if not isinstance(value, str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        return None
    components = tuple(int(part) for part in value.split('.'))
    return components + (0,) * (3 - len(components))


def inspect_app(app):
    errors = []
    inventory = []
    info = {}
    try:
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        if not isinstance(info, dict):
            raise ValueError('Info.plist is not a dictionary')
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        errors.append(f'Cannot parse built Info.plist: {error}')
        info = {}

    sdk = info.get('DTSDKName', '')
    sdk_match = re.fullmatch(r'iphoneos(\d+)(?:\.\d+)*', str(sdk))
    if not sdk_match or int(sdk_match[1]) < 26:
        errors.append(f'Built bundle does not record an iOS 26+ SDK: {sdk!r}')
    target = str(info.get('MinimumOSVersion', ''))
    if os_version(info.get('MinimumOSVersion')) != IOS_MINIMUM:
        errors.append(f'Built bundle minimum OS must match the approved iOS 15.0 floor: {target!r}')
    frameworks = []
    framework_root = app / 'Frameworks'
    required_frameworks = {framework_root / name for name in ('App.framework', 'Flutter.framework')}
    for framework in sorted(required_frameworks | set(framework_root.rglob('*.framework'))):
        relative = str(framework.relative_to(app))
        try:
            framework_info = plistlib.loads((framework / 'Info.plist').read_bytes())
            if not isinstance(framework_info, dict):
                raise ValueError('Info.plist is not a dictionary')
            minimum = framework_info.get('MinimumOSVersion')
            parsed = os_version(minimum)
            if parsed is None:
                errors.append(f'Embedded framework has no valid minimum OS: {relative}: {minimum!r}')
            elif parsed > IOS_MINIMUM:
                errors.append(f'Embedded framework requires newer than iOS 15.0: {relative}: {minimum!r}')
            frameworks.append({'path': relative, 'minimum_os': minimum})
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            errors.append(f'Cannot parse embedded framework Info.plist: {relative}: {error}')
    executable = info.get('CFBundleExecutable')
    if (not isinstance(executable, str) or not executable
            or Path(executable).name != executable
            or not (app / executable).is_file()):
        errors.append('Built app executable is missing or invalid')
    if not (app / 'Assets.car').is_file():
        errors.append('Compiled app asset catalog is missing')

    required = [app / 'PrivacyInfo.xcprivacy',
                app / 'Frameworks/Flutter.framework/PrivacyInfo.xcprivacy']
    for bundle in PLUGIN_BUNDLES:
        candidates = sorted(app.glob(f'**/{bundle}.bundle/PrivacyInfo.xcprivacy'))
        if not candidates:
            errors.append(f'Missing plugin manifest resource: {bundle}.bundle/PrivacyInfo.xcprivacy')
        required.extend(candidates)
    for path in required:
        if not path.is_file():
            errors.append(f'Missing manifest: {path.relative_to(app)}')
    # Include every manifest, including newly introduced SDKs, in the report.
    for path in sorted(app.rglob('*.xcprivacy')):
        relative = str(path.relative_to(app))
        try:
            raw = path.read_bytes()
            data = plistlib.loads(raw)
            if not isinstance(data, dict):
                raise ValueError('Manifest is not a dictionary')
            reasons = data.get('NSPrivacyAccessedAPITypes', [])
            if not isinstance(reasons, list):
                raise ValueError('NSPrivacyAccessedAPITypes is not an array')
            for entry in reasons:
                if (not isinstance(entry, dict)
                        or not isinstance(entry.get('NSPrivacyAccessedAPIType'), str)
                        or not isinstance(entry.get('NSPrivacyAccessedAPITypeReasons'), list)
                        or not all(isinstance(reason, str) for reason in entry['NSPrivacyAccessedAPITypeReasons'])):
                    raise ValueError('Invalid required-reason entry structure')
            inventory.append({'path': relative, 'sha256': hashlib.sha256(raw).hexdigest(),
                              'declaration': data})
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            errors.append(f'Invalid manifest {relative}: {error}')

    return {'scope': 'unsigned bundle structure and resource presence only',
            'app': str(app), 'sdk': sdk, 'minimum_os': target,
            'bundle_id': info.get('CFBundleIdentifier'),
            'frameworks': frameworks, 'manifests': inventory, 'errors': errors,
            'not_verified': ['code signing', 'device execution', 'privacy reason correctness',
                             'collection or tracking completeness', 'SDK signatures',
                             'production connectivity', 'App Store eligibility']}


def main():
    if len(sys.argv) != 2:
        sys.exit('Usage: python3 scripts/verify-ios-resources.py /path/to/Runner.app')
    result = inspect_app(Path(sys.argv[1]))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if result['errors'] else 0


if __name__ == '__main__':
    sys.exit(main())
