#!/usr/bin/env python3
"""Three small changes to Debian 12's glibc 2.36 source for the Infimech TX
vendor kernel (Linux 4.9.191), where system call 397 (statx on newer
kernels) and 398 (rseq) are vendor calls that answer EINVAL.
  1. stat()/fstat()/fstatat() on 32-bit ARM use fstatat64 (327) directly
     instead of trying statx first.
  2. statx() on 32-bit ARM is emulated with fstatat64 (glibc's own fallback).
  3. rseq registration is off by default (tunable glibc.pthread.rseq=0).
Usage: glibc_tx_edit.py <glibc source folder>. Every edit must match once."""
import sys, pathlib

src = pathlib.Path(sys.argv[1])
edits = [
    ("sysdeps/unix/sysv/linux/fstatat64.c",
     "#if (__WORDSIZE == 32 \\\n"
     "     && (!defined __SYSCALL_WORDSIZE || __SYSCALL_WORDSIZE == 32)) \\\n"
     "     || defined STAT_HAS_TIME32 \\\n"
     "     || (!defined __NR_newfstatat && !defined __NR_fstatat64)\n"
     "# define FSTATAT_USE_STATX 1\n",
     "/* Infimech TX: on the vendor kernel syscall 397 is not statx; use\n"
     "   fstatat64 on 32-bit ARM.  */\n"
     "#if !defined __arm__ && ((__WORDSIZE == 32 \\\n"
     "     && (!defined __SYSCALL_WORDSIZE || __SYSCALL_WORDSIZE == 32)) \\\n"
     "     || defined STAT_HAS_TIME32 \\\n"
     "     || (!defined __NR_newfstatat && !defined __NR_fstatat64))\n"
     "# define FSTATAT_USE_STATX 1\n"),
    ("sysdeps/unix/sysv/linux/statx.c",
     "  int ret = INLINE_SYSCALL_CALL (statx, fd, path, flags, mask, buf);\n"
     "#ifdef __ASSUME_STATX\n"
     "  return ret;\n"
     "#else\n",
     "#ifdef __arm__\n"
     "  /* Infimech TX: on the vendor kernel syscall 397 is not statx.  */\n"
     "  return statx_generic (fd, path, flags, mask, buf);\n"
     "#elif defined __ASSUME_STATX\n"
     "  return INLINE_SYSCALL_CALL (statx, fd, path, flags, mask, buf);\n"
     "#else\n"
     "  int ret = INLINE_SYSCALL_CALL (statx, fd, path, flags, mask, buf);\n"),
    ("sysdeps/nptl/dl-tunables.list",
     "    rseq {\n"
     "      type: INT_32\n"
     "      minval: 0\n"
     "      maxval: 1\n"
     "      default: 1\n"
     "    }\n",
     "    rseq {\n"
     "      type: INT_32\n"
     "      minval: 0\n"
     "      maxval: 1\n"
     "      default: 0\n"
     "    }\n"),
]
for rel, old, new in edits:
    p = src / rel
    text = p.read_text()
    if text.count(new) == 1 and text.count(old) == 0:
        print(f"already changed: {rel}")
        continue
    n = text.count(old)
    if n != 1:
        sys.exit(f"ERROR: {rel}: expected text found {n} times - not changed")
    p.write_text(text.replace(old, new))
    print(f"changed: {rel}")
