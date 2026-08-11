"""Narrow retry policy for transient 1C.ai transport disconnects."""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable, Sequence
from typing import Any


LOGGER = logging.getLogger(__name__)

DEFAULT_BACKOFF_SECONDS = (0.25, 0.75)

_TRANSIENT_NETWORK_MARKERS = (
    "incomplete chunked read",
    "peer closed connection",
    "server disconnected",
    "connection reset",
    "connection aborted",
    "connection closed",
    "remote protocol error",
    "remoteprotocolerror",
    "readerror",
    "writeerror",
    "connecterror",
    "network error while sending message",
    "ошибка сети при отправке сообщения",
)


def _exception_text(error: BaseException) -> str:
    parts: list[str] = []
    current: BaseException | None = error
    seen: set[int] = set()
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        parts.append(str(current))
        message = getattr(current, "message", None)
        if message is not None:
            parts.append(str(message))
        current = current.__cause__ or current.__context__
    return " ".join(parts).casefold()


def is_transient_network_error(error: BaseException) -> bool:
    """Return True only for known temporary transport-disconnect diagnostics."""

    text = _exception_text(error)
    return any(marker in text for marker in _TRANSIENT_NETWORK_MARKERS)


async def send_with_transient_network_retry(
    client: Any,
    question: str,
    *,
    backoff_seconds: Sequence[float] = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
) -> str:
    """Send a prompt, opening a fresh 1C.ai session for every bounded attempt."""

    delays = tuple(backoff_seconds)
    for attempt in range(len(delays) + 1):
        try:
            conversation_id = await client.get_or_create_session(create_new=True)
            return await client.send_message(conversation_id, question)
        except Exception as error:
            if not is_transient_network_error(error) or attempt == len(delays):
                raise
            delay = delays[attempt]
            LOGGER.warning(
                "Transient 1C.ai network disconnect; retrying check_1c_code "
                "with a fresh session in %.2fs (attempt %d/%d): %s",
                delay,
                attempt + 2,
                len(delays) + 1,
                error,
            )
            await sleep(delay)
