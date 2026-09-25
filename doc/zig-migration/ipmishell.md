# Optional Zig shell frontend

`zig build -Dzig-modules=ipmishell` replaces **all four** entry points from
`src/ipmishell.c`: `shell`, `exec`, `set`, and `echo`. With `-Dipmishell=true`
(the default), the shell remains in the C front end's command table. The
replacement has no readline dependency; ordinary builds without this module
continue to compile the C oracle through Phase 7. `-Dipmishell=false` hides
only `shell` as before, not `exec`, `set`, or `echo`.

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

Intentional parser differences from the C source: literal `~` inside quotes
is preserved (C replaces it with a space); `#` starts a script comment only
outside quoted text (C strips quoted `#` too). Tabs and other whitespace
separate script arguments as well as shell arguments; adjacent and empty
quoted words work. Unterminated quotes and more than 64 arguments fail with
an error instead of invoking a partially parsed command. Script lines beyond
the 2047-byte C buffer are rejected and skipped rather than executed as
multiple unrelated fragments. No shell expansion or persistent history file
is added.

Run `zig build test-unit -Dzig-modules=ipmishell` and
`zig build test-shell -Dzig-modules=ipmishell` for automated PTY/CLI coverage
(also part of `zig build test` when selected). The shell suite also accepts
`python3 tests/shell/pty.py zig-out/bin/ipmitool` after a normal build;
if available, pass a
second path to the binary built *without* the Zig module; the suite compares
the C `exec`/`set`/`echo` outputs and status with Zig. The test server listens
on a worktree-local Unix socket and stops when the suite finishes.
