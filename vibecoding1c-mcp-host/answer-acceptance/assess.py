"""Offline whole-answer acceptance; no provider, server, or lifecycle authority."""
import argparse
import hashlib
import json
from pathlib import Path
import sys


class EvidenceError(ValueError):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def decode(data):
    return data.decode("utf-8-sig", errors="strict")


def load(path):
    return json.loads(decode(Path(path).read_bytes()))


def save(path, value):
    Path(path).write_bytes((json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def extract_answer(raw):
    """Accept saved MCP results, including common JSON-RPC/capture envelopes."""
    value = json.loads(decode(raw))
    for key in ("response", "result"):
        if isinstance(value, dict) and isinstance(value.get(key), dict):
            value = value[key]
    if not isinstance(value, dict) or value.get("isError"):
        raise EvidenceError("MCP result is missing or isError; preserve it as an unusable result")
    structured = value.get("structuredContent")
    texts = [item["text"] for item in value.get("content", [])
             if item.get("type") == "text" and isinstance(item.get("text"), str)]
    if structured is None and len(texts) == 1:
        try:
            structured = json.loads(texts[0])
        except json.JSONDecodeError:
            return texts[0]
    if not isinstance(structured, dict):
        raise EvidenceError("No unambiguous answer; retain raw result and resolve its response contract")
    answer = structured.get("answer", structured.get("result"))
    if not isinstance(answer, str):
        raise EvidenceError("No string answer in saved MCP result")
    if "result" in structured and structured["result"] != answer:
        raise EvidenceError("answer/result disagree; do not choose the convenient copy")
    if len(texts) != 1:
        raise EvidenceError("Ambiguous text content; compare the original MCP representations")
    if texts[0] != answer:
        try:
            content = json.loads(texts[0])
        except json.JSONDecodeError as error:
            raise EvidenceError("Text and structured answer disagree") from error
        if content != structured:
            raise EvidenceError("Text and structured result disagree")
    return answer


def units(answer):
    """Partition every non-whitespace character, without interpreting semantics.

    Paragraphs, individual table lines and fenced code are separate review units.
    Unknown Markdown remains ordinary text and cannot disappear from coverage.
    Offsets count Unicode characters; line numbers count LF, preserving CRLF bytes.
    """
    result, pending = [], []
    offset, start, start_line, fenced = 0, 0, 1, None

    def flush():
        nonlocal pending
        if pending:
            body = "".join(pending)
            result.append(dict(id=f"u{len(result)+1:04}", start=start,
                               end=start+len(body), line=start_line,
                               sha256=sha(body.encode("utf-8")), text=body))
            pending = []

    for number, chunk in enumerate(answer.splitlines(keepends=True), 1):
        stripped = chunk.strip()
        marker = "```" if stripped.startswith("```") else "~~~" if stripped.startswith("~~~") else None
        if fenced:
            pending.append(chunk)
            if marker == fenced:
                fenced = None
                flush()
        elif marker:
            flush()
            start, start_line, fenced = offset, answer[:offset].count("\n")+1, marker
            pending.append(chunk)
        elif not stripped:
            flush()
        elif stripped.startswith(("|", "#")):
            flush()
            start, start_line = offset, answer[:offset].count("\n")+1
            pending.append(chunk)
            flush()
        else:
            if not pending:
                start, start_line = offset, answer[:offset].count("\n")+1
            pending.append(chunk)
        offset += len(chunk)
    flush()
    return result


def prepare(code_path, raw_path, directory, response=False):
    code_raw, raw = Path(code_path).read_bytes(), Path(raw_path).read_bytes()
    code = decode(code_raw)
    answer = extract_answer(raw) if response else decode(raw)
    packet_units = units(answer)
    bindings = dict(sourceSha256=sha(code_raw), rawSha256=sha(raw),
                    answerSha256=sha(answer.encode("utf-8")))
    directory = Path(directory)
    if directory.exists():
        raise EvidenceError("Packet directory exists; use a new directory, never replace retained evidence")
    directory.mkdir(parents=True)
    (directory / "source.raw.bsl").write_bytes(code_raw)
    (directory / "response.raw").write_bytes(raw)
    (directory / "answer.txt").write_bytes(answer.encode("utf-8"))
    packet = dict(schemaVersion=1, bindings=bindings, response=response, units=packet_units)
    save(directory / "packet.json", packet)
    review = dict(schemaVersion=1, bindings=bindings, reviewer="",
                 format=dict(verdict="pending", rationale=""),
                 units=[dict(id=u["id"], sha256=u["sha256"], verdict="pending",
                             rationale="", witness="", evidence=[]) for u in packet_units])
    save(directory / "review.json", review)
    return dict(status="prepared", units=len(packet_units), accepted=False,
                continuation="Review every unit, including prose outside tables, then assess the same packet")


def verify_evidence(item, source):
    """Check exact quotes/locations; this is not a semantic proof engine."""
    if item.get("kind") == "source":
        document = source
    elif item.get("kind") == "reference":
        if not Path(item["path"]).is_absolute():
            raise EvidenceError("Reference path must be absolute")
        raw = Path(item["path"]).read_bytes()
        if sha(raw) != item.get("sha256"):
            raise EvidenceError("Reference hash changed")
        document = decode(raw)
    else:
        raise EvidenceError("Evidence must identify source or a hash-bound retained reference")
    quote, number = item.get("quote"), item.get("line")
    if not isinstance(quote, str) or not quote.strip() or type(number) is not int or number < 1:
        raise EvidenceError("Evidence needs a literal quote and positive source line")
    lines = document.split("\n")
    if number > len(lines):
        raise EvidenceError("Evidence line is outside its source")
    # A quote may start within its first line, but cannot move to another line.
    tail = "\n".join(lines[number-1:])
    position = tail.find(quote)
    if position < 0 or position >= len(lines[number-1]):
        raise EvidenceError("Quote does not occur at the claimed line")


def assess(directory, review_path):
    directory = Path(directory)
    packet, review = load(directory / "packet.json"), load(review_path)
    code_raw, raw = (directory / "source.raw.bsl").read_bytes(), (directory / "response.raw").read_bytes()
    answer = extract_answer(raw) if packet["response"] else decode(raw)
    actual = dict(sourceSha256=sha(code_raw), rawSha256=sha(raw), answerSha256=sha(answer.encode()))
    if packet.get("schemaVersion") != 1 or review.get("schemaVersion") != 1:
        raise EvidenceError("Unsupported packet/review schema")
    if actual != packet["bindings"] or actual != review.get("bindings"):
        raise EvidenceError("Input/answer identity changed; prepare a new packet and review the changed input")
    if (directory / "answer.txt").read_bytes() != answer.encode("utf-8"):
        raise EvidenceError("Preserved answer changed; restore from response.raw or prepare a new packet")
    expected_units = units(answer)
    if packet["units"] != expected_units:
        raise EvidenceError("Unit inventory changed; do not omit inconvenient answer text")
    decisions = review.get("units", [])
    if not isinstance(decisions, list):
        raise EvidenceError("Review unit inventory is invalid")
    if any(not isinstance(d, dict) for d in decisions):
        raise EvidenceError("Review decisions must be objects")
    ids = [d.get("id") for d in decisions]
    if len(ids) != len(set(ids)) or set(ids) != {u["id"] for u in expected_units}:
        raise EvidenceError("Review must cover every answer unit exactly once, including outside-table text")
    by_id = {d["id"]: d for d in decisions}
    unresolved, rejected, supported = [], [], 0
    for unit in expected_units:
        decision = by_id[unit["id"]]
        if decision.get("sha256") != unit["sha256"]:
            raise EvidenceError("Reviewed unit changed: " + unit["id"])
        verdict = decision.get("verdict")
        if verdict not in ("supported", "contradicted", "out-of-scope", "not-a-claim", "unverified", "pending"):
            raise EvidenceError("Unknown unit verdict: " + unit["id"])
        if verdict in ("pending", "unverified") or not nonempty(decision.get("rationale")):
            unresolved.append(dict(unit=unit["id"], reason="review-or-rationale-incomplete"))
            continue
        if verdict in ("supported", "contradicted"):
            if not nonempty(decision.get("witness")) or not decision.get("evidence"):
                unresolved.append(dict(unit=unit["id"], reason="witness-or-evidence-missing"))
                continue
            try:
                for item in decision["evidence"]:
                    verify_evidence(item, decode(code_raw))
            except (EvidenceError, OSError, KeyError, UnicodeError) as error:
                unresolved.append(dict(unit=unit["id"], reason=str(error)))
                continue
        if verdict in ("contradicted", "out-of-scope"):
            rejected.append(dict(unit=unit["id"], verdict=verdict, rationale=decision["rationale"]))
        elif verdict == "supported":
            supported += 1
    fmt = review.get("format", {})
    if fmt.get("verdict") not in ("pass", "fail", "unverified", "pending"):
        raise EvidenceError("Format needs an explicit assessment")
    if fmt.get("verdict") in ("pending", "unverified") or not nonempty(fmt.get("rationale")):
        unresolved.append(dict(unit="format", reason="format-unreviewed"))
    elif fmt["verdict"] == "fail":
        rejected.append(dict(unit="format", verdict="fail", rationale=fmt["rationale"]))
    if not nonempty(review.get("reviewer")) or not supported or not expected_units:
        unresolved.append(dict(unit="answer", reason="reviewer-or-substantive-analysis-missing"))
    status = "rejected" if rejected else "unverified" if unresolved else "accepted"
    return dict(schemaVersion=1, status=status, accepted=status == "accepted", bindings=actual,
                reviewedUnits=len(expected_units), supportedUnits=supported,
                rejected=rejected, unresolved=unresolved,
                reviewer=review.get("reviewer", ""),
                scope="answer quality only; not product-code correctness or lifecycle permission",
                continuation="Resolve open units/evidence against exact inputs; preserve the raw answer. "
                "A rejected answer does not require appeasement edits or automatic AI retries. "
                "Adjudicate product findings through the existing verification evidence owner.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--code", required=True)
    input_group = prepare_parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument("--response")
    input_group.add_argument("--answer")
    prepare_parser.add_argument("--out", required=True)
    check = commands.add_parser("assess")
    check.add_argument("--packet", required=True)
    check.add_argument("--review", required=True)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            result = prepare(args.code, args.response or args.answer, args.out, bool(args.response))
        else:
            result = assess(args.packet, args.review)
            # Report is derived; immutable originals and reviewer decisions are never overwritten.
            target = Path(args.packet) / "assessment.json"
            if target.resolve() == Path(args.review).resolve():
                raise EvidenceError("Report path collides with review; retain the original review")
            save(target, result)
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result["status"] in ("prepared", "accepted") else 1 if result["status"] == "rejected" else 2
    except (EvidenceError, OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        print(json.dumps(dict(status="unverified", accepted=False, error=str(error),
                             continuation="Retain original files, correct the evidence/coverage and repeat assess; no AI replay"), ensure_ascii=False))
        return 2


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="strict")
    sys.exit(main())
