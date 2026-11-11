"""Enforce the documented one-OS-process ledger ownership on Windows / POSIX."""
from pathlib import Path


class ProcessLease:
    def __init__(self, path: Path):
        self.path = path
        self.file = None

    def acquire(self):
        import os

        if self.file is not None:
            raise RuntimeError("Backend service is already started")
        self.file = self.path.open("a+b")
        self.file.seek(0)
        self.file.write(b"1")
        self.file.flush()
        self.file.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.file.close()
            self.file = None
            raise RuntimeError("Only one backend process may open this RUYUAN_DATA_DIR") from None

    def release(self):
        if self.file:
            self.file.close()  # Kernel releases the lock, including after crashes.
            self.file = None
