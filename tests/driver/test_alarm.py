import signal

import pytest

from spectest.alarm import CallTimeout, alarm

BLOCKED = {signal.SIGALRM}


def test_a_signal_pending_at_exit_is_dropped_not_sent_to_the_old_handler():
    seen: list[int] = []
    old = signal.signal(signal.SIGALRM, lambda signum, frame: seen.append(signum))
    try:
        with alarm(60):
            signal.pthread_sigmask(signal.SIG_BLOCK, BLOCKED)
            signal.raise_signal(signal.SIGALRM)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, BLOCKED)
        assert seen == []
        assert signal.getitimer(signal.ITIMER_REAL) == (0.0, 0.0)
    finally:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, BLOCKED)
        signal.signal(signal.SIGALRM, old)


def test_the_previous_handler_is_restored_when_the_body_raises():
    def old_handler(signum, frame):
        pass

    old = signal.signal(signal.SIGALRM, old_handler)
    try:
        with pytest.raises(KeyError), alarm(60):
            raise KeyError
        assert signal.getsignal(signal.SIGALRM) is old_handler
    finally:
        signal.signal(signal.SIGALRM, old)


def test_the_alarm_raises_in_the_body():
    with pytest.raises(CallTimeout), alarm(0.01):
        while True:
            pass
