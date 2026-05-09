#!/usr/bin/env python3
"""Apply kernel-vulnerability inspired rules to added patch lines.

Input TSV format:
  file<TAB>line<TAB>text

Output TSV format:
  severity<TAB>category<TAB>location<TAB>evidence<TAB>risk<TAB>action<TAB>rule_id<TAB>source<TAB>confidence
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


@dataclass
class AddedLine:
    file: str
    line: int
    text: str


def read_added_lines(path: Path) -> List[AddedLine]:
    lines: List[AddedLine] = []
    with path.open("r", encoding="utf-8", errors="replace") as f:
        for raw in f:
            raw = raw.rstrip("\n")
            if not raw:
                continue
            parts = raw.split("\t", 2)
            if len(parts) != 3:
                continue
            file, line_s, text = parts
            try:
                line = int(line_s)
            except ValueError:
                continue
            lines.append(AddedLine(file=file, line=line, text=text))
    return lines


def glob_match(patterns: Sequence[str], value: str) -> bool:
    for p in patterns:
        if fnmatch.fnmatch(value, p):
            return True
    return False


def compile_pattern(pat: str) -> re.Pattern[str]:
    return re.compile(pat)


def add_finding(
    out: List[Tuple[str, str, str, str, str, str, str, str, str]],
    seen: set[str],
    severity: str,
    category: str,
    location: str,
    evidence: str,
    risk: str,
    action: str,
    rule_id: str,
    source: str,
    confidence: str,
) -> None:
    key = f"{location}|{rule_id}|{evidence}"
    if key in seen:
        return
    seen.add(key)
    out.append(
        (
            severity,
            category,
            location,
            evidence.replace("\t", " "),
            risk.replace("\t", " "),
            action.replace("\t", " "),
            rule_id,
            source,
            confidence,
        )
    )


def build_file_index(lines: Sequence[AddedLine]) -> Dict[str, List[AddedLine]]:
    by_file: Dict[str, List[AddedLine]] = defaultdict(list)
    for ln in lines:
        by_file[ln.file].append(ln)
    return by_file


def detect_aggregate(
    rule: dict,
    lines: Sequence[AddedLine],
    by_file: Dict[str, List[AddedLine]],
    repo_dir: Optional[Path],
    files_json: Optional[Path],
) -> List[Tuple[str, str, str]]:
    agg = rule.get("aggregate_check")
    hits: List[Tuple[str, str, str]] = []
    if not agg:
        return hits

    if agg == "lock_unlock_balance":
        lock_re = re.compile(r"\b(spin_lock|mutex_lock|write_lock|read_lock)\s*\(")
        unlock_re = re.compile(r"\b(spin_unlock|mutex_unlock|write_unlock|read_unlock)\s*\(")
        for file, flines in by_file.items():
            lock_count = sum(1 for ln in flines if lock_re.search(ln.text))
            unlock_count = sum(1 for ln in flines if unlock_re.search(ln.text))
            code_lines = [ln for ln in flines if not re.match(r'^\s*(/\*|\*|//)', ln.text)]
            lock_lines = [ln for ln in code_lines if lock_re.search(ln.text)]
            unlock_count_code = sum(1 for ln in code_lines if unlock_re.search(ln.text))
            if lock_lines and unlock_count_code == 0:
                first = lock_lines[0]
                hits.append((f"{file}:{first.line}", f"lock acquired in diff ({len(lock_lines)}x) with no matching unlock in same diff", ""))
        return hits

    if agg == "alloc_without_free_hint":
        alloc_re = re.compile(r"\b(kmalloc|kzalloc|krealloc|vmalloc|calloc|malloc)\s*\(")
        free_re = re.compile(r"\b(kfree|vfree|free)\s*\(")
        for file, flines in by_file.items():
            alloc_lines = [ln for ln in flines if alloc_re.search(ln.text)]
            free_count = sum(1 for ln in flines if free_re.search(ln.text))
            if alloc_lines and free_count == 0:
                first = alloc_lines[0]
                hits.append((f"{file}:{first.line}", "alloc-like calls without visible free-like calls in changed lines", ""))
        return hits

    if agg == "refcount_without_put":
        inc_re = re.compile(r"\b(refcount_inc|kref_get|atomic_inc|atomic_inc_return)\s*\(")
        dec_re = re.compile(r"\b(refcount_dec|refcount_dec_and_test|kref_put|atomic_dec|atomic_dec_and_test)\s*\(")
        for file, flines in by_file.items():
            inc_lines = [ln for ln in flines if inc_re.search(ln.text)]
            dec_count = sum(1 for ln in flines if dec_re.search(ln.text))
            if inc_lines and dec_count == 0:
                first = inc_lines[0]
                hits.append((f"{file}:{first.line}", "refcount increment without visible dec/put in changed lines", ""))
        return hits

    if agg == "potential_double_free":
        free_re = re.compile(r"\b(kfree|free|vfree)\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)")
        for file, flines in by_file.items():
            func_re = re.compile(r'^[A-Za-z_][A-Za-z0-9_\s\*]+\s+[A-Za-z_][A-Za-z0-9_]*\s*\(')
            cur_func_start = 0
            func_groups: list = []
            cur_group: list = []
            for ln in flines:
                if func_re.match(ln.text.lstrip()) and '{' not in ln.text:
                    if cur_group:
                        func_groups.append(cur_group)
                    cur_group = [ln]
                    cur_func_start = ln.line
                else:
                    cur_group.append(ln)
            if cur_group:
                func_groups.append(cur_group)
            for group in func_groups:
                seen_g: Dict[str, int] = {}
                first_g: Dict[str, int] = {}
                for ln in group:
                    if re.match(r'^\s*(/\*|\*|//)', ln.text):
                        continue
                    m = free_re.search(ln.text)
                    if not m:
                        continue
                    var = m.group(2)
                    seen_g[var] = seen_g.get(var, 0) + 1
                    if var not in first_g:
                        first_g[var] = ln.line
                for var, cnt in seen_g.items():
                    if cnt > 1:
                        hits.append((f"{file}:{first_g[var]}", f"same pointer '{var}' freed {cnt} times in same function scope", ""))
        return hits

    if agg == "missing_check_hint":
        fallible_re = re.compile(r"\b(copy_from_user|copy_to_user|kmalloc|kzalloc|vmalloc|alloc|mutex_lock)\s*\(")
        for file, flines in by_file.items():
            for ln in flines:
                t = ln.text
                if not fallible_re.search(t):
                    continue
                # crude unchecked-signal heuristic
                if "=" not in t and "if (" not in t and not t.strip().startswith("return "):
                    hits.append((f"{file}:{ln.line}", "fallible operation appears without direct result check", ""))
                    break
        return hits

    if agg == "callback_name_inconsistency":
        cb_re = re.compile(r"\bdo_set_([A-Za-z0-9_]+)\b")
        fn_re = re.compile(r"\brpmi_[A-Za-z0-9_]+_set_([A-Za-z0-9_]+)\b")
        cb_suffixes = set()
        fn_suffixes = set()
        cb_loc = None
        for file, flines in by_file.items():
            for ln in flines:
                m1 = cb_re.search(ln.text)
                if m1:
                    cb_suffixes.add(m1.group(1).lower())
                    if cb_loc is None:
                        cb_loc = f"{file}:{ln.line}"
                m2 = fn_re.search(ln.text)
                if m2:
                    fn_suffixes.add(m2.group(1).lower())
        if cb_suffixes and fn_suffixes and cb_suffixes.isdisjoint(fn_suffixes):
            loc = cb_loc or "api-surface"
            hits.append((loc, f"callback suffixes={sorted(cb_suffixes)} differ from set-handler suffixes={sorted(fn_suffixes)}", ""))
        return hits

    if agg == "requires_length_guard":
        req_re = re.compile(r"\b(request_data|payload|msg_data)\b")
        len_cmp_re = re.compile(r"\brequest_datalen\b.*(<=|>=|==|!=|<|>)")
        for file, flines in by_file.items():
            req_lines = [ln for ln in flines if req_re.search(ln.text)]
            if not req_lines:
                continue
            has_guard = any(len_cmp_re.search(ln.text) for ln in flines)
            if not has_guard:
                first = req_lines[0]
                hits.append((f"{file}:{first.line}", "payload use without request_datalen guard in changed lines", ""))
        return hits

    if agg == "constant_success_return":
        ret_init = re.compile(r"\benum\s+\w+\s+ret\s*=\s*0\s*;")
        ret_return = re.compile(r"\breturn\s+ret\s*;")
        callback = re.compile(r"->\s*\w+\s*->\s*\w+\s*\(")
        for file, flines in by_file.items():
            has_init = any(ret_init.search(ln.text) for ln in flines)
            has_ret = any(ret_return.search(ln.text) for ln in flines)
            has_cb = any(callback.search(ln.text) for ln in flines)
            if has_init and has_ret and has_cb:
                first = next((ln for ln in flines if ret_init.search(ln.text)), flines[0])
                hits.append((f"{file}:{first.line}", "ret initialized to success and returned after callback path", ""))
        return hits

    if agg == "unused_parameter_signal":
        for file, flines in by_file.items():
            mentions = [ln for ln in flines if "request_datalen" in ln.text]
            if len(mentions) == 1:
                hits.append((f"{file}:{mentions[0].line}", "request_datalen appears only once in changed lines", ""))
        return hits

    if agg == "missing_defgroup_nearby":
        enum_re = re.compile(r"^\s*enum\s+rpmi_(\w+)_service_id\s*\{")
        for file, flines in by_file.items():
            for ln in flines:
                m = enum_re.search(ln.text)
                if not m:
                    continue
                group = m.group(1).lower()
                found = False
                if repo_dir:
                    abs_path = repo_dir / file
                    if abs_path.is_file():
                        low = max(1, ln.line - 120)
                        high = ln.line + 120
                        try:
                            with abs_path.open("r", encoding="utf-8", errors="replace") as f:
                                for idx, row in enumerate(f, start=1):
                                    if idx < low or idx > high:
                                        continue
                                    row_l = row.lower()
                                    if "\\defgroup" in row_l and group in row_l:
                                        found = True
                                        break
                        except OSError:
                            pass
                if not found:
                    hits.append((f"{file}:{ln.line}", f"missing nearby defgroup for service group '{group}'", ""))
        return hits

    if agg in {"api_change_without_tests", "api_change_without_release_note"} and files_json and files_json.is_file():
        try:
            files = json.loads(files_json.read_text(encoding="utf-8"))
        except Exception:
            files = []
        filenames = [str(x.get("filename", "")) for x in files if isinstance(x, dict)]
        api_changed = any(re.search(r"(^|/)(include|public|api|apis|interface|interfaces|proto|openapi|swagger)/|\.h$|\.hpp$|\.proto$", f) for f in filenames)
        tests_changed = any(re.search(r"(^|/)(test|tests|testing|spec|specs)/|(_test\.|\.spec\.)", f) for f in filenames)
        notes_changed = any(re.search(r"CHANGELOG|NEWS|RELEASE|release-notes|notes/", f) for f in filenames)
        if agg == "api_change_without_tests" and api_changed and not tests_changed:
            hits.append(("api-surface", "public API changed without obvious tests", ""))
        if agg == "api_change_without_release_note" and api_changed and not notes_changed:
            hits.append(("api-surface", "public API changed without release-note signal", ""))
        return hits

    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--added-lines-tsv", required=True)
    ap.add_argument("--rules-json", required=True)
    ap.add_argument("--repo-dir", default="")
    ap.add_argument("--files-json", default="")
    args = ap.parse_args()

    added_path = Path(args.added_lines_tsv)
    rules_path = Path(args.rules_json)
    repo_dir = Path(args.repo_dir) if args.repo_dir else None
    files_json = Path(args.files_json) if args.files_json else None

    lines = read_added_lines(added_path)
    by_file = build_file_index(lines)

    try:
        rules_doc = json.loads(rules_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"error: failed to read rules json: {exc}", file=sys.stderr)
        return 2

    rules = rules_doc.get("rules", [])
    findings: List[Tuple[str, str, str, str, str, str, str, str, str]] = []
    seen: set[str] = set()

    for rule in rules:
        rule_id = str(rule.get("id", "KV-UNKNOWN"))
        severity = str(rule.get("severity", "medium"))
        category = str(rule.get("category", "maintainability"))
        risk = str(rule.get("risk", "Potential vulnerability signal from patch content."))
        action = str(rule.get("action", "Review and harden this path."))
        source = str(rule.get("source", "https://docs.kernel.org/process/submit-checklist.html"))
        confidence = str(rule.get("confidence", "low"))

        # Aggregate checks that do not map 1:1 to a single regex line.
        agg_hits = detect_aggregate(rule, lines, by_file, repo_dir, files_json)
        for location, evidence, _ in agg_hits:
            add_finding(
                findings,
                seen,
                severity,
                category,
                location,
                f"{rule_id}: {evidence}",
                risk,
                action,
                rule_id,
                source,
                confidence,
            )

        pat = rule.get("pattern")
        if not pat:
            continue
        try:
            pat_re = compile_pattern(str(pat))
        except re.error:
            continue
        neg_res = []
        for p in rule.get("negative_patterns", []):
            try:
                neg_res.append(compile_pattern(str(p)))
            except re.error:
                pass
        sec_re = None
        if rule.get("secondary_pattern"):
            try:
                sec_re = compile_pattern(str(rule["secondary_pattern"]))
            except re.error:
                sec_re = None

        file_globs = [str(x) for x in rule.get("file_globs", []) if str(x).strip()]
        for ln in lines:
            if file_globs and not glob_match(file_globs, ln.file):
                continue
            if not pat_re.search(ln.text):
                continue
            if sec_re and not sec_re.search(ln.text):
                continue
            if any(nr.search(ln.text) for nr in neg_res):
                continue
            add_finding(
                findings,
                seen,
                severity,
                category,
                f"{ln.file}:{ln.line}",
                f"{rule_id}: {ln.text.strip()}",
                risk,
                action,
                rule_id,
                source,
                confidence,
            )

    for row in findings:
        print("\t".join(row))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
