#!/usr/bin/env python3
"""Validate and persist metadata-only Wiki consolidation reports."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import stat
import sys
import tempfile
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, TextIO

from wiki_candidate_journal import JournalError, fold_events, read_events
from wiki_maintenance_report import (
    DIGEST,
    IDENTITY,
    REPORT_KIND,
    ReportError,
    dump,
    enum,
    exact_keys,
    fail,
    integer,
    text,
    timestamp,
    validate_identity,
)


REPORT_PATH = re.compile(
    r'^\.grill-adapter/context/[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?/'
    r'wiki-maintenance-consolidation\.json$'
)
FEATURE_SLUG = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')
CANDIDATE_ID = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')
GROUP_ID = re.compile(r'^[a-z0-9][a-z0-9._-]{0,63}$')
SNAPSHOT_DIGEST = re.compile(r'^sha256:[0-9a-f]{64}$')
RELATIONSHIP_CONTRACTS = {
    'equivalent': ('equivalent-durable-claim', 'capture-replacement'),
    'contradictory': ('contradictory-durable-claims', 'request-user-decision'),
}
CAVEAT_CODES = frozenset({'candidate-limit-reached', 'evidence-insufficient'})


@dataclass(frozen=True)
class ConsolidationRequest:
    as_of: str
    candidate_limit: int
    project_root: Path


def candidate_identity(value: Any, field: str) -> dict[str, str]:
    row = exact_keys(value, {'featureSlug', 'candidateId'}, field)
    feature_slug = text(row['featureSlug'], f'{field}.featureSlug', 128)
    candidate_id = text(row['candidateId'], f'{field}.candidateId', 128)
    if not FEATURE_SLUG.fullmatch(feature_slug):
        fail(f'{field}.featureSlug')
    if not CANDIDATE_ID.fullmatch(candidate_id):
        fail(f'{field}.candidateId')
    return row


def _sha256(value: bytes) -> str:
    return 'sha256:' + hashlib.sha256(value).hexdigest()


def _candidate_digest(
    journal_digest: str,
    feature_slug: str,
    candidate: dict[str, Any],
) -> str:
    identity = '\0'.join(
        (
            journal_digest,
            feature_slug,
            candidate['candidateId'],
            candidate['status'],
            candidate['lastEventId'],
        )
    )
    return _sha256(identity.encode('utf-8'))


def canonical_snapshot(project_root: Path, candidate_limit: int) -> dict[str, Any]:
    try:
        root = project_root.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise ReportError('project root is unavailable') from exc
    if not root.is_dir():
        fail('project root')
    context_root = root / '.grill-adapter' / 'context'
    if not context_root.exists():
        journals: list[dict[str, str]] = []
        candidates: list[dict[str, Any]] = []
        return {'journals': journals, 'candidates': candidates, 'candidateCount': 0}
    try:
        context_metadata = context_root.lstat()
    except OSError as exc:
        raise ReportError('context root is unavailable') from exc
    if stat.S_ISLNK(context_metadata.st_mode) or not stat.S_ISDIR(context_metadata.st_mode):
        fail('context root boundary')
    if context_root.resolve(strict=True) != root / '.grill-adapter' / 'context':
        fail('context root boundary')

    journals = []
    candidates = []
    try:
        entries = sorted(context_root.iterdir(), key=lambda path: path.name)
    except OSError as exc:
        raise ReportError('context root could not be scanned') from exc
    for feature_root in entries:
        metadata = feature_root.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            fail(f'feature context boundary for {feature_root.name}')
        if not stat.S_ISDIR(metadata.st_mode):
            continue
        if not FEATURE_SLUG.fullmatch(feature_root.name):
            fail('feature context identity')
        journal_path = feature_root / 'wiki-candidates.jsonl'
        try:
            journal_metadata = journal_path.lstat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise ReportError('candidate journal is unavailable') from exc
        if stat.S_ISLNK(journal_metadata.st_mode) or not stat.S_ISREG(journal_metadata.st_mode):
            fail(f'candidate journal boundary for {feature_root.name}')
        try:
            raw = journal_path.read_bytes()
            folded = fold_events(
                read_events(journal_path, require_nonempty=True),
                feature_root.name,
            )
        except (OSError, JournalError) as exc:
            raise ReportError(
                f'canonical candidate journal for {feature_root.name} is invalid'
            ) from exc
        journal_digest = _sha256(raw)
        journals.append(
            {'featureSlug': feature_root.name, 'journalDigest': journal_digest}
        )
        for candidate in folded['candidates']:
            if candidate['status'] not in {'pending', 'deferred'}:
                continue
            correction = candidate.get('correction')
            affected = (
                correction.get('affectedWikiIdentity')
                if isinstance(correction, dict)
                else None
            )
            candidates.append(
                {
                    'featureSlug': feature_root.name,
                    'candidateId': candidate['candidateId'],
                    'status': candidate['status'],
                    'kind': candidate['kind'],
                    'candidateDigest': _candidate_digest(
                        journal_digest, feature_root.name, candidate
                    ),
                    'affectedWikiIdentity': affected,
                }
            )
    candidates.sort(key=lambda row: (row['featureSlug'], row['candidateId']))
    return {
        'journals': journals,
        'candidates': candidates[:candidate_limit],
        'candidateCount': len(candidates),
    }


def validate_report(value: Any, expected: ConsolidationRequest) -> dict[str, Any]:
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
            'proposalGroups',
            'independentCandidateIdentities',
            'unresolvedCandidateIdentities',
            'snapshotIdentity',
            'caveats',
        },
        'report shape',
    )
    if report['schemaVersion'] != 1 or report['kind'] != REPORT_KIND:
        fail('report identity')
    if report['authoritative'] is not False or report['mode'] != 'consolidation':
        fail('report authority or mode')
    status_value = enum(report['status'], frozenset({'ok', 'partial'}), 'status')
    as_of = timestamp(report['asOf'], 'asOf')
    limits = exact_keys(report['limits'], {'candidateLimit'}, 'limits')
    limit = integer(limits['candidateLimit'], 'limits.candidateLimit', 1, 200)
    if as_of != expected.as_of or limit != expected.candidate_limit:
        fail('consolidation request identity')

    current = canonical_snapshot(expected.project_root, limit)
    scanned = exact_keys(
        report['scanned'], {'sources', 'featureJournals', 'candidates'}, 'scanned'
    )
    sources = integer(scanned['sources'], 'scanned.sources', 0, 200)
    if integer(scanned['featureJournals'], 'scanned.featureJournals', 0, 1_000_000) != len(current['journals']):
        fail('scanned.featureJournals')
    candidate_count = integer(scanned['candidates'], 'scanned.candidates', 0, 1_000_000)
    if candidate_count != current['candidateCount']:
        fail('scanned.candidates')

    snapshot = exact_keys(
        report['snapshotIdentity'],
        {'bindings', 'journalSnapshots', 'candidateSnapshots'},
        'snapshotIdentity',
    )
    bindings = snapshot['bindings']
    if not isinstance(bindings, list) or len(bindings) != sources:
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
        if not DIGEST.fullmatch(text(binding['bindingDigest'], f'{field}.bindingDigest', 64)):
            fail(f'{field}.bindingDigest')

    journal_snapshots = snapshot['journalSnapshots']
    if journal_snapshots != current['journals']:
        fail('snapshotIdentity.journalSnapshots or journal drift')
    candidate_snapshots = snapshot['candidateSnapshots']
    if candidate_snapshots != current['candidates']:
        fail('snapshotIdentity.candidateSnapshots or journal drift')
    visible_candidates = {
        (row['featureSlug'], row['candidateId']): row for row in current['candidates']
    }

    classified: set[tuple[str, str]] = set()
    group_ids: set[str] = set()
    proposal_groups = report['proposalGroups']
    if not isinstance(proposal_groups, list) or len(proposal_groups) > limit:
        fail('proposalGroups')
    for index, raw_group in enumerate(proposal_groups):
        field = f'proposalGroups[{index}]'
        group = exact_keys(
            raw_group,
            {
                'groupId',
                'relationship',
                'candidateIdentities',
                'affectedWikiIdentities',
                'reason',
                'recommendedAction',
            },
            field,
        )
        group_id = text(group['groupId'], f'{field}.groupId', 64)
        if not GROUP_ID.fullmatch(group_id) or group_id in group_ids:
            fail(f'{field}.groupId')
        group_ids.add(group_id)
        relationship = enum(
            group['relationship'], frozenset(RELATIONSHIP_CONTRACTS), f'{field}.relationship'
        )
        expected_reason, expected_action = RELATIONSHIP_CONTRACTS[relationship]
        if group['reason'] != expected_reason or group['recommendedAction'] != expected_action:
            fail(f'{field} relationship contract')
        identities = group['candidateIdentities']
        if not isinstance(identities, list) or len(identities) < 2:
            fail(f'{field}.candidateIdentities')
        group_candidates: list[dict[str, Any]] = []
        for identity_index, raw_identity in enumerate(identities):
            identity_value = candidate_identity(
                raw_identity, f'{field}.candidateIdentities[{identity_index}]'
            )
            key = (identity_value['featureSlug'], identity_value['candidateId'])
            if key not in visible_candidates or key in classified:
                fail(f'{field}.candidateIdentities')
            classified.add(key)
            group_candidates.append(visible_candidates[key])
        affected_values = group['affectedWikiIdentities']
        if not isinstance(affected_values, list):
            fail(f'{field}.affectedWikiIdentities')
        affected_keys: set[tuple[str, str]] = set()
        for affected_index, raw_affected in enumerate(affected_values):
            affected = validate_identity(
                raw_affected, f'{field}.affectedWikiIdentities[{affected_index}]'
            )
            key = (affected['sourceId'], affected['wikiId'])
            if key in affected_keys:
                fail(f'{field}.affectedWikiIdentities')
            affected_keys.add(key)
        expected_affected = {
            (row['affectedWikiIdentity']['sourceId'], row['affectedWikiIdentity']['wikiId'])
            for row in group_candidates
            if row['affectedWikiIdentity'] is not None
        }
        if affected_keys != expected_affected:
            fail(f'{field}.affectedWikiIdentities')

    def classify_list(name: str) -> set[tuple[str, str]]:
        values = report[name]
        if not isinstance(values, list) or len(values) > limit:
            fail(name)
        result: set[tuple[str, str]] = set()
        for index, raw_identity in enumerate(values):
            identity_value = candidate_identity(raw_identity, f'{name}[{index}]')
            key = (identity_value['featureSlug'], identity_value['candidateId'])
            if key not in visible_candidates or key in classified or key in result:
                fail(name)
            result.add(key)
        classified.update(result)
        return result

    classify_list('independentCandidateIdentities')
    unresolved = classify_list('unresolvedCandidateIdentities')
    if classified != set(visible_candidates):
        fail('candidate classification coverage')

    caveats = report['caveats']
    if not isinstance(caveats, list) or len(caveats) != len(set(caveats)):
        fail('caveats')
    for index, caveat in enumerate(caveats):
        enum(caveat, CAVEAT_CODES, f'caveats[{index}]')
    truncated = candidate_count > limit
    if ('candidate-limit-reached' in caveats) != truncated:
        fail('candidate-limit caveat')
    if ('evidence-insufficient' in caveats) != bool(unresolved):
        fail('evidence caveat')
    expected_status = 'partial' if truncated or unresolved else 'ok'
    if status_value != expected_status:
        fail('status')
    return report


def load_stream(stream: TextIO, expected: ConsolidationRequest) -> dict[str, Any]:
    try:
        value = json.load(stream)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ReportError('report is not valid JSON') from exc
    if stream.read().strip():
        fail('trailing report content')
    return validate_report(value, expected)


def read_path(path: Path) -> Any:
    try:
        with path.open('r', encoding='utf-8') as handle:
            try:
                value = json.load(handle)
            except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                raise ReportError('report is not valid JSON') from exc
            if handle.read().strip():
                fail('trailing report content')
            return value
    except OSError as exc:
        raise ReportError('report could not be read') from exc


def compact(report: dict[str, Any], report_path: str) -> dict[str, Any]:
    if not REPORT_PATH.fullmatch(report_path):
        fail('reportPath')
    relationships = Counter(group['relationship'] for group in report['proposalGroups'])
    return {
        'status': report['status'],
        'mode': 'consolidation',
        'reportPath': report_path,
        'counts': {
            'sources': report['scanned']['sources'],
            'featureJournals': report['scanned']['featureJournals'],
            'candidates': report['scanned']['candidates'],
            'proposalGroups': len(report['proposalGroups']),
            'independentCandidates': len(report['independentCandidateIdentities']),
            'unresolvedCandidates': len(report['unresolvedCandidateIdentities']),
        },
        'groupCounts': dict(sorted(relationships.items())),
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
            current.mkdir(mode=0o700)
            metadata = current.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            fail('report directory boundary')
    try:
        metadata = target.lstat()
    except FileNotFoundError:
        pass
    else:
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            fail('report file boundary')
    fd, temporary = tempfile.mkstemp(prefix=f'.{target.name}.', dir=target.parent, text=True)
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
    validate.add_argument('--project-root', required=True)
    validate.add_argument('--expected-as-of')
    validate.add_argument('--expected-candidate-limit', type=int)
    compact_command = commands.add_parser('compact')
    compact_command.add_argument('report')
    compact_command.add_argument('--report-path', required=True)
    compact_command.add_argument('--project-root', required=True)
    compact_command.add_argument('--expected-as-of')
    compact_command.add_argument('--expected-candidate-limit', type=int)
    write = commands.add_parser('write')
    write.add_argument('--output', required=True)
    write.add_argument('--expected-as-of', required=True)
    write.add_argument('--expected-candidate-limit', required=True, type=int)
    write.add_argument('--project-root', required=True)
    write.add_argument('--stdin-line', action='store_true')
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == 'write':
            expected = ConsolidationRequest(
                as_of=timestamp(args.expected_as_of, 'expected asOf'),
                candidate_limit=integer(
                    args.expected_candidate_limit, 'expected candidateLimit', 1, 200
                ),
                project_root=Path(args.project_root),
            )
            if args.stdin_line and sys.stdin.isatty():
                import tty

                tty.setraw(sys.stdin.fileno())
            stream = io.StringIO(sys.stdin.readline()) if args.stdin_line else sys.stdin
            report = load_stream(stream, expected)
            write_report(report, args.output)
            print(dump(compact(report, args.output)))
            return 0
        raw_report = read_path(Path(args.report))
        if not isinstance(raw_report, dict):
            fail('report shape')
        raw_limits = raw_report.get('limits')
        inferred_limit = (
            raw_limits.get('candidateLimit') if isinstance(raw_limits, dict) else None
        )
        expected = ConsolidationRequest(
            as_of=timestamp(
                args.expected_as_of if args.expected_as_of is not None else raw_report.get('asOf'),
                'expected asOf',
            ),
            candidate_limit=integer(
                args.expected_candidate_limit
                if args.expected_candidate_limit is not None
                else inferred_limit,
                'expected candidateLimit',
                1,
                200,
            ),
            project_root=Path(args.project_root),
        )
        report = validate_report(raw_report, expected)
        if args.command == 'compact':
            print(dump(compact(report, args.report_path)))
        else:
            print(dump(report))
        return 0
    except ReportError as exc:
        print(f'Invalid Wiki maintenance consolidation report: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
