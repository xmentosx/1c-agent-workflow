"""Lossless, review-only presentation of an already completed exchange.

No prompt, transport, retry, timeout, JSON-format or semantic acceptance policy.
The caller supplies the existing text assembler and sanitizer's output.
"""
from copy import deepcopy
from hashlib import sha256


def split_review(result, assembled, sanitize):
    """Select a nonempty final answer only if it is an exact assembled suffix.

    Unknown layouts keep the complete legacy answer. Retrieved text alone is
    never promoted to a final review. Never copy the exchange's reasoning field.
    """
    final = result.get("final_text")
    final = sanitize(final.strip()) if isinstance(final, str) and final.strip() else ""
    if final and assembled.endswith(final):
        review, context = final, assembled[:-len(final)]
        status = "separated" if context else "unchanged"
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
