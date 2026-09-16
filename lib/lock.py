#!/usr/bin/env python3
"""Open a lock file safely and exec a command with the descriptor inherited.

Shell redirection has no O_NOFOLLOW equivalent.  A check (or a ``touch``)
followed by ``exec 9>path`` therefore still leaves a pathname race, and the
redirection also truncates an existing file before ``flock`` gets a chance to
reject it.  This small boundary opens the parent directory as a chain of
descriptors, opens the final name once with O_NOFOLLOW and no O_TRUNC, then
execs the protected command with that exact descriptor in fd 9.

The directory walk follows user-created symlinks only after opening and
re-validating their targets from the root.  This keeps the ordinary dotfiles
layout usable while preventing a path component from being swapped between a
check and the open.  The lock name itself is deliberately stricter: a
symlink is never a valid lock file, even when its target is trusted.
"""

from __future__ import annotations

import errno
import os
import stat
import sys


MAX_SYMLINK_HOPS = 10


class Refused(Exception):
    """The requested directory or lock file is outside the trust contract."""


def _require_component(name: str) -> None:
    if not name or name in (".", "..") or "/" in name:
        raise Refused(f"refusing {name!r}: not a single path component")


def _check_trusted(fd: int, path: str) -> None:
    st = os.fstat(fd)
    if st.st_uid not in (0, os.geteuid()):
        raise Refused(f"refusing {path}: directory is owned by neither root nor us")
    writable_by_others = st.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    if writable_by_others and not (st.st_mode & stat.S_ISVTX):
        raise Refused(f"refusing {path}: directory is writable by others without sticky bit")


def _parts(target: str) -> list[str]:
    return [part for part in target.split("/") if part]


def open_dir_chain(path: str, create: bool) -> int:
    """Return a trusted fd for ``path``, resolving each component by fd."""

    if not path.startswith("/"):
        raise Refused(f"refusing non-absolute directory: {path!r}")

    expected_uid = os.geteuid()
    root_fd = os.open("/", os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    stack = [root_fd]
    queue = _parts(path)
    hops = 0

    try:
        while queue:
            part = queue.pop(0)
            if part == ".":
                continue
            if part == "..":
                if len(stack) > 1:
                    os.close(stack.pop())
                continue

            current = stack[-1]
            try:
                entry = os.lstat(part, dir_fd=current)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(part, mode=0o700, dir_fd=current)
                entry = os.lstat(part, dir_fd=current)

            if stat.S_ISLNK(entry.st_mode):
                hops += 1
                if hops > MAX_SYMLINK_HOPS:
                    raise Refused(f"refusing {path}: symlink chain too long or cyclic")
                target = os.readlink(part, dir_fd=current)
                if target.startswith("/"):
                    for fd in stack[1:]:
                        os.close(fd)
                    del stack[1:]
                queue = _parts(target) + queue
                continue

            next_fd = os.open(
                part,
                os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                dir_fd=current,
            )
            stack.append(next_fd)
            _check_trusted(next_fd, path)

        result = stack.pop()
        for fd in stack:
            os.close(fd)
        return result
    except BaseException:
        for fd in stack:
            try:
                os.close(fd)
            except OSError:
                pass
        raise


def open_lock_fd(dir_fd: int, name: str) -> int:
    """Open one non-symlink regular lock file relative to ``dir_fd``."""

    _require_component(name)
    try:
        entry = os.lstat(name, dir_fd=dir_fd)
    except FileNotFoundError:
        entry = None
    if entry is not None and stat.S_ISLNK(entry.st_mode):
        raise Refused(f"refusing {name}: a symlink where a lock file belongs")

    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_NOFOLLOW
        | os.O_CLOEXEC
        | os.O_NONBLOCK
    )
    try:
        fd = os.open(name, flags, 0o600, dir_fd=dir_fd)
    except OSError as exc:
        if exc.errno in (errno.ELOOP, errno.ENXIO):
            reason = "a symlink where a lock file belongs" if exc.errno == errno.ELOOP else "lock is not a regular file"
            raise Refused(f"refusing {name}: {reason}") from exc
        raise

    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise Refused(f"refusing {name}: lock is not a regular file")
        if st.st_uid not in (0, os.geteuid()):
            raise Refused(f"refusing {name}: lock is owned by neither root nor us")
        if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise Refused(f"refusing {name}: lock is writable by group or others")
        return fd
    except BaseException:
        os.close(fd)
        raise


def exec_with_lock(dir_path: str, name: str, fd_num: int, command: list[str]) -> None:
    if not command:
        raise ValueError("a command is required")
    dir_fd = open_dir_chain(dir_path, create=True)
    try:
        lock_fd = open_lock_fd(dir_fd, name)
    finally:
        os.close(dir_fd)

    try:
        os.dup2(lock_fd, fd_num)
        os.set_inheritable(fd_num, True)
    finally:
        if lock_fd != fd_num:
            os.close(lock_fd)
    os.execvp(command[0], command)


def main() -> None:
    if len(sys.argv) < 3 or sys.argv[1] != "exec-with-lock":
        print(
            "usage: lock.py exec-with-lock <dir> <name> <fd_num> -- <command> [args...]",
            file=sys.stderr,
        )
        raise SystemExit(2)

    try:
        separator = sys.argv.index("--")
        directory, name, fd_num = sys.argv[2:separator]
        command = sys.argv[separator + 1 :]
        if not command:
            raise ValueError
        exec_with_lock(directory, name, int(fd_num), command)
    except ValueError:
        print(
            "usage: lock.py exec-with-lock <dir> <name> <fd_num> -- <command> [args...]",
            file=sys.stderr,
        )
        raise SystemExit(2)
    except Refused as exc:
        print(f"safe_lock: {exc}", file=sys.stderr)
        raise SystemExit(1)
    except OSError as exc:
        print(f"safe_lock: {exc}", file=sys.stderr)
        raise SystemExit(5)


if __name__ == "__main__":
    main()
