#!/bin/bash
set -euo pipefail
umask 077
unset BASH_ENV ENV CDPATH
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

fail() {
  printf '  FAIL  %s\n' "$*"
  findings=$((findings + 1))
}

validate_regular() {
  local path="$1" name="$2" mode="$3"
  if [ ! -f "$path" ] || [ -L "$path" ]; then
    fail "$name is not a physical regular file"
    return
  fi
  [ "$(stat -f '%u' "$path")" = "$(id -u)" ] || fail "$name has the wrong owner"
  [ "$(stat -f '%Lp' "$path")" = "$mode" ] || fail "$name has the wrong mode"
  [ "$(stat -f '%l' "$path")" = 1 ] || fail "$name has multiple links"
}

validate_latest() {
  local path="$1"
  if ! /usr/bin/python3 -I - "$path" <<'PY'
import json
import os
import re
import stat
import sys
import unicodedata
import uuid
from datetime import datetime

path = sys.argv[1]
descriptor = os.open(
    path,
    os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
)
try:
    before = os.fstat(descriptor)
    assert stat.S_ISREG(before.st_mode)
    assert before.st_uid == os.geteuid()
    assert before.st_nlink == 1
    assert stat.S_IMODE(before.st_mode) == 0o600
    data = b""
    while len(data) <= 4_194_304:
        block = os.read(
            descriptor,
            min(65_536, 4_194_305 - len(data)),
        )
        if not block:
            break
        data += block
    after = os.fstat(descriptor)
    named = os.lstat(path)
finally:
    os.close(descriptor)
identity = lambda value: (
    value.st_dev, value.st_ino, value.st_uid, value.st_mode,
    value.st_nlink, value.st_size, value.st_mtime_ns,
    value.st_ctime_ns,
)
assert identity(before) == identity(after) == identity(named)
assert len(data) <= 4_194_304
if not data:
    raise SystemExit(0)
assert data.endswith(b"\n")
lines = [line for line in data.splitlines() if line]
assert lines
records = []
for line in lines:
    assert len(line) <= 1_048_576
    value = json.loads(line)
    assert isinstance(value, dict)
    records.append(value)
schema = records[0].get("schema")
assert schema in {
    "shadow-sync-log/v1",
    "shadow-sync-log/v2",
}
if schema == "shadow-sync-log/v1":
    assert len(data) <= 1_048_576
run = records[0].get("run")
assert isinstance(run, str) and str(uuid.UUID(run)) == run
common = {"schema", "run", "sequence", "timestamp", "type"}
v1_payload = {"event", "report", "intent", "checkpoint", "data"}
repository_keys = {
    "id", "displayName", "path", "rawOrigin", "originIdentity",
    "presentationLocation", "rootIdentity", "gitDirectoryIdentity",
    "commonDirectoryIdentity", "configIdentity",
    "policyAdmissionSHA256", "hookAdmissionSHA256",
    "linkedWorktreePaths", "linkedWorktrees", "cachedMainRelation",
    "blockedReason",
}
result_keys = {
    "repository", "operationID", "defaultBranch", "code",
    "resultClass", "fetched", "mainUpdated", "beforeCommit",
    "targetCommit", "afterCommit", "remoteTrackingBeforeCommit",
    "remoteTrackingAfterCommit", "startedAt", "endedAt",
    "durationMilliseconds", "explanation", "technicalDetail",
    "failureReason",
}
report_keys = {
    "schema", "run", "startedAt", "endedAt", "durationMilliseconds",
    "cancelled", "cancellationState", "results", "summaryOverride",
    "repositoryModel",
}
oid = re.compile(r"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$")

def timestamp(value):
    assert isinstance(value, str) and len(value) <= 64
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    assert parsed.tzinfo is not None
    return parsed

def technical_detail(value):
    assert isinstance(value, str) and value
    assert len(value.encode("utf-8")) <= 2_048
    canonical = value
    redactions = (
        (
            r"-----BEGIN [^-\r\n]*PRIVATE KEY-----.*?"
            r"-----END [^-\r\n]*PRIVATE KEY-----",
            "[REDACTED PRIVATE KEY]",
            re.IGNORECASE | re.DOTALL,
        ),
        (
            r"(authorization\s*[:=]\s*)(?:bearer\s+)?[^\s,\r\n]+",
            r"\g<1>[REDACTED]",
            re.IGNORECASE,
        ),
        (
            r"(\bbearer\s+)[A-Za-z0-9._~+/\-=]{8,}",
            r"\g<1>[REDACTED]",
            re.IGNORECASE,
        ),
        (
            r"((?:credentials?|api[_-]?key|access[_-]?token|"
            r"refresh[_-]?token|client[_-]?secret|private[_-]?key|"
            r"pat|token|password|passwd|secret)\s*[=:]\s*[\"']?)"
            r"[^\s\"'&,\r\n]+",
            r"\g<1>[REDACTED]",
            re.IGNORECASE,
        ),
        (
            r"([?&](?:credentials?|api[_-]?key|access[_-]?token|"
            r"pat|token|key)=)[^&\s]+",
            r"\g<1>[REDACTED]",
            re.IGNORECASE,
        ),
        (
            r"([a-z][a-z0-9+.-]*://)[^/@\s]+@",
            r"\g<1>[REDACTED]@",
            re.IGNORECASE,
        ),
        (
            r"(x-access-token:)[^@\s]+",
            r"\g<1>[REDACTED]",
            re.IGNORECASE,
        ),
        (
            r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|"
            r"github_pat_[A-Za-z0-9_]{20,}|"
            r"glpat-[A-Za-z0-9_-]{20,}|"
            r"sk-[A-Za-z0-9_-]{20,}|AKIA[A-Z0-9]{16})\b",
            "[REDACTED TOKEN]",
            0,
        ),
    )
    for pattern, replacement, flags in redactions:
        canonical = re.sub(
            pattern,
            replacement,
            canonical,
            flags=flags,
        )
    canonical = re.sub(
        r"\b[a-z][a-z0-9+.-]*://[^\s]+",
        "[REDACTED URL]",
        canonical,
        flags=re.IGNORECASE,
    )
    canonical = re.sub(
        r"(?<![A-Za-z0-9_.-])/(?:[^\s/]+/)*[^\s,;:)\]}]*",
        "[REDACTED PATH]",
        canonical,
    )
    canonical = re.sub(
        r"\b([A-Z_][A-Z0-9_]{1,63})=[^\s,;]+",
        r"\g<1>=[REDACTED]",
        canonical,
    ).strip()
    assert canonical == value

def repository(value):
    assert isinstance(value, dict)
    assert set(value).issubset(repository_keys)
    assert isinstance(value.get("id"), str)
    identity = re.fullmatch(
        r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
        value["id"],
    )
    assert identity
    owner, name = value["id"].split("/")
    assert owner not in {".", ".."} and name not in {".", ".."}
    assert isinstance(value.get("path"), str) and value["path"].startswith("/")
    raw_origin = value.get("rawOrigin")
    assert isinstance(raw_origin, str)
    origin = None
    for pattern in (
        r"git@github[.]com:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:[.]git)?",
        r"ssh://git@github[.]com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:[.]git)?",
        r"https://github[.]com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:[.]git)?/?",
    ):
        match = re.fullmatch(pattern, raw_origin)
        if match:
            assert match.group(1) not in {".", ".."}
            assert match.group(2) not in {".", ".."}
            origin = (
                match.group(1).lower()
                + "/"
                + match.group(2).lower()
            )
            break
    display = value.get("displayName")
    assert isinstance(display, str)
    local = display.strip()
    safe_local = (
        bool(local)
        and local not in {".", ".."}
        and len(local.encode("utf-8")) <= 255
        and "/" not in local
        and "\\" not in local
        and "%2f" not in local.lower()
        and "%5c" not in local.lower()
        and all(unicodedata.category(character) != "Cc" for character in local)
    )
    historical = (
        origin is not None
        and value["id"].lower() == origin
        and display == origin
        and len(origin.split("/")) == 2
    )
    assert safe_local or historical

def result(value):
    assert isinstance(value, dict)
    assert set(value).issubset(result_keys)
    repository(value.get("repository"))
    assert isinstance(value.get("code"), str)
    assert isinstance(value.get("resultClass"), str)
    assert type(value.get("fetched")) is bool
    assert type(value.get("mainUpdated")) is bool
    assert type(value.get("durationMilliseconds")) is int
    assert value["durationMilliseconds"] >= 0
    timestamp(value.get("startedAt"))
    timestamp(value.get("endedAt"))
    assert isinstance(value.get("explanation"), str) and value["explanation"]
    for key in (
        "beforeCommit", "targetCommit", "afterCommit",
        "remoteTrackingBeforeCommit", "remoteTrackingAfterCommit",
    ):
        assert value.get(key) is None or oid.fullmatch(value[key])

terminal_statuses = {
    "succeeded", "skipped", "refused", "failed", "cancelled",
}
all_statuses = terminal_statuses | {"queued", "running"}
node_kinds = {
    "repair", "reinspection", "fastForward", "retention",
    "groupedRemovalConfirmation", "worktreeRemoval",
    "claimReinspection", "branchRemoval",
    "residueVerification", "policyInvalidation",
}

def v2_plan(value):
    assert isinstance(value, dict)
    assert set(value) == {
        "schema", "run", "createdAt", "policyEvidenceDigest", "nodes",
    }
    assert value.get("schema") == "shadow-sync-batch-plan/v2"
    assert value.get("run") == run
    timestamp(value.get("createdAt"))
    assert (
        isinstance(value.get("policyEvidenceDigest"), str)
        and value["policyEvidenceDigest"]
    )
    nodes = value.get("nodes")
    assert isinstance(nodes, list) and nodes
    by_id = {}
    for node in nodes:
        assert isinstance(node, dict)
        assert {
            "id", "kind", "dependencies", "payload",
            "requiresExclusiveWorkerPool",
        }.issubset(node)
        assert set(node).issubset({
            "id", "repositoryID", "commonDirectoryKey", "kind",
            "dependencies", "payload", "requiresExclusiveWorkerPool",
        })
        assert (
            isinstance(node.get("id"), str)
            and node["id"].startswith("body3-node:")
            and node["id"] not in by_id
        )
        assert node.get("kind") in node_kinds
        assert isinstance(node.get("payload"), dict) and len(node["payload"]) == 1
        payload_key = next(iter(node["payload"]))
        expected_payload = {
            "repair": "operation",
            "fastForward": "operation",
            "reinspection": "reinspection",
            "claimReinspection": "reinspection",
            "retention": "retention",
            "groupedRemovalConfirmation": "confirmation",
            "worktreeRemoval": "removal",
            "branchRemoval": "removal",
            "residueVerification": "residue",
            "policyInvalidation": "policyInvalidation",
        }[node["kind"]]
        assert payload_key == expected_payload
        assert type(node.get("requiresExclusiveWorkerPool")) is bool
        if node["kind"] == "groupedRemovalConfirmation":
            assert node.get("repositoryID") is None
            assert node.get("commonDirectoryKey") is None
            assert node["requiresExclusiveWorkerPool"]
        elif node["kind"] == "policyInvalidation":
            assert isinstance(node.get("repositoryID"), str)
            assert isinstance(node.get("commonDirectoryKey"), str)
            assert node["requiresExclusiveWorkerPool"]
        else:
            assert isinstance(node.get("repositoryID"), str)
            assert isinstance(node.get("commonDirectoryKey"), str)
        dependencies = node.get("dependencies")
        assert isinstance(dependencies, list)
        dependency_ids = []
        for dependency in dependencies:
            assert (
                isinstance(dependency, dict)
                and set(dependency) == {"nodeID", "requiresSuccess"}
                and isinstance(dependency.get("nodeID"), str)
                and type(dependency.get("requiresSuccess")) is bool
            )
            dependency_ids.append(dependency["nodeID"])
        assert (
            len(dependency_ids) == len(set(dependency_ids))
            and node["id"] not in dependency_ids
        )
        by_id[node["id"]] = node
    assert all(
        dependency["nodeID"] in by_id
        for node in nodes
        for dependency in node["dependencies"]
    )
    remaining = {
        node["id"]: {
            dependency["nodeID"]
            for dependency in node["dependencies"]
        }
        for node in nodes
    }
    admitted = set()
    while remaining:
        ready = next(
            (node for node, dependencies in remaining.items()
             if dependencies.issubset(admitted)),
            None,
        )
        assert ready is not None
        admitted.add(ready)
        del remaining[ready]
    return by_id

v2_allowed = common | {
    "repository", "operation", "target", "kind", "phase",
    "worker", "recommendation", "selection", "awa",
    "retention", "artifact", "restore", "exclusions",
    "executable", "arguments", "force", "outcome", "status",
    "residue", "recovery", "detail", "technicalDetail",
    "durationMilliseconds",
    "plan", "report",
}
saw_legacy = False
saw_v2 = False
saw_intent = False
terminal_report = None
saw_worker_exit = False
saw_final_event = False
v2_nodes = None
v2_states = {}
v2_saw_report = False

def report_summary(report):
    override = report.get("summaryOverride")
    if override is not None:
        assert isinstance(override, str)
        return override
    results = report["results"]
    if report["cancelled"]:
        completed = sum(
            item["resultClass"] != "cancelled" for item in results
        )
        incomplete = sum(
            item["resultClass"] == "cancelled" for item in results
        )
        return (
            f"Run cancelled — {completed} repositories completed before "
            f"cancellation; {incomplete} were not run. Completed updates "
            "were kept."
        )
    issue_count = sum(
        item["resultClass"] in {"warning", "failure"} for item in results
    )
    updated = sum(item["mainUpdated"] for item in results)
    if issue_count:
        skipped = sum(
            item["resultClass"] == "warning" and not item["mainUpdated"]
            for item in results
        )
        failed = sum(
            item["resultClass"] == "failure" for item in results
        )
        return (
            f"Run complete with issues — {updated} updated, {skipped} "
            f"skipped, {failed} failed. Completed updates were kept."
        )
    current = sum(
        item["code"] == "ALREADY_CURRENT" for item in results
    )
    return f"Run complete — {updated} updated, {current} already current."

for sequence, record in enumerate(records, 1):
    assert record.get("schema") == schema
    assert record.get("run") == run
    assert type(record.get("sequence")) is int
    assert record.get("sequence") == sequence
    timestamp(record.get("timestamp"))
    if schema == "shadow-sync-log/v2":
        assert set(record).issubset(v2_allowed)
        for key in (
            "repository", "operation", "target", "kind", "phase",
            "recommendation", "selection", "awa", "retention",
            "artifact", "restore", "executable", "force", "outcome",
            "residue", "recovery", "detail",
        ):
            assert record.get(key) is None or isinstance(record[key], str)
        assert (
            record.get("worker") is None
            or type(record["worker"]) is int
            and 1 <= record["worker"] <= 2
        )
        assert (
            record.get("durationMilliseconds") is None
            or type(record["durationMilliseconds"]) is int
            and record["durationMilliseconds"] >= 0
        )
        if record.get("technicalDetail") is not None:
            technical_detail(record["technicalDetail"])
        assert (
            record.get("exclusions") is None
            or isinstance(record["exclusions"], list)
            and all(isinstance(item, str) for item in record["exclusions"])
        )
        assert (
            record.get("arguments") is None
            or isinstance(record["arguments"], list)
            and all(isinstance(item, str) for item in record["arguments"])
        )
        if sequence == 1:
            assert record.get("type") == "plan"
            assert record.get("operation") is None
            assert record.get("status") is None
            v2_nodes = v2_plan(record.get("plan"))
        else:
            assert record.get("plan") is None
            assert v2_nodes is not None
        operation = record.get("operation")
        status = record.get("status")
        if operation is not None:
            assert operation in v2_nodes
        if status is not None:
            assert operation is not None and status in all_statuses
            previous = v2_states.get(operation)
            assert previous not in terminal_statuses
            assert (
                previous is not None
                or status in {"running", "cancelled"}
            )
            v2_states[operation] = status
        report = record.get("report")
        if report is not None:
            assert not v2_saw_report
            assert record.get("type") == "run_finished"
            assert isinstance(report, dict)
            assert set(report) == {
                "schema", "run", "startedAt", "endedAt", "cancelled",
                "paused", "results", "repositoryCounts",
            }
            assert report.get("schema") == "shadow-sync-batch-report/v2"
            assert report.get("run") == run
            report_started = timestamp(report.get("startedAt"))
            report_ended = timestamp(report.get("endedAt"))
            assert report_ended >= report_started
            assert type(report.get("cancelled")) is bool
            assert type(report.get("paused")) is bool
            results = report.get("results")
            assert isinstance(results, list)
            assert len(results) == len(v2_nodes)
            result_ids = []
            expected_counts = {}
            for item in results:
                assert isinstance(item, dict)
                assert {
                    "node", "status", "endedAt",
                    "durationMilliseconds", "detail",
                }.issubset(item)
                assert set(item).issubset({
                    "node", "status", "worker", "startedAt",
                    "endedAt", "durationMilliseconds", "detail",
                    "technicalDetail",
                })
                node = item.get("node")
                assert isinstance(node, dict)
                node_id = node.get("id")
                assert node_id in v2_nodes and node == v2_nodes[node_id]
                result_ids.append(node_id)
                assert item.get("status") in terminal_statuses
                assert (
                    v2_states.get(node_id) is None
                    or v2_states[node_id] == item["status"]
                )
                assert (
                    item.get("worker") is None
                    or type(item["worker"]) is int
                    and 1 <= item["worker"] <= 2
                )
                result_ended = timestamp(item.get("endedAt"))
                assert report_started <= result_ended <= report_ended
                if item.get("startedAt") is not None:
                    result_started = timestamp(item["startedAt"])
                    assert report_started <= result_started <= result_ended
                assert (
                    type(item.get("durationMilliseconds")) is int
                    and item["durationMilliseconds"] >= 0
                )
                assert isinstance(item.get("detail"), str)
                if item.get("technicalDetail") is not None:
                    technical_detail(item["technicalDetail"])
                repository_id = node.get("repositoryID")
                if repository_id is not None:
                    expected_counts[repository_id] = (
                        expected_counts.get(repository_id, 0) + 1
                    )
            assert len(result_ids) == len(set(result_ids))
            counts = report.get("repositoryCounts")
            assert isinstance(counts, dict)
            assert all(
                isinstance(key, str)
                and type(value) is int
                and value >= 0
                for key, value in counts.items()
            )
            assert counts == expected_counts
            v2_saw_report = True
        else:
            assert not v2_saw_report
        continue
    assert set(record).issubset(common | v1_payload)
    present = [
        key for key in v1_payload
        if key in record and record[key] is not None
    ]
    expected = {
        "run_intent": "intent",
        "event": "event",
        "repository_checkpoint": "checkpoint",
        "run_finished": "report",
        "control": "data",
        "worker_exit": "data",
        "subprocess": "data",
    }.get(record.get("type"))
    assert expected is not None and present == [expected]
    if terminal_report is not None and not saw_worker_exit:
        assert record.get("type") == "worker_exit"
        saw_worker_exit = True
    elif terminal_report is not None and not saw_final_event:
        event = record.get("event")
        assert record.get("type") == "event"
        assert isinstance(event, dict)
        assert event.get("type") == "run_finished"
        assert event.get("run") == run
        assert event.get("repositoryID") is None
        assert event.get("phase") is None
        assert event.get("result") is None
        assert event.get("message") == report_summary(terminal_report)
        saw_final_event = True
    elif terminal_report is not None:
        assert False
    else:
        assert record.get("type") != "worker_exit"
        event = record.get("event")
        assert not (
            isinstance(event, dict)
            and event.get("type") == "run_finished"
        )
    payload = record.get(expected)
    if expected == "intent":
        assert not saw_intent and terminal_report is None
        saw_intent = True
        assert isinstance(payload, dict)
        assert set(payload).issubset({
            "run", "startedAt", "candidates", "repositoryModel",
        })
        assert payload.get("run") == run
        timestamp(payload.get("startedAt"))
        candidates = payload.get("candidates")
        assert isinstance(candidates, list) and candidates
        for candidate in candidates:
            repository(candidate)
    elif expected == "event":
        assert isinstance(payload, dict)
        assert set(payload).issubset({
            "schema", "run", "sequence", "timestamp", "type",
            "repositoryID", "phase", "result", "message",
        })
        assert payload.get("schema") == "shadow-sync-event/v1"
        assert payload.get("run") == run
        assert type(payload.get("sequence")) is int
        assert payload["sequence"] > 0
        timestamp(payload.get("timestamp"))
        if payload.get("result") is not None:
            result(payload["result"])
    elif expected == "checkpoint":
        assert isinstance(payload, dict)
        assert set(payload).issubset({
            "repository", "startedAt", "beforeCommit",
            "targetCommit", "fetched",
        })
        repository(payload.get("repository"))
        timestamp(payload.get("startedAt"))
        assert type(payload.get("fetched")) is bool
        for key in ("beforeCommit", "targetCommit"):
            assert payload.get(key) is None or oid.fullmatch(payload[key])
    elif expected == "report":
        assert terminal_report is None
        assert isinstance(payload, dict)
        assert set(payload).issubset(report_keys)
        assert payload.get("schema") == "shadow-sync-report/v1"
        assert payload.get("run") == run
        timestamp(payload.get("startedAt"))
        timestamp(payload.get("endedAt"))
        assert type(payload.get("durationMilliseconds")) is int
        assert payload["durationMilliseconds"] >= 0
        assert type(payload.get("cancelled")) is bool
        expected_cancellation = (
            "cancelled" if payload["cancelled"] else "not_cancelled"
        )
        assert payload.get("cancellationState") == expected_cancellation
        assert isinstance(payload.get("results"), list)
        for item in payload["results"]:
            result(item)
        terminal_report = payload
    else:
        assert isinstance(payload, str) and payload
    if expected in {"intent", "report"}:
        assert isinstance(payload, dict)
        observed = payload.get("repositoryModel")
        if "repositoryModel" in payload:
            assert observed == "v2"
            saw_v2 = True
        else:
            saw_legacy = True
        assert not (saw_legacy and saw_v2)
if schema == "shadow-sync-log/v2":
    assert v2_nodes is not None
PY
  then
    fail "latest.log content is malformed, partial, or incompatible"
  fi
}

