#!/usr/bin/env python3
"""Validate, persist, and compact metadata-only Wiki maintenance reports."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any


REPORT_KIND = 'grill-adapter.wiki-maintenance-report'
REPORT_PATH = re.compile(
    r'^\.grill-adapter/context/[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?/wiki-maintenance-audit\.json$'
)
UTC_SECONDS = re.compile(
    r'^[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T'
    r'(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$'
)
DIGEST = re.compile(r'^[0-9a-f]{64}$')
SNAPSHOT_HASH = re.compile(r'^sha256:[0-9a-f]{64}$')
IDENTITY = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,255}$')
FINDING_ID = re.compile(r'^[a-z0-9][a-z0-9._-]{0,63}$')
FINDING_CATEGORIES = frozenset({'freshness', 'contradiction', 'overloaded-note'})
SEVERITIES = frozenset({'info', 'warning', 'critical'})
RECOMMENDED_ACTIONS = frozenset(
    {'review-note', 'resolve-contradiction', 'split-note', 'no-action'}
)
FINDING_CONTRACTS = {
    'freshness': (frozenset({'review-date-reached', 'expiry-date-reached'}), 'review-note'),
    'contradiction': (frozenset({'typed-contradiction-present'}), 'resolve-contradiction'),
    'overloaded-note': (
        frozenset({'independent-contracts-share-one-note'}),
        'split-note',
    ),
}
CAVEAT_CODES = frozenset(
    {
        'identity-limit-reached',
        'maintenance-summary-warning',
        'note-read-limit-reached',
        'repository-base-unverified',
    }
)


class ReportError(ValueError):
    pass


def fail(field: str) -> None:
    raise ReportError(f'invalid {field}')


def exact_keys(value: Any, keys: set[str], field: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        fail(field)
    return value


def integer(value: Any, field: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        fail(field)
    return value


def text(value: Any, field: str, maximum: int, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or len(value) > maximum or (not allow_empty and not value.strip()):
        fail(field)
    if any(ord(character) < 32 and character not in '\t\n\r' for character in value):
        fail(field)
    return value


def enum(value: Any, allowed: frozenset[str], field: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        fail(field)
    return value


def timestamp(value: Any, field: str) -> str:
    candidate = text(value, field, 20)
    if not UTC_SECONDS.fullmatch(candidate):
        fail(field)
    try:
        parsed = datetime.strptime(candidate, '%Y-%m-%dT%H:%M:%SZ')
    except ValueError:
        fail(field)
    if parsed.strftime('%Y-%m-%dT%H:%M:%SZ') != candidate:
        fail(field)
    return candidate


def validate_identity(value: Any, field: str) -> dict[str, str]:
    row = exact_keys(value, {'sourceId', 'wikiId'}, field)
    for key in ('sourceId', 'wikiId'):
        candidate = text(row[key], f'{field}.{key}', 256)
        if not IDENTITY.fullmatch(candidate) or '..' in candidate:
            fail(f'{field}.{key}')
    return row


def validate_report(value: Any) -> dict[str, Any]:
    report = exact_keys(
        value,
        {
            'schemaVersion',
            'kind',
            'authoritative',
            'mode',
            'status',
            'asOf',
            'limits',
            'scanned',
            'findings',
            'snapshotIdentity',
            'caveats',
        },
        'report shape',
    )
    if report['schemaVersion'] != 1 or report['kind'] != REPORT_KIND:
        fail('report identity')
    if report['authoritative'] is not False or report['mode'] != 'audit':
        fail('report authority or mode')
    enum(report['status'], frozenset({'ok', 'partial'}), 'status')
    as_of = timestamp(report['asOf'], 'asOf')

    limits = exact_keys(report['limits'], {'identityLimit', 'noteReadLimit'}, 'limits')
    identity_limit = integer(limits['identityLimit'], 'limits.identityLimit', 1, 200)
    note_read_limit = integer(limits['noteReadLimit'], 'limits.noteReadLimit', 1, 24)

    scanned = exact_keys(
        report['scanned'],
        {
            'sources',
            'activeNotes',
            'reviewDueNotes',
            'expiredNotes',
            'contradictoryNotes',
            'noteBodiesRead',
        },
        'scanned',
    )
    for key in ('sources', 'activeNotes', 'reviewDueNotes', 'expiredNotes', 'contradictoryNotes'):
        integer(scanned[key], f'scanned.{key}', 0, 1_000_000)
    note_bodies_read = integer(
        scanned['noteBodiesRead'], 'scanned.noteBodiesRead', 0, note_read_limit
    )

    findings = report['findings']
    if not isinstance(findings, list) or len(findings) > identity_limit:
        fail('findings')
    finding_ids: set[str] = set()
    total_affected = 0
    for index, raw_finding in enumerate(findings):
        field = f'findings[{index}]'
        finding = exact_keys(
            raw_finding,
            {
                'findingId',
                'category',
                'severity',
                'affectedWikiIdentities',
                'reason',
                'recommendedAction',
            },
            field,
        )
        finding_id = text(finding['findingId'], f'{field}.findingId', 64)
        if not FINDING_ID.fullmatch(finding_id) or finding_id in finding_ids:
            fail(f'{field}.findingId')
        finding_ids.add(finding_id)
        category = enum(finding['category'], FINDING_CATEGORIES, f'{field}.category')
        enum(finding['severity'], SEVERITIES, f'{field}.severity')
        recommended_action = enum(
            finding['recommendedAction'],
            RECOMMENDED_ACTIONS,
            f'{field}.recommendedAction',
        )
        allowed_reasons, expected_action = FINDING_CONTRACTS[category]
        enum(finding['reason'], allowed_reasons, f'{field}.reason')
        if recommended_action != expected_action:
            fail(f'{field}.recommendedAction')
        identities = finding['affectedWikiIdentities']
        if not isinstance(identities, list) or not identities:
            fail(f'{field}.affectedWikiIdentities')
        seen_identities: set[tuple[str, str]] = set()
        for identity_index, raw_identity in enumerate(identities):
            identity = validate_identity(
                raw_identity, f'{field}.affectedWikiIdentities[{identity_index}]'
            )
            key = (identity['sourceId'], identity['wikiId'])
            if key in seen_identities:
                fail(f'{field}.affectedWikiIdentities')
            seen_identities.add(key)
        total_affected += len(identities)
    if total_affected > identity_limit:
        fail('affected Wiki identity limit')

    snapshot = exact_keys(
        report['snapshotIdentity'],
        {'summarySchemaVersion', 'asOf', 'bindings', 'auditedNoteSnapshots'},
        'snapshotIdentity',
    )
    if snapshot['summarySchemaVersion'] != 1 or timestamp(snapshot['asOf'], 'snapshotIdentity.asOf') != as_of:
        fail('snapshotIdentity summary')
    bindings = snapshot['bindings']
    if not isinstance(bindings, list) or len(bindings) != scanned['sources'] or len(bindings) > 200:
        fail('snapshotIdentity.bindings')
    seen_sources: set[str] = set()
    for index, raw_binding in enumerate(bindings):
        field = f'snapshotIdentity.bindings[{index}]'
        binding = exact_keys(raw_binding, {'sourceId', 'role', 'bindingDigest'}, field)
        source_id = text(binding['sourceId'], f'{field}.sourceId', 256)
        if not IDENTITY.fullmatch(source_id) or '..' in source_id or source_id in seen_sources:
            fail(f'{field}.sourceId')
        seen_sources.add(source_id)
        enum(binding['role'], frozenset({'project', 'shared'}), f'{field}.role')
        digest = text(binding['bindingDigest'], f'{field}.bindingDigest', 64)
        if not DIGEST.fullmatch(digest):
            fail(f'{field}.bindingDigest')
    audited_snapshots = snapshot['auditedNoteSnapshots']
    if not isinstance(audited_snapshots, list) or len(audited_snapshots) > len(bindings):
        fail('snapshotIdentity.auditedNoteSnapshots')
    audited_sources: set[str] = set()
    audited_note_count = 0
    for index, raw_audited in enumerate(audited_snapshots):
        field = f'snapshotIdentity.auditedNoteSnapshots[{index}]'
        audited = exact_keys(raw_audited, {'sourceId', 'noteCount', 'snapshotHash'}, field)
        source_id = text(audited['sourceId'], f'{field}.sourceId', 256)
        if source_id not in seen_sources or source_id in audited_sources:
            fail(f'{field}.sourceId')
        audited_sources.add(source_id)
        audited_note_count += integer(audited['noteCount'], f'{field}.noteCount', 1, note_read_limit)
        snapshot_hash = text(audited['snapshotHash'], f'{field}.snapshotHash', 71)
        if not SNAPSHOT_HASH.fullmatch(snapshot_hash):
            fail(f'{field}.snapshotHash')
    if audited_note_count != note_bodies_read:
        fail('snapshotIdentity audited Note count')

    caveats = report['caveats']
    if not isinstance(caveats, list) or len(caveats) > 20:
        fail('caveats')
    seen_caveats: set[str] = set()
    for index, caveat in enumerate(caveats):
        code = enum(caveat, CAVEAT_CODES, f'caveats[{index}]')
        if code in seen_caveats:
            fail('caveats')
        seen_caveats.add(code)
    if report['status'] == 'partial' and not caveats:
        fail('partial caveats')
    return report


def duplicate_safe_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ReportError('duplicate JSON key')
        result[key] = value
    return result


def load_json_stream(stream: Any) -> dict[str, Any]:
    try:
        value = json.load(stream, object_pairs_hook=duplicate_safe_object)
    except json.JSONDecodeError as exc:
        raise ReportError(f'malformed JSON at line {exc.lineno}, column {exc.colno}') from exc
    return validate_report(value)


def load_path(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding='utf-8') as handle:
            return load_json_stream(handle)
    except OSError as exc:
        raise ReportError('report file is not readable') from exc


def dump(value: Any) -> str:
    return json.dumps(value, ensure_ascii=True, separators=(',', ':'), sort_keys=True)


def compact(report: dict[str, Any], report_path: str) -> dict[str, Any]:
    if not REPORT_PATH.fullmatch(report_path):
        fail('reportPath')
    categories = Counter(finding['category'] for finding in report['findings'])
    return {
        'status': report['status'],
        'mode': 'audit',
        'reportPath': report_path,
        'counts': {
            'sources': report['scanned']['sources'],
            'noteBodiesRead': report['scanned']['noteBodiesRead'],
            'findings': len(report['findings']),
        },
        'findingCounts': dict(sorted(categories.items())),
        'caveats': report['caveats'],
    }


def write_report(report: dict[str, Any], output: str) -> None:
    if not REPORT_PATH.fullmatch(output):
        fail('output path')
    target = Path(output)
    current = Path.cwd()
    for part in target.parent.parts:
        current = current / part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            try:
                current.mkdir(mode=0o700)
            except OSError as exc:
                raise ReportError('report directory could not be created') from exc
            metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            fail('report directory boundary')
    try:
        target_metadata = target.lstat()
    except FileNotFoundError:
        pass
    else:
        if stat.S_ISLNK(target_metadata.st_mode) or not stat.S_ISREG(target_metadata.st_mode):
            fail('report file boundary')
    try:
        fd, temporary = tempfile.mkstemp(prefix=f'.{target.name}.', dir=target.parent, text=True)
    except OSError as exc:
        raise ReportError('temporary report could not be created') from exc
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(dump(report) + '\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    except OSError as exc:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise ReportError('report could not be persisted') from exc


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest='command', required=True)
    validate = commands.add_parser('validate')
    validate.add_argument('report')
    write = commands.add_parser('write')
    write.add_argument('--output', required=True)
    compact_command = commands.add_parser('compact')
    compact_command.add_argument('report')
    compact_command.add_argument('--report-path', required=True)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == 'write':
            report = load_json_stream(sys.stdin)
            write_report(report, args.output)
            print(dump(compact(report, args.output)))
            return 0
        report = load_path(Path(args.report))
        if args.command == 'compact':
            print(dump(compact(report, args.report_path)))
        else:
            print(dump(report))
        return 0
    except ReportError as exc:
        print(f'Invalid Wiki maintenance report: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
