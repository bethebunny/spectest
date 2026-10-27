"""A time limit for one call, by SIGALRM (main thread only, and only between bytecodes)."""

from __future__ import annotations

import signal
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from types import FrameType


class CallTimeout(BaseException):
    """A call ran past its time limit: the verdict is inconclusive."""


@contextmanager
def alarm(seconds: float) -> Iterator[None]:
    armed = True

    def expire(signum: int, frame: FrameType | None) -> None:
        # a signal that lands after the call must not raise into later code
        if armed:
            raise CallTimeout(f"timed out after {seconds:g}s")

    previous = signal.signal(signal.SIGALRM, expire)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        armed = False
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def can_time_out() -> bool:
    """Timeouts need SIGALRM and the main thread."""
    return (
        hasattr(signal, "setitimer")
        and threading.current_thread() is threading.main_thread()
    )
