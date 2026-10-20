"""Lossless, review-only presentation of an already completed exchange.

No prompt, transport, retry, timeout, JSON-format or semantic acceptance policy.
The caller supplies the existing text assembler and sanitizer's output.
"""
from copy import deepcopy
from hashlib import sha256


def split_review(result, assembled, sanitize):
    """Separate only an exact suffix containing the complete assistant text.

    A final acknowledgement can refer to earlier findings in full_text. Do not
    move those findings out of the main answer. Missing provenance and unknown
    layouts keep the complete legacy answer, without semantic/length heuristics.
    Retrieved text alone is never promoted to a final review. Never copy reasoning.
    """
    final = result.get("final_text")
    final = sanitize(final.strip()) if isinstance(final, str) and final.strip() else ""
    full = result.get("full_text")
    full = sanitize(full.strip()) if isinstance(full, str) and full.strip() else ""
    if final and assembled == final:
        # No text is moved out of the answer, so no provenance is needed.
        review, context, status = final, "", "unchanged"
    elif final and full == final and assembled.endswith(final):
        review, context = final, assembled[:-len(final)]
        status = "separated"
    else:
        review, context, status = assembled, "", "unseparated"
    # The context already contains the legacy rendered tool evidence. Do not
    # duplicate its document bodies in a second public representation.
    # PromptOutcome.tool_results remains untouched for its existing consumers.
    evidence = {
        "status": status,
        "context": context,
        "assembled_sha256": sha256(assembled.encode("utf-8")).hexdigest(),
    }
    return review, evidence


def evidence_for_answer(evidence, selected_review, answer):
    """Retain the original selection if the existing plugin/verdict changes it."""
    proof = deepcopy(evidence)
    if answer != selected_review:
        proof["review_text"] = selected_review
    return proof
