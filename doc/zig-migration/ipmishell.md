# Zig shell frontend

`zig build -Dzig-modules=ipmishell` replaces **all four** entry points from
`src/ipmishell.c`: `shell`, `exec`, `set`, and `echo`. With `-Dipmishell=true`
(the default), the shell remains in the C front end's command table. The
replacement has no readline dependency and is selected by default. Explicit
C/mixed builds without this module continue to compile the C oracle through
Phase 7. `-Dipmishell=false` hides
only `shell` as before, not `exec`, `set`, or `echo`.

The interactive editor and shared word parser live in
`src/zig/frontend/ipmishell.zig`. The non-interactive `exec`, `set`, and
`echo` entry points live in `src/zig/frontend/shell_commands.zig`; all four are
exported together when `ipmishell` is selected, including the default build.
Explicit C/mixed builds without that selection use `src/ipmishell.c`.

Successful `echo` and output-producing `set` commands use a Zig 0.16
streaming stdout writer, with the same trailing space for each echoed word,
the same stored session value/decimal port/two-digit lowercase hex address
formats, and the same final newlines as C. The shared
`util/stdout.zig` `trySyncC` drains output from preceding C commands before
any Zig writes; unlike the CLI/helper's `syncC` wrapper it returns a checked
error instead of panicking. A failed C flush, Zig write, or final Zig flush
reports an error and returns -1 rather than success; session setters and the
global `verbose`/CSV state retain their existing behavior.

The selected `exec` command opens and closes its script through the same C
`ipmi_open_file`/`fclose` path. A bounded Zig scanner counts at most 2047
physical bytes per `fgets`-sized chunk and passes only the prefix before the
first NUL to the shared Zig parser. It keeps consuming bytes after an embedded
NUL; a full chunk with an early NUL skips the overflow lookahead, just as the
old `strlen` check did. Exactly 2047 bytes followed by LF (or EOF) are
accepted; a following non-LF byte discards the rest of that physical line and
reports an overflow. CR is a normal byte; LF terminates a chunk. The scanner
still uses C `fgetc` on the owned `FILE*` to preserve its buffering, ownership
and shared stream offset. If a read fails partway through a chunk, the
scanner discards its partial command as `fgets` does; it does not dispatch
the prefix. An error in the *lookahead* after a complete 2047-byte chunk
still leaves that chunk available for dispatch. `ferror` reports either
read failure with the existing `exec: unable to read file` status/diagnostic.
The file-open and stream APIs remain C interop dependencies, not native
Zig file I/O.

The interactive editor uses a PTY's termios raw mode and a native Zig history
list (up/down arrows). Left/right arrows, Home/End, Delete, Backspace,
Ctrl-A/E/U/K, and Ctrl-D edit a line; Ctrl-C cancels it. Empty Ctrl-D or an
input-stream EOF exits, returning the last command's status, while `exit` and
`quit` return success. SIGINT, SIGTERM, SIGHUP, and SIGQUIT from another process
restore the terminal and re-raise the signal. The LAN keepalive callback runs
about every 30 seconds while idle. `TERM=dumb` (or an unset `TERM`) uses
carriage returns and backspaces instead of ANSI cursor control. On redirected
input, the editor still accepts commands without requiring a terminal,
including a last line with no newline.
Failed output writes (including zero-byte writes) abort line editing with a
reported I/O error and restore the terminal instead of continuing to process
input. Interrupted and partial writes are retried until complete.

Intentional parser differences from the C source: literal `~` inside quotes
is preserved (C replaces it with a space); `#` starts a script comment only
outside quoted text (C strips quoted `#` too). Tabs and other whitespace
separate script arguments as well as shell arguments; adjacent and empty
quoted words work. Unterminated quotes and more than 64 arguments fail with
an error instead of invoking a partially parsed command. Script lines beyond
the 2047-byte C buffer are rejected and skipped rather than executed as
multiple unrelated fragments (except that an early NUL still makes the
existing overflow check see only its prefix). No shell expansion or
persistent history file is added.

Run `zig build test-shell-unit -Dzig-modules=ipmishell` for the shared parser and
`zig build test-shell -Dzig-modules=ipmishell` for automated PTY/CLI coverage
(also part of `zig build test` when selected). The shell suite also accepts
`python3 tests/shell/pty.py zig-out/bin/ipmitool` after a normal build;
if available, pass a
second path to the binary built *without* the Zig module; the suite compares
the C `exec`/`set`/`echo` outputs and status with Zig. The test server listens
on a worktree-local Unix socket and stops when the suite finishes.
`zig build test-exec-line-input -Dzig-modules=ipmishell` compares the scanner
against the old C `fgets`/`fgetc`/`strlen` framing on in-memory C streams,
including every first byte, NULs, boundaries, CR/LF and EOF. Fault-injected
`fopencookie` streams compare mid-line, post-newline, lookahead and overflow
discard read errors without writing to a temporary directory.
`zig build test-golden -Dzig-modules=ipmishell -- --filter shellcmd_`
compares the selected Zig binary and the all-Zig binary against
`exec`/`set`/`echo` snapshots recorded from the unchanged C oracle. The
`shellcmd_exec_2048` golden also keeps the original C snapshot: only this
deliberately safer Zig overlong-line behavior uses its own `.zig.snap`. The
2047-byte and embedded-NUL cases match the C CLI exactly. The
`shellcmd_exec_stdout_order` snapshot and PTY test sandwich C-buffered SDR
stdout between Zig echo and set responses. `zig build test-shell-stdout-unit`
checks echo and every successful set response against libc `snprintf`, with
early and late failing writers. The PTY suite forces both a failed C pre-flush
and failed Zig writes through `/dev/full`, requiring a nonzero exit and an
error diagnostic instead of a shell panic. The selected Zig chassis prints
POH through checked Zig stdout and reports its own failed write. To keep
testing an *actual* libc-buffered-to-Zig transition, `test-shell` also builds
a test-only C-chassis/Zig-shell hybrid: its zero-count `chassis poh` reply is
buffered in libc before `mc reset warm` and Zig `echo`. A `/dev/full` run
requires the Zig reset's C pre-flush failure when MC is selected, or Zig
echo's C pre-flush failure when MC is C. The dummy interface has no live
session, so CLI goldens
cannot reach successful hostname, username, password, authtype, privlvl, or
port setters; their message formats have unit differential coverage, not
successful CLI golden coverage. With reduced local
flags `-Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false`, use
`-Dipmishell=false` for the unit and CLI goldens. For `test-shell`, select
`-Dzig-modules=ipmishell` or `-Dzig-modules=all` without disabling the shell:
both use the readline-free Zig frontend, including on hosts without readline
headers. To regenerate only the selected shell's intentionally different
overlong snapshot, run `tests/run.sh --binary zig-out/bin/ipmitool
--filter shellcmd_exec_2048 --zig-shell-deviations --update` after building
with `-Dzig-modules=ipmishell`; without that flag the harness checks the
original-C snapshot instead.