validate_retention() {
  local path="$1"
  if [ ! -d "$path" ] || [ -L "$path" ]; then
    fail "retention is not a physical directory"
    return
  fi
  [ "$(stat -f '%u' "$path")" = "$(id -u)" ] || fail "retention has the wrong owner"
  [ "$(stat -f '%Lp' "$path")" = 700 ] || fail "retention has the wrong mode"
  if ! /usr/bin/python3 -I - "$path" "$(id -u)" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys

root, expected_uid = sys.argv[1], int(sys.argv[2])
sha = re.compile(r"^[0-9a-f]{64}$")
artifact = re.compile(r"^ret-[a-z0-9-]{4,76}$")
oid = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
shared = re.compile(r"^sharedindex\.(?:[0-9a-f]{40}|[0-9a-f]{64})$")

def safe_relative(value):
    return (
        isinstance(value, str)
        and value
        and not value.startswith("/")
        and "\0" not in value
        and all(part not in ("", ".", "..") for part in value.split("/"))
    )

def directory(path, mode=0o700):
    value = os.lstat(path)
    assert stat.S_ISDIR(value.st_mode)
    assert not stat.S_ISLNK(value.st_mode)
    assert value.st_uid == expected_uid
    assert stat.S_IMODE(value.st_mode) == mode

def protected_file(path, maximum):
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    try:
        value = os.fstat(descriptor)
        assert stat.S_ISREG(value.st_mode)
        assert value.st_uid == expected_uid
        assert value.st_nlink == 1
        assert stat.S_IMODE(value.st_mode) == 0o400
        assert 0 <= value.st_size <= maximum
        data = b""
        while len(data) <= maximum:
            block = os.read(
                descriptor,
                min(65_536, maximum + 1 - len(data)),
            )
            if not block:
                break
            data += block
        opened_after = os.fstat(descriptor)
        named_after = os.lstat(path)
    finally:
        os.close(descriptor)
    assert len(data) <= maximum
    assert (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    ) == (
        opened_after.st_dev,
        opened_after.st_ino,
        opened_after.st_mode,
        opened_after.st_nlink,
        opened_after.st_size,
        opened_after.st_mtime_ns,
        opened_after.st_ctime_ns,
    ) == (
        named_after.st_dev,
        named_after.st_ino,
        named_after.st_mode,
        named_after.st_nlink,
        named_after.st_size,
        named_after.st_mtime_ns,
        named_after.st_ctime_ns,
    )
    return data

directory(root)
names = sorted(os.listdir(root))
assert len(names) <= 10_000
assert not any(name.startswith(".incomplete-") for name in names)
assert all(artifact.fullmatch(name) for name in names)
for name in names:
    path = os.path.join(root, name)
    directory(path)
    manifest_bytes = protected_file(
        os.path.join(path, "manifest.json"), 4_194_304
    )
    manifest = json.loads(manifest_bytes)
    required_manifest = {
        "schema", "artifactID", "repositoryID", "cloneID",
        "commonDirectoryIdentity", "objectFormat", "entries",
        "sharedIndexFiles", "includedPaths", "excludedPaths",
        "secretShapedPaths", "possibleSecretsAuthorized",
        "createdAt", "componentSHA256", "restoreProof",
        "restoreInstructions",
    }
    optional_manifest = {
        "worktreeID", "worktreeRootIdentity", "registrationIdentity",
        "branchRef", "tipOID", "indexSHA256", "statusSHA256",
    }
    assert required_manifest.issubset(manifest)
    assert set(manifest).issubset(required_manifest | optional_manifest)
    assert manifest.get("schema") == "shadow-sync-retention/v2"
    assert manifest.get("artifactID") == name
    assert isinstance(manifest.get("repositoryID"), str)
    assert re.fullmatch(
        r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
        manifest["repositoryID"],
    )
    assert isinstance(manifest.get("cloneID"), str)
    assert manifest["cloneID"].startswith("clone:")
    for key in (
        "commonDirectoryIdentity",
        "worktreeRootIdentity",
        "registrationIdentity",
    ):
        identity = manifest.get(key)
        if key == "commonDirectoryIdentity" or identity is not None:
            assert isinstance(identity, dict)
            assert set(identity) == {"device", "inode"}
            assert all(
                type(item) is int and item >= 0
                for item in identity.values()
            )
    assert manifest.get("objectFormat") in ("sha1", "sha256")
    tip = manifest.get("tipOID")
    assert tip is None or oid.fullmatch(tip)
    assert manifest.get("possibleSecretsAuthorized") is True
    assert manifest.get("excludedPaths") == []
    instructions = manifest.get("restoreInstructions")
    assert isinstance(instructions, list) and instructions
    proof = manifest.get("restoreProof")
    assert isinstance(proof, dict)
    assert {
        "verifiedAt", "bundleVerified", "connectivityVerified",
        "entryManifestVerified", "indexVerified",
        "statusDigestVerified",
    }.issubset(proof)
    assert set(proof).issubset({
        "verifiedAt", "exactTipOID", "bundleVerified",
        "connectivityVerified", "entryManifestVerified",
        "indexVerified", "statusDigestVerified",
    })
    assert proof.get("entryManifestVerified") is True
    assert proof.get("indexVerified") is True
    assert proof.get("statusDigestVerified") is True
    assert proof.get("exactTipOID") == tip
    if tip is not None:
        assert proof.get("bundleVerified") is True
        assert proof.get("connectivityVerified") is True

    entries = manifest.get("entries")
    assert isinstance(entries, list)
    entry_paths = [entry.get("path") for entry in entries]
    assert entry_paths == sorted(entry_paths)
    assert len(entry_paths) == len(set(entry_paths))
    for entry in entries:
        assert {"path", "kind", "mode", "size"}.issubset(entry)
        assert set(entry).issubset({
            "path", "kind", "mode", "size",
            "symlinkTarget", "contentSHA256",
        })
        assert safe_relative(entry.get("path"))
        assert entry.get("kind") in ("directory", "regular", "symbolicLink")
        assert isinstance(entry.get("mode"), int)
        assert 0 <= entry["mode"] <= 0o7777
        content_hash = entry.get("contentSHA256")
        target = entry.get("symlinkTarget")
        assert (entry["kind"] == "regular") == (
            isinstance(content_hash, str) and bool(sha.fullmatch(content_hash))
        )
        assert (entry["kind"] == "symbolicLink") == isinstance(target, str)

    for key in ("includedPaths", "secretShapedPaths"):
        values = manifest.get(key)
        assert isinstance(values, list)
        assert values == sorted(set(values))
        assert all(safe_relative(value) for value in values)

    components = manifest.get("componentSHA256")
    shared_files = manifest.get("sharedIndexFiles")
    assert isinstance(components, dict)
    assert set(components).issubset(
        {"branch.bundle", "worktree.tar", "index.snapshot"}
    )
    assert all(sha.fullmatch(value) for value in components.values())
    assert isinstance(shared_files, dict)
    assert all(shared.fullmatch(key) for key in shared_files)
    assert all(sha.fullmatch(value) for value in shared_files.values())
    expected = {"manifest.json", *components}
    assert set(os.listdir(path)) == expected

    for component, expected_hash in components.items():
        component_path = os.path.join(path, component)
        if component == "index.snapshot":
            directory(component_path)
            expected_index_entries = {"index", *shared_files}
            assert set(os.listdir(component_path)) == expected_index_entries
            index_hash = hashlib.sha256(
                protected_file(
                    os.path.join(component_path, "index"), 67_108_864
                )
            ).hexdigest()
            fields = [index_hash]
            for shared_name in sorted(shared_files):
                observed = hashlib.sha256(
                    protected_file(
                        os.path.join(component_path, shared_name),
                        67_108_864,
                    )
                ).hexdigest()
                assert observed == shared_files[shared_name]
                fields.append(f"{shared_name}:{observed}")
            observed = hashlib.sha256("\n".join(fields).encode()).hexdigest()
        else:
            observed = hashlib.sha256(
                protected_file(component_path, 1_073_741_824)
            ).hexdigest()
        assert observed == expected_hash

    if manifest.get("worktreeID") is not None:
        assert {"worktree.tar", "index.snapshot"}.issubset(components)
        assert sha.fullmatch(manifest.get("indexSHA256", ""))
        assert sha.fullmatch(manifest.get("statusSHA256", ""))
        assert set(entry_paths) == set(manifest["includedPaths"])
    else:
        assert isinstance(manifest.get("branchRef"), str)
        assert manifest["branchRef"].startswith("refs/heads/")
        assert "worktree.tar" not in components
        assert "index.snapshot" not in components
        assert entries == []
        assert manifest.get("indexSHA256") is None
        assert manifest.get("statusSHA256") is None
        assert shared_files == {}
PY
  then
    fail "retention artifacts are malformed, incomplete, or incompatible"
  fi
}

