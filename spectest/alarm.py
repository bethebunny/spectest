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

    previous = signal.SIG_DFL
    try:
        previous = signal.signal(signal.SIGALRM, expire)
        signal.setitimer(signal.ITIMER_REAL, seconds)
        yield
    finally:
        armed = False
        # blocked, so a late signal stays pending instead of raising out of here
        old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGALRM})
        try:
            signal.setitimer(signal.ITIMER_REAL, 0)
            # ignoring discards a pending signal, so the restored handler never sees it
            signal.signal(signal.SIGALRM, signal.SIG_IGN)
            signal.signal(signal.SIGALRM, previous)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def can_time_out() -> bool:
    """Timeouts need SIGALRM and the main thread."""
    return (
        hasattr(signal, "setitimer")
        and threading.current_thread() is threading.main_thread()
    )
