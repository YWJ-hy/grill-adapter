#!/usr/bin/env python3
"""Atomically exchange two filesystem paths using the host OS primitive."""

from __future__ import annotations

import ctypes
import os
from pathlib import Path
import platform
import sys
import uuid


def _raise_errno(operation: str) -> None:
    value = ctypes.get_errno()
    raise OSError(value, f"{operation} failed: {os.strerror(value)}")


def _darwin(first: str, second: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    renamex_np = libc.renamex_np
    renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    renamex_np.restype = ctypes.c_int
    if renamex_np(os.fsencode(first), os.fsencode(second), 0x00000002) != 0:
        _raise_errno("renamex_np(RENAME_SWAP)")


def _linux(first: str, second: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is not None:
        renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        renameat2.restype = ctypes.c_int
        result = renameat2(-100, os.fsencode(first), -100, os.fsencode(second), 0x00000002)
    else:
        syscall_numbers = {"x86_64": 316, "aarch64": 276}
        number = syscall_numbers.get(platform.machine().lower())
        if number is None:
            raise RuntimeError(f"renameat2 syscall number is unknown for {platform.machine()}")
        result = libc.syscall(number, -100, os.fsencode(first), -100, os.fsencode(second), 0x00000002)
    if result != 0:
        _raise_errno("renameat2(RENAME_EXCHANGE)")


def _windows(first: str, second: str) -> None:
    backup = f"{second}.swap-backup-{uuid.uuid4()}"
    replace_file = ctypes.windll.kernel32.ReplaceFileW
    replace_file.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
    replace_file.restype = ctypes.c_int
    if replace_file(first, second, backup, 0, None, None) == 0:
        raise ctypes.WinError()
    try:
        os.replace(backup, second)
    except OSError:
        # Restore the original target atomically if materializing the swapped-out
        # path fails; use `second` as the backup of the proposed replacement.
        if replace_file(first, backup, second, 0, None, None) == 0:
            raise ctypes.WinError()
        raise


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: atomic_swap.py <first-path> <second-path>")
    first, second = map(str, map(Path, sys.argv[1:]))
    system = platform.system()
    if system == "Darwin":
        _darwin(first, second)
    elif system == "Linux":
        _linux(first, second)
    elif system == "Windows":
        _windows(first, second)
    else:
        raise RuntimeError(f"atomic path exchange is unsupported on {system}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
