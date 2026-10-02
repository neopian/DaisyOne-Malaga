#!/usr/bin/env python3
"""Retain bounded Xcode log evidence without claiming a clean native analysis.

Read a complete capture before any CI log-tail limit is applied. JSON goes to
stdout; exit 0 means the report was generated, not that Xcode or analysis passed.
Exit 2 means invalid invocation or unreadable input. This does not read xcresult,
run tools, change dependencies, or establish release readiness.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys


DEFAULT_REPORT_BYTES = 32768
MAX_ENTRIES = 80
MAX_TEXT_CHARS = 1200
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
SOURCE_DIAGNOSTIC = re.compile(
    r'^(?P<source>.+?):(?P<line>\d+)(?::(?P<column>\d+))?:\s*'
    r'(?P<severity>fatal error|error|warning):\s*(?P<message>.*)$')
TOOL_DIAGNOSTIC = re.compile(
    r'^(?:(?:clang(?:\+\+)?|ld|ld64|swift(?:c|-frontend)?|xcodebuild|'
    r'ibtool|actool|metal|[^:]+\.(?:xcassets|xcodeproj|xcworkspace|storyboard|xib)):\s*)?'
    r'(?P<severity>fatal error|error|warning):\s*(?P<message>.*)$', re.I)
RESULT = re.compile(r'^\*\* (BUILD|ANALYZE) (SUCCEEDED|FAILED) \*\*$')
ISSUE_COUNT = re.compile(r'^\((\d+) commands? with analyzer issues?\)$')
GENERATED_COUNT = re.compile(r'^\d+ (?:warnings?|errors?)(?: and \d+ (?:warnings?|errors?))? generated\.$')
TRUNCATION = re.compile(
    r'^(?:Warning: truncated output|\[.*truncat.*\]|\.\.\.\s*(?:output |log )?truncated)', re.I)
ISSUE_HEADER = 'The following commands produced analyzer issues:'


def encode_report(report):
    """Stable UTF-8 representation, including the final newline in the budget."""
    return json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + '\n'


def summarize_log(path, *, input_completeness='unknown', xcode_exit_code=None,
                  max_report_bytes=DEFAULT_REPORT_BYTES):
    """Scan every available line; completeness is a caller assertion, not inferred.

    Counts are line occurrences, not unique findings. Analyzer command counts
    are kept separate from diagnostics: one command may report many findings.
    Retained evidence is first-in-log order with explicit per-category omissions.
    """
    if input_completeness not in ('complete', 'partial', 'unknown'):
        raise ValueError('input completeness must be complete, partial or unknown')
    if not 8192 <= max_report_bytes <= 65536:
        raise ValueError('report byte limit must be between 8192 and 65536')
    if xcode_exit_code is not None and not 0 <= xcode_exit_code <= 255:
        raise ValueError('Xcode exit code must be between 0 and 255')

    evidence = {name: [] for name in ('diagnostics', 'analyzer_commands', 'summaries')}
    observed = dict.fromkeys(evidence, 0)
    diagnostic_counts = dict.fromkeys(('warning', 'error', 'fatal error'), 0)
    compiler_reported_counts = dict.fromkeys(('warning', 'error'), 0)
    results = {action: {'succeeded': 0, 'failed': 0} for action in ('build', 'analyze')}
    digest = hashlib.sha256()
    total_bytes = total_lines = decode_errors = source_diagnostics = 0
    clipped_entries = truncation_markers = issue_headers = count_summaries = 0
    largest_reported_command_count = None
    in_issue_summary = False

    def retain(category, log_line, text, **fields):
        nonlocal clipped_entries
        observed[category] += 1
        if len(evidence[category]) >= MAX_ENTRIES:
            return
        # Clip every source-derived string, including unusually long filenames.
        entry = {'log_line': log_line, 'text': text, **fields}
        clipped = False
        for key, value in entry.items():
            if isinstance(value, str) and len(value) > MAX_TEXT_CHARS:
                entry[key] = value[:MAX_TEXT_CHARS] + ' [truncated]'
                clipped = True
        entry['text_truncated'] = clipped
        clipped_entries += int(clipped)
        evidence[category].append(entry)

    with Path(path).open('rb') as stream:
        for total_lines, raw in enumerate(stream, 1):
            total_bytes += len(raw)
            digest.update(raw)
            try:
                decoded = raw.decode('utf-8')
            except UnicodeDecodeError:
                decoded = raw.decode('utf-8', errors='replace')
                decode_errors += 1
            line = ANSI.sub('', decoded).strip()
            if TRUNCATION.match(line):
                truncation_markers += 1
                retain('summaries', total_lines, line, kind='capture_truncation')
                continue
            if line == ISSUE_HEADER:
                issue_headers += 1
                in_issue_summary = True
                retain('summaries', total_lines, line, kind='analyzer_issue_header')
                continue
            count = ISSUE_COUNT.fullmatch(line)
            if count:
                value = int(count[1])
                count_summaries += 1
                largest_reported_command_count = max(largest_reported_command_count or 0, value)
                retain('summaries', total_lines, line, kind='analyzer_issue_count', commands=value)
                in_issue_summary = False
                continue
            if in_issue_summary and line.startswith(('Analyze ', 'AnalyzeC ', 'AnalyzeSwift ')):
                retain('analyzer_commands', total_lines, line)
                continue
            if line:
                in_issue_summary = False
            result = RESULT.fullmatch(line)
            if result:
                results[result[1].lower()][result[2].lower()] += 1
                retain('summaries', total_lines, line, kind='action_result')
                continue
            if GENERATED_COUNT.fullmatch(line):
                for amount, severity in re.findall(r'(\d+) (warning|error)s?', line):
                    compiler_reported_counts[severity] += int(amount)
                retain('summaries', total_lines, line, kind='compiler_diagnostic_count')
                continue
            match = SOURCE_DIAGNOSTIC.match(line)
            if match:
                source_diagnostics += 1
                fields = {'source': match['source'], 'source_line': int(match['line']),
                          'source_column': int(match['column']) if match['column'] else None}
            else:
                match = TOOL_DIAGNOSTIC.match(line)
                fields = {}
            if match:
                severity = match['severity'].lower()
                diagnostic_counts[severity] += 1
                retain('diagnostics', total_lines, line, severity=severity, **fields)

    effective_completeness = 'partial' if truncation_markers else input_completeness
    gaps = []
    if effective_completeness != 'complete':
        gaps.append('The caller has not supplied an untruncated complete invocation log.')
    if decode_errors:
        gaps.append('Some input lines required UTF-8 replacement; diagnostic text may be incomplete.')
    if xcode_exit_code is None:
        gaps.append('The Xcode process exit code was not supplied.')
    if not any(results['analyze'].values()):
        gaps.append('No terminal ANALYZE result marker was observed.')
    if issue_headers and not count_summaries:
        gaps.append('An analyzer issue-command section has no reported closing command count.')
    issues_reported = bool(issue_headers or largest_reported_command_count
                           or observed['analyzer_commands'])
    if issues_reported and not source_diagnostics:
        gaps.append('Analyzer issue commands are reported, but no source diagnostic details survive in this input.')
    if any(compiler_reported_counts.values()) and not observed['diagnostics']:
        gaps.append('Compiler summaries report diagnostics, but no diagnostic detail lines were observed.')
    if results['analyze']['succeeded'] and results['analyze']['failed']:
        gaps.append('Conflicting ANALYZE result markers were observed; inspect the full capture.')
    has_findings = bool(observed['diagnostics'] or any(compiler_reported_counts.values()) or issues_reported
                        or xcode_exit_code not in (None, 0)
                        or any(value['failed'] for value in results.values()))
    report = {
        'schema_version': 1,
        'scope': 'Xcode text-log evidence only; no clean analysis or release-readiness conclusion is established.',
        'assessment': 'review_required' if has_findings else ('insufficient_evidence' if gaps else 'no_diagnostics_observed'),
        'input': {'declared_completeness': input_completeness,
                  'effective_completeness': effective_completeness,
                  'all_available_bytes_scanned': True, 'bytes_scanned': total_bytes,
                  'lines_scanned': total_lines, 'sha256': digest.hexdigest(),
                  'utf8_replacement_lines': decode_errors,
                  'capture_truncation_markers': truncation_markers},
        'xcode_exit_code': xcode_exit_code,
        'action_result_markers': results,
        'diagnostic_counts': diagnostic_counts,
        'compiler_summary_counts': compiler_reported_counts,
        'source_diagnostic_lines': source_diagnostics,
        'analyzer': {'issue_section_headers': issue_headers,
                     'issue_command_lines': observed['analyzer_commands'],
                     'command_count_summaries': count_summaries,
                     'largest_reported_command_count': largest_reported_command_count,
                     'command_counts_are_not_finding_counts': True,
                     'details_correlated_to_issue_commands': False},
        'evidence_gaps': gaps,
        'evidence': evidence,
        'report_limits': {'max_report_bytes': max_report_bytes,
                          'max_entries_per_category': MAX_ENTRIES,
                          'max_text_chars_per_field': MAX_TEXT_CHARS},
        'truncation': {'report_truncated': False, 'text_clipped_entries': clipped_entries,
                       'omitted_entries': {}, 'evidence_retention': 'First occurrences per category; all input lines counted.'},
        'limitations': [
            'Text formats are recognized heuristically; zero parsed diagnostics is not proof of zero findings.',
            'Counts represent log occurrences; compiler summaries may repeat diagnostic details or compilation passes.',
            'Success markers and exit code 0 describe command execution, not an issue-free analyzer result.',
            'Retain and review the original full log and xcresult bundle, especially when evidence is partial or omitted.',
        ],
    }

    def update_truncation():
        omitted = {name: observed[name] - len(items) for name, items in evidence.items()}
        report['truncation']['omitted_entries'] = omitted
        report['truncation']['report_truncated'] = bool(clipped_entries or any(omitted.values()))

    update_truncation()
    # Keep counts and conclusions even when exceptionally noisy logs exhaust the
    # byte budget. Protect issue-command and summary evidence as long as possible.
    for category in ('diagnostics', 'analyzer_commands', 'summaries'):
        while len(encode_report(report).encode('utf-8')) > max_report_bytes and evidence[category]:
            evidence[category].pop()
            update_truncation()
    if len(encode_report(report).encode('utf-8')) > max_report_bytes:
        raise ValueError('report metadata exceeds byte limit')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path, help='Unmodified full xcodebuild log whenever available')
    parser.add_argument('--input-completeness', choices=('complete', 'partial', 'unknown'), default='unknown',
                        help='Caller assertion about original capture; defaults to unknown')
    parser.add_argument('--xcode-exit-code', type=int, help='Actual xcodebuild process exit code, when known')
    parser.add_argument('--max-report-bytes', type=int, default=DEFAULT_REPORT_BYTES,
                        help='UTF-8 JSON byte limit including newline, 8192..65536 (default: 32768)')
    args = parser.parse_args()
    try:
        report = summarize_log(args.log, input_completeness=args.input_completeness,
                               xcode_exit_code=args.xcode_exit_code,
                               max_report_bytes=args.max_report_bytes)
    except (OSError, ValueError) as error:
        parser.exit(2, f'ERROR: Cannot summarize native diagnostics: {error}\n')
    sys.stdout.buffer.write(encode_report(report).encode('utf-8'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
