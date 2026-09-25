# Optional Zig shell frontend

`zig build -Dzig-modules=ipmishell` replaces **all four** entry points from
`src/ipmishell.c`: `shell`, `exec`, `set`, and `echo`. With `-Dipmishell=true`
(the default), the shell remains in the C front end's command table. The
replacement has no readline dependency; ordinary builds without this module
continue to compile the C oracle through Phase 7. `-Dipmishell=false` hides
only `shell` as before, not `exec`, `set`, or `echo`.

The interactive editor and shared word parser live in
`src/zig/frontend/ipmishell.zig`. The non-interactive `exec`, `set`, and
`echo` entry points live in `src/zig/frontend/shell_commands.zig`; all four are
exported together only when `ipmishell` is selected. The default build still
uses `src/ipmishell.c` for all three commands.

Successful `echo` and output-producing `set` commands use a Zig 0.16
streaming stdout writer, with the same trailing space for each echoed word,
the same stored session value/decimal port/two-digit lowercase hex address
formats, and the same final newlines as C. The shared
`util/stdout.zig` `trySyncC` drains output from preceding C commands before
any Zig writes; unlike the CLI/helper's `syncC` wrapper it returns a checked
error instead of panicking. A failed C flush, Zig write, or final Zig flush
reports an error and returns -1 rather than success; session setters and the
global `verbose`/CSV state retain their existing behavior. Script `FILE`
ownership and reading remain unchanged.

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
multiple unrelated fragments. No shell expansion or persistent history file
is added.

Run `zig build test-shell-unit -Dzig-modules=ipmishell` for the shared parser and
`zig build test-shell -Dzig-modules=ipmishell` for automated PTY/CLI coverage
(also part of `zig build test` when selected). The shell suite also accepts
`python3 tests/shell/pty.py zig-out/bin/ipmitool` after a normal build;
if available, pass a
second path to the binary built *without* the Zig module; the suite compares
the C `exec`/`set`/`echo` outputs and status with Zig. The test server listens
on a worktree-local Unix socket and stops when the suite finishes.
`zig build test-golden -Dzig-modules=ipmishell -- --filter shellcmd_`
compares both the selected Zig binary and the all-Zig binary against thirteen
`exec`/`set`/`echo` snapshots recorded from the unchanged C oracle. The
`shellcmd_exec_stdout_order` snapshot and PTY test sandwich C-buffered SDR
stdout between Zig echo and set responses. `zig build test-shell-stdout-unit`
checks echo and every successful set response against libc `snprintf`, with
early and late failing writers. The PTY suite forces both a failed C pre-flush
and failed Zig writes through `/dev/full`, requiring a nonzero exit and an
error diagnostic instead of a shell panic. The dummy interface has no live
session, so CLI goldens cannot reach successful hostname, username, password,
authtype, privlvl, or port setters; their message formats have unit
differential coverage, not successful CLI golden coverage. With reduced local
flags `-Dopenssl=false -Dinternal-md5=true -Dintf-lanplus=false`, use
`-Dipmishell=false` for the unit and CLI goldens; `test-shell` needs
`-Dipmishell=true` to enable the interactive command even when Zig supplies
the readline-free frontend.
