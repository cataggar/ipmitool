/*
 * Umbrella header for the Zig -> C bridge.
 *
 * `build.zig` feeds this file to `zig translate-c` and exposes the result as
 * the `ipmi_c` Zig module, so a ported Zig module can call every part of
 * ipmitool that is still written in C.  It carries no declarations of its own;
 * it only decides which of `include/ipmitool/*.h` the bridge exposes.
 *
 * This is one of exactly two C files owned by the Zig tree (the other is
 * `abi_layout.h`).  Both disappear together with the last C translation unit.
 *
 * To expose another header, add an `#include` below and rebuild; see
 * doc/zig-migration/interop-seams.md.
 */

#pragma once

/*
 * POSIX headers used by ported modules.  `lib/helper.c` calls lstat(), fstat(),
 * fork(), ioctl() and friends; Zig's standard library deliberately dropped the
 * Linux `struct stat` bindings, so the bridge has to supply the libc ones to
 * keep the ported code bit-identical to the C it replaces.
 */
#include <fcntl.h>
#include <paths.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <ipmitool/helper.h>
#include <ipmitool/log.h>
#include <ipmitool/bswap.h>
#include <ipmitool/ipmi.h>
#include <ipmitool/ipmi_cc.h>
#include <ipmitool/ipmi_constants.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi_oem.h>
#include <ipmitool/ipmi_sel.h>
#include <ipmitool/ipmi_sdr.h>
#include <ipmitool/ipmi_strings.h>
#include <ipmitool/ipmi_time.h>

/*
 * Plugin-private headers.  These are not under `include/`, so they are reached
 * relative to this file rather than through the include path; adding
 * `src/plugins/*` to the bridge's `-I` list would make the two `asf.h` /
 * `rmcp.h` pairs ambiguous.
 */
#include "../plugins/lan/md5.h"
#include "../plugins/lan/auth.h"
#include "../plugins/lanplus/lanplus.h"
#include "../plugins/lanplus/lanplus_crypt.h"
#include "../plugins/lanplus/lanplus_crypt_impl.h"

#include "abi_layout.h"
