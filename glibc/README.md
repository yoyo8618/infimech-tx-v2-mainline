# glibc 2.36 for Debian 12 on the Infimech TX vendor kernel

Stock Debian 12 can't start programs on the TX's kernel (Linux 4.9.191). On that kernel, system calls 397 and 398 are vendor calls that return `EINVAL`. Newer kernels use those numbers for `statx` and `rseq`, and glibc 2.36 relies on them. These packages are Debian's `2.36-9+deb12u14`, rebuilt with three changes (`../scripts/glibc_tx_edit.py`):
1. `stat()` and its relatives use `fstatat64` on 32-bit ARM instead of trying `statx` first.
2. `statx()` is emulated with `fstatat64`.
3. rseq is off by default (`glibc.pthread.rseq=0`).

Version `2.36-9+deb12u14+tx1`, armhf: `libc6`, `libc6-dev`, `libc-bin`, `libc-dev-bin`, `libc-devtools`. **Download** the `.deb` files from this repository's **Releases**. Checksums are in `SHA256SUMS` (`sha256sum -c SHA256SUMS`).

**When to install**
- **Before the Debian 12 system's first start on the printer.** Install them on the PC, in the qemu armhf chroot where you built Debian 12. Don't install them on the printer into a stock Debian 12 tree: the package scripts would run with the stock glibc and fail.
- **On a running TX Debian 12 that already has a `+tx` build.** Install them on the printer, inside the chroot.

**Install and pin** (inside the target Debian 12):
```
dpkg -i libc6_*.deb libc-bin_*.deb libc6-dev_*.deb libc-dev-bin_*.deb libc-devtools_*.deb
cat > /etc/apt/preferences.d/glibc-tx <<'PIN'
Package: libc-bin libc-dev-bin libc-devtools libc6 libc6-dev
Pin: version *+tx1
Pin-Priority: 1001
PIN
apt-get -s upgrade | grep -E '^Inst (libc6|libc-bin)' || echo "apt keeps the rebuilt glibc"
```
Leave `locales` and `libc-l10n` stock (architecture "all").

**Tested:** on one TX V2 since 2026-11-25: Klipper, Moonraker, nginx, git, Python 3.11, prints. Under qemu's system-call trace, starting Python and stat-ing a file made 167 `statx`/`rseq` calls with stock glibc and 0 with this one.

**Security updates:** the pin keeps Debian's own glibc updates out, because stock Debian glibc wouldn't run. When Debian releases a newer `2.36-9+deb12uN`, rebuild it with `../scripts/pc_glibc.sh` (about 20 minutes on a fast PC). Rebuilding it yourself is also the safer choice if you'd rather not install system libraries built by someone else.

**Source (LGPL-2.1+):** Debian's glibc source package `2.36-9+deb12u14` (`apt-get source glibc=2.36-9+deb12u14`, or snapshot.debian.org), plus the three edits in `../scripts/glibc_tx_edit.py`. The build commands are in `../scripts/pc_glibc.sh`.