[ "$#" -eq 4 ] && [ "$1" = "--home" ] && [ "$3" = "--launchctl" ] || {
  printf 'source-doctor: usage: source-doctor.sh --home ABSOLUTE_HOME --launchctl ABSOLUTE_COMMAND\n' >&2
  exit 2
}
home="$2"
launchctl="$4"
case "$home" in /private/tmp/*/home) ;; *) printf 'source-doctor: isolated fixture home required\n' >&2; exit 64 ;; esac
fixture_root="${home%/home}"
[ "$launchctl" = "$fixture_root/launchctl-stub" ] || {
  printf 'source-doctor: fixture launchctl stub required\n' >&2
  exit 64
}
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
/usr/bin/python3 -I "$SRC/scripts/verify-fixture-root.py" "$fixture_root" --doctor-absent >/dev/null

app="$home/Applications/ShadowSync.app"
predecessor_app="$home/Applications/Dev Main Sync.app"
plist="$home/Library/LaunchAgents/com.kleinperkins.shadow-sync.plist"
state="$home/.local/state/shadow-sync"
findings=0

if [ -e "$app" ] || [ -L "$app" ] \
  || [ -e "$predecessor_app" ] || [ -L "$predecessor_app" ]; then
  printf 'source-doctor: installed candidate requires source-attested bundle verification\n'
  exit 3
fi
printf '  OK    app is absent\n'

for slot in \
  "$home/Applications/.ShadowSync.app.incoming" \
  "$home/Applications/.ShadowSync.app.previous" \
  "$home/Applications/.ShadowSync.app.predecessor.previous" \
  "$home/Applications/.Dev Main Sync.app.incoming" \
  "$home/Applications/.Dev Main Sync.app.previous" \
  "$home/Library/LaunchAgents/.com.kleinperkins.shadow-sync.plist.incoming" \
  "$home/Library/LaunchAgents/.com.kleinperkins.shadow-sync.plist.previous"; do
  if [ -e "$slot" ] || [ -L "$slot" ]; then
    fail "transaction slot is present: $slot"
  fi
done
for parent in "$home/Applications" "$home/Library/LaunchAgents"; do
  [ -d "$parent" ] && [ ! -L "$parent" ] || continue
  while IFS= read -r name; do
    case "$name" in
      ".ShadowSync.app.incoming"|".ShadowSync.app.previous"|".ShadowSync.app.predecessor.previous"|".Dev Main Sync.app.incoming"|".Dev Main Sync.app.previous"|".com.kleinperkins.shadow-sync.plist.incoming"|".com.kleinperkins.shadow-sync.plist.previous") ;;
      .ShadowSync.app.*|.Dev\ Main\ Sync.app.*|.com.kleinperkins.shadow-sync.plist.*)
        fail "unknown transaction entry is present: $parent/$name"
        ;;
    esac
  done < <(/bin/ls -A "$parent")
done

if [ -e "$plist" ] || [ -L "$plist" ]; then
  fail "LaunchAgent plist remains while the app is absent"
else
  printf '  OK    LaunchAgent plist is absent\n'
fi

set +e
launch_output="$("$launchctl" print "gui/$(id -u)/com.kleinperkins.shadow-sync" 2>&1)"
launch_status=$?
set -e
if [ "$launch_status" -eq 0 ]; then
  launch_program="$(printf '%s\n' "$launch_output" | awk -F' = ' '/^[[:space:]]*program = / {print $2; exit}')"
  launch_pid="$(printf '%s\n' "$launch_output" | awk -F' = ' '/^[[:space:]]*pid = / {print $2; exit}')"
  fail "launchd label remains loaded while the app is absent (program=${launch_program:-unknown}, pid=${launch_pid:-unknown}); readiness was not queried without valid app authority"
elif printf '%s\n' "$launch_output" \
    | grep -Eiq 'could not find service|service not found'; then
  printf '  OK    launchd label is absent\n'
else
  fail "launchd state could not be classified (status $launch_status)"
fi

if [ ! -e "$state" ] && [ ! -L "$state" ]; then
  if [ "$findings" -eq 0 ]; then
    printf 'ShadowSync doctor OK: product is absent with no residue.\n'
    exit 0
  fi
  printf 'ShadowSync doctor found %d unsafe condition(s).\n' "$findings"
  exit 1
fi
if [ ! -d "$state" ] || [ -L "$state" ]; then
  fail "state path is not a physical directory"
  printf 'ShadowSync doctor found %d unsafe condition(s).\n' "$findings"
  exit 1
fi
[ "$(stat -f '%u' "$state")" = "$(id -u)" ] || fail "state directory has the wrong owner"
[ $((8#$(stat -f '%Lp' "$state") & 077)) -eq 0 ] || fail "state directory is not private"

entries=()
while IFS= read -r entry; do
  [ -n "$entry" ] && entries+=("$entry")
done < <(/bin/ls -A "$state")
for entry in "${entries[@]}"; do
  case "$entry" in
    latest.log|repository-authorities.json|selection-preferences.json|selection-preferences.recovery|retention|host-owner.json|host.sock|launcher.lock|lifecycle.lock|operation.lock|run.lock) ;;
    *) fail "unknown state entry is present: $entry" ;;
  esac
done

if [ -e "$state/latest.log" ] || [ -L "$state/latest.log" ]; then
  validate_regular "$state/latest.log" latest.log 600
  validate_latest "$state/latest.log"
else
  fail "state directory is missing latest.log"
fi

if [ -e "$state/repository-authorities.json" ] || [ -L "$state/repository-authorities.json" ]; then
  validate_regular "$state/repository-authorities.json" repository-authorities.json 600
  if ! /usr/bin/python3 -I - "$state/repository-authorities.json" <<'PY'
import json
import os
import re
import stat
import sys

path = sys.argv[1]
descriptor = os.open(
    path,
    os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
)
try:
    before = os.fstat(descriptor)
    assert stat.S_ISREG(before.st_mode)
    assert before.st_uid == os.geteuid()
    assert before.st_nlink == 1
    assert stat.S_IMODE(before.st_mode) == 0o600
    assert 0 <= before.st_size <= 1_048_576
    data = b""
    while len(data) <= 1_048_576:
        block = os.read(
            descriptor,
            min(65_536, 1_048_577 - len(data)),
        )
        if not block:
            break
        data += block
    after = os.fstat(descriptor)
    named = os.lstat(path)
finally:
    os.close(descriptor)
identity = lambda item: (
    item.st_dev, item.st_ino, item.st_uid, item.st_mode,
    item.st_nlink, item.st_size, item.st_mtime_ns,
    item.st_ctime_ns,
)
assert identity(before) == identity(after) == identity(named)
assert len(data) <= 1_048_576
value = json.loads(data)
assert set(value) == {"schema", "revision", "records"}
assert value.get("schema") == "shadow-sync-repository-authorities/v1"
assert type(value.get("revision")) is int and value["revision"] >= 0
records = value.get("records")
assert isinstance(records, list)
for record in records:
    assert isinstance(record, dict)
    assert set(record) == {
        "repositoryID", "canonicalRoot", "rootIdentity",
        "commonDirectoryIdentity", "updatedAt",
    }
    assert isinstance(record["repositoryID"], str)
    assert record["repositoryID"] == record["repositoryID"].lower()
    assert re.fullmatch(
        r"[a-z0-9_.-]+/[a-z0-9_.-]+",
        record["repositoryID"],
    )
    assert (
        isinstance(record["canonicalRoot"], str)
        and record["canonicalRoot"].startswith("/")
    )
    assert isinstance(record["updatedAt"], str) and record["updatedAt"]
    for key in ("rootIdentity", "commonDirectoryIdentity"):
        identity = record[key]
        assert isinstance(identity, dict)
        assert set(identity) == {"device", "inode"}
        assert all(type(item) is int and item >= 0 for item in identity.values())
identities = [record.get("repositoryID") for record in records]
assert identities == sorted(identities)
assert len(identities) == len(set(identities))
PY
  then
    fail "repository-authorities.json is malformed"
  fi
fi

if [ -e "$state/selection-preferences.json" ] || [ -L "$state/selection-preferences.json" ]; then
  validate_regular "$state/selection-preferences.json" selection-preferences.json 600
  if ! /usr/bin/python3 -I - "$state/selection-preferences.json" <<'PY'
import json
import os
import re
import stat
import sys
import uuid

path = sys.argv[1]
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
try:
    before = os.fstat(fd)
    assert stat.S_ISREG(before.st_mode)
    assert before.st_uid == os.geteuid()
    assert before.st_nlink == 1
    assert stat.S_IMODE(before.st_mode) == 0o600
    assert 0 <= before.st_size <= 1_048_576
    data = os.read(fd, 1_048_577)
    after = os.fstat(fd)
    named = os.lstat(path)
finally:
    os.close(fd)
identity = lambda item: (
    item.st_dev, item.st_ino, item.st_uid, item.st_mode,
    item.st_nlink, item.st_size, item.st_mtime_ns,
    item.st_ctime_ns,
)
assert identity(before) == identity(after) == identity(named)
assert len(data) <= 1_048_576
value = json.loads(data)
assert set(value) == {"schema", "documentID", "revision", "entries"}
assert value["schema"] == "shadow-sync-repository-selection-preferences/v1"
assert str(uuid.UUID(value["documentID"])) == value["documentID"]
assert type(value["revision"]) is int and 0 < value["revision"] <= 2**64 - 1
entries = value["entries"]
assert isinstance(entries, list)
keys = []
for entry in entries:
    assert set(entry) == {"repositoryID", "locator"}
    repository_id = entry["repositoryID"]
    assert isinstance(repository_id, str) and repository_id == repository_id.lower()
    assert re.fullmatch(r"(?:[a-z0-9_.-]+/[a-z0-9_.-]+|local-[0-9a-f]{64})", repository_id)
    locator = entry["locator"]
    assert set(locator) == {"governedRoot", "components"}
    assert isinstance(locator["governedRoot"], str) and locator["governedRoot"]
    components = locator["components"]
    assert isinstance(components, list) and 0 < len(components) <= 4
    assert all(
        isinstance(item, str) and item and item not in (".", "..")
        and not item.startswith(".") and "/" not in item and "\\" not in item
        for item in components
    )
    keys.append((repository_id, locator["governedRoot"], tuple(components)))
assert keys == sorted(keys)
assert len({item[0] for item in keys}) == len(keys)
assert len({item[1:] for item in keys}) == len(keys)
PY
  then
    fail "selection-preferences.json is malformed"
  fi
fi

if [ -e "$state/selection-preferences.recovery" ] || [ -L "$state/selection-preferences.recovery" ]; then
  validate_regular "$state/selection-preferences.recovery" selection-preferences.recovery 600
  [ "$(stat -f '%z' "$state/selection-preferences.recovery")" -le 1048576 ] \
    || fail "selection-preferences.recovery is too large"
fi

if [ -e "$state/retention" ] || [ -L "$state/retention" ]; then
  validate_retention "$state/retention"
fi

owner_present=0
socket_present=0
if [ -e "$state/host-owner.json" ] || [ -L "$state/host-owner.json" ]; then
  owner_present=1
  validate_regular "$state/host-owner.json" host-owner.json 600
  fail "stale host owner remains while the app is absent"
fi
if [ -e "$state/host.sock" ] || [ -L "$state/host.sock" ]; then
  socket_present=1
  if [ -L "$state/host.sock" ] || [ ! -S "$state/host.sock" ]; then
    fail "host.sock is not a physical socket"
  else
    [ "$(stat -f '%u' "$state/host.sock")" = "$(id -u)" ] || fail "host.sock has the wrong owner"
    [ "$(stat -f '%Lp' "$state/host.sock")" = 600 ] || fail "host.sock has the wrong mode"
  fi
  fail "stale host socket remains while the app is absent"
fi
[ "$owner_present" -eq "$socket_present" ] || fail "host owner/socket presence is incoherent"

for lock in lifecycle.lock operation.lock run.lock launcher.lock; do
  if [ -e "$state/$lock" ] || [ -L "$state/$lock" ]; then
    validate_regular "$state/$lock" "$lock" 600
    fail "$lock remains while the app is absent"
  fi
done

if [ "$findings" -eq 0 ]; then
  printf 'ShadowSync doctor OK: verified removal; retained latest.log, canonical-root authority, and completed recovery artifacts when present.\n'
  exit 0
fi
printf 'ShadowSync doctor found %d unsafe condition(s).\n' "$findings"
exit 1
