#!/usr/bin/env python3
"""Portable evidence-retention tests; no Xcode execution or clean-build claims."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('summarize-native-diagnostics.py')
SPEC = importlib.util.spec_from_file_location('native_diagnostics', SCRIPT)
DIAGNOSTICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DIAGNOSTICS)

# Verbatim terminal evidence from the surviving Oct 2 CI log. The retained log
# began mid-line after the original capture was tailed to 65,536 characters.
# These are five issue-producing commands, not evidence of only five findings.
SURVIVING_SUMMARY = '''** ANALYZE SUCCEEDED **


The following commands produced analyzer issues:
\tAnalyze /Users/runner/.pub-cache/hosted/pub.dev/geolocator_apple-2.3.14/darwin/geolocator_apple/Sources/geolocator_apple/Utils/LocationDistanceMapper.m normal arm64 (in target 'geolocator_apple' from project 'Pods')
\tAnalyze /Users/runner/.pub-cache/hosted/pub.dev/geolocator_apple-2.3.14/darwin/geolocator_apple/Sources/geolocator_apple/Utils/LocationAccuracyMapper.m normal arm64 (in target 'geolocator_apple' from project 'Pods')
\tAnalyze /Users/runner/.pub-cache/hosted/pub.dev/geolocator_apple-2.3.14/darwin/geolocator_apple/Sources/geolocator_apple/Utils/ActivityTypeMapper.m normal arm64 (in target 'geolocator_apple' from project 'Pods')
\tAnalyze /Users/runner/.pub-cache/hosted/pub.dev/image_picker_ios-0.8.13/ios/image_picker_ios/Sources/image_picker_ios/FLTImagePickerPlugin.m normal arm64 (in target 'image_picker_ios' from project 'Pods')
\tAnalyze /Users/runner/.pub-cache/hosted/pub.dev/image_picker_ios-0.8.13/ios/image_picker_ios/Sources/image_picker_ios/FLTImagePickerPhotoAssetUtil.m normal arm64 (in target 'image_picker_ios' from project 'Pods')
(5 commands with analyzer issues)
'''


class NativeDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'xcode.log'

    def summarize(self, text, **options):
        self.path.write_bytes(text if isinstance(text, bytes) else text.encode('utf-8'))
        return DIAGNOSTICS.summarize_log(self.path, **options)

    def test_source_diagnostics_retain_actionable_location_and_message(self):
        report = self.summarize(
            'Analyze /project/Maps/Mapper.m normal arm64\n'
            '\x1b[33m/project/Maps/Mapper.m:42:9: warning: Value stored to value is never read [deadcode.DeadStores]\x1b[0m\n'
            '/project/App Delegate.swift:12: error: Cannot find type Missing in scope\n'
            "clang: fatal error: 'missing.h' file not found\n"
            'ld: warning: duplicate library ignored\n'
            '** ANALYZE FAILED **\n', input_completeness='complete', xcode_exit_code=65)
        self.assertEqual(report['assessment'], 'review_required')
        self.assertEqual(report['diagnostic_counts'], {'warning': 2, 'error': 1, 'fatal error': 1})
        detail = report['evidence']['diagnostics'][0]
        self.assertEqual((detail['source'], detail['source_line'], detail['source_column']),
                         ('/project/Maps/Mapper.m', 42, 9))
        self.assertIn('[deadcode.DeadStores]', detail['text'])
        self.assertEqual(detail['log_line'], 2)
        self.assertNotIn('\x1b', detail['text'])
        self.assertFalse(report['truncation']['report_truncated'])

    def test_surviving_ci_summary_cannot_be_mistaken_for_clean_analysis(self):
        report = self.summarize('dData/Build/Intermediates.noindex/partial.scan\n' + SURVIVING_SUMMARY,
                                input_completeness='partial', xcode_exit_code=0)
        self.assertEqual(report['assessment'], 'review_required')
        self.assertEqual(report['diagnostic_counts']['warning'], 0)
        self.assertEqual(report['action_result_markers']['analyze']['succeeded'], 1)
        self.assertEqual(report['analyzer']['largest_reported_command_count'], 5)
        self.assertEqual(report['analyzer']['issue_command_lines'], 5)
        self.assertEqual(len(report['evidence']['analyzer_commands']), 5)
        self.assertTrue(any('no source diagnostic details' in gap for gap in report['evidence_gaps']))
        self.assertEqual(report['input']['effective_completeness'], 'partial')
        self.assertIn('FLTImagePickerPhotoAssetUtil.m', report['evidence']['analyzer_commands'][-1]['text'])

    def test_complete_scan_keeps_early_diagnostics_despite_noisy_tail(self):
        text = '/source/Early.m:3:4: warning: Dereference of null pointer\n' + ('CompileC noisy command\n' * 10000) + SURVIVING_SUMMARY
        report = self.summarize(text, input_completeness='complete', xcode_exit_code=0)
        self.assertEqual(report['diagnostic_counts']['warning'], 1)
        self.assertEqual(report['evidence']['diagnostics'][0]['log_line'], 1)
        self.assertEqual(report['input']['bytes_scanned'], len(text.encode('utf-8')))
        self.assertEqual(report['input']['sha256'], hashlib.sha256(text.encode('utf-8')).hexdigest())
        self.assertEqual(report['analyzer']['issue_command_lines'], 5)

    def test_bounded_unicode_report_preserves_totals_and_summary(self):
        text = ''.join(f'/source/{index}.m:2:7: warning: ' + ('地' * 3000) + '\n' for index in range(500)) + SURVIVING_SUMMARY
        report = self.summarize(text, input_completeness='complete', xcode_exit_code=0, max_report_bytes=8192)
        encoded = DIAGNOSTICS.encode_report(report).encode('utf-8')
        self.assertLessEqual(len(encoded), 8192)
        self.assertEqual(report['diagnostic_counts']['warning'], 500)
        self.assertTrue(report['truncation']['report_truncated'])
        self.assertGreater(report['truncation']['text_clipped_entries'], 0)
        kept = len(report['evidence']['diagnostics'])
        self.assertEqual(report['truncation']['omitted_entries']['diagnostics'], 500 - kept)
        self.assertEqual(report['analyzer']['largest_reported_command_count'], 5)
        self.assertEqual(json.loads(encoded)['assessment'], 'review_required')

    def test_success_or_empty_input_never_claims_clean_analysis(self):
        report = self.summarize('', xcode_exit_code=0)
        self.assertEqual(report['assessment'], 'insufficient_evidence')
        self.assertEqual(report['input']['lines_scanned'], 0)
        self.assertEqual(report['input']['effective_completeness'], 'unknown')
        report = self.summarize('** ANALYZE SUCCEEDED **\n', input_completeness='complete', xcode_exit_code=0)
        self.assertEqual(report['assessment'], 'no_diagnostics_observed')
        self.assertIn('no clean analysis', report['scope'])
        self.assertIn('not proof of zero findings', ' '.join(report['limitations']))

    def test_nonzero_exit_is_review_required_without_parsed_errors(self):
        report = self.summarize('The operation could not be completed\n', input_completeness='complete', xcode_exit_code=65)
        self.assertEqual(report['assessment'], 'review_required')
        self.assertTrue(any('No terminal ANALYZE' in gap for gap in report['evidence_gaps']))

    def test_compiler_summary_without_details_remains_review_required(self):
        report = self.summarize('3 warnings and 1 error generated.\n** ANALYZE SUCCEEDED **\n',
                                input_completeness='complete', xcode_exit_code=0)
        self.assertEqual(report['assessment'], 'review_required')
        self.assertEqual(report['compiler_summary_counts'], {'warning': 3, 'error': 1})
        self.assertEqual(report['diagnostic_counts']['warning'], 0)
        self.assertTrue(any('Compiler summaries report diagnostics' in gap for gap in report['evidence_gaps']))

    def test_project_warning_without_source_line_is_retained(self):
        report = self.summarize("/project/My App/Pods.xcodeproj: warning: The iOS deployment target is below the supported range\n")
        self.assertEqual(report['diagnostic_counts']['warning'], 1)
        self.assertIn('Pods.xcodeproj', report['evidence']['diagnostics'][0]['text'])

    def test_truncated_and_non_utf8_input_disclose_evidence_gaps(self):
        report = self.summarize(b'Warning: truncated output (original token count: 9000)\n/source/File.m:3: warning: bad \xff\n** ANALYZE SUCCEEDED **\n',
                                input_completeness='complete', xcode_exit_code=0)
        self.assertEqual(report['input']['effective_completeness'], 'partial')
        self.assertEqual(report['input']['utf8_replacement_lines'], 1)
        self.assertEqual(report['input']['capture_truncation_markers'], 1)
        self.assertEqual(report['diagnostic_counts']['warning'], 1)

    def test_normal_analyze_commands_and_compiler_flags_are_not_findings(self):
        report = self.summarize('Analyze /source/File.m normal arm64\n    clang -Werror=return-type -Wno-unused-variable\n    export WARNINGS=YES\n',
                                input_completeness='complete', xcode_exit_code=0)
        self.assertEqual(report['analyzer']['issue_command_lines'], 0)
        self.assertFalse(any(report['diagnostic_counts'].values()))
        self.assertEqual(report['assessment'], 'insufficient_evidence')

    def test_incomplete_issue_section_still_reports_findings(self):
        report = self.summarize('The following commands produced analyzer issues:\n\tAnalyze /source/F.m normal arm64\n')
        self.assertEqual(report['assessment'], 'review_required')
        self.assertEqual(report['analyzer']['issue_command_lines'], 1)
        self.assertIsNone(report['analyzer']['largest_reported_command_count'])
        self.assertTrue(any('no reported closing command count' in gap for gap in report['evidence_gaps']))

    def test_cli_is_deterministic_and_exit_zero_only_means_report_written(self):
        self.path.write_text(SURVIVING_SUMMARY)
        command = [sys.executable, '-B', str(SCRIPT), str(self.path), '--input-completeness', 'partial', '--xcode-exit-code', '0']
        first = subprocess.run(command, capture_output=True, check=False)
        second = subprocess.run(command, capture_output=True, check=False)
        self.assertEqual(first.returncode, 0)
        self.assertEqual(first.stdout, second.stdout)
        self.assertFalse(first.stderr)
        self.assertEqual(json.loads(first.stdout)['assessment'], 'review_required')
        self.assertLessEqual(len(first.stdout), DIAGNOSTICS.DEFAULT_REPORT_BYTES)

    def test_cli_rejects_unreadable_input_and_invalid_limits(self):
        for args in ((str(self.path),), (str(self.path), '--max-report-bytes', '1024'),
                     (str(self.path), '--xcode-exit-code', '-1')):
            result = subprocess.run([sys.executable, '-B', str(SCRIPT), *args], capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(result.stdout)
            self.assertIn('ERROR:', result.stderr)


if __name__ == '__main__':
    unittest.main()
