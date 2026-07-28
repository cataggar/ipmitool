/*
 * Layout facts for C types that `translate-c` cannot represent.
 *
 * `translate-c` demotes any struct containing a bitfield to `opaque {}`, which
 * makes `@sizeOf`/`@offsetOf` unavailable on the Zig side and would leave the
 * hottest ipmitool structures without ABI assertions.  Re-stating the layout as
 * plain `enum` constants gets the numbers back: they are computed by the real C
 * compiler for the real target, so they stay correct for every architecture and
 * for both `HAVE_PRAGMA_PACK` settings, and they need no host execution.
 *
 * `src/zig/abi.zig` compares these against the hand written `extern struct`
 * mirrors, so any drift between a header and its Zig port is a compile error.
 *
 * Adding a type:
 *   1. Add `ABI_SIZEOF_x`, `ABI_ALIGNOF_x` and one `ABI_OFFSETOF_x__field` per
 *      field.  Nested members use the C member designator, e.g.
 *      `offsetof(struct ipmi_rq, msg.cmd)`; a `.` becomes `__` in the name.
 *   2. Bitfields have no address, so assert the offset of the byte that holds
 *      them via the field that follows.
 *   3. Reference the constants from the mirror's `abi.assertOpaqueLayout` call.
 *
 * Only needed for opaque types: everything `translate-c` represents faithfully
 * is compared directly against the `@cImport`ed type instead.
 */

#pragma once

#include <stddef.h>

#include <ipmitool/ipmi.h>

enum ipmitool_abi_layout {
	/* struct ipmi_rq - opaque: `msg.netfn:6` / `msg.lun:2` are bitfields. */
	ABI_SIZEOF_ipmi_rq = sizeof(struct ipmi_rq),
	ABI_ALIGNOF_ipmi_rq = _Alignof(struct ipmi_rq),
	ABI_OFFSETOF_ipmi_rq__msg = offsetof(struct ipmi_rq, msg),
	/* netfn/lun share the byte at offset 0; `cmd` pins that down. */
	ABI_OFFSETOF_ipmi_rq__msg__cmd = offsetof(struct ipmi_rq, msg.cmd),
	ABI_OFFSETOF_ipmi_rq__msg__target_cmd =
		offsetof(struct ipmi_rq, msg.target_cmd),
	ABI_OFFSETOF_ipmi_rq__msg__data_len =
		offsetof(struct ipmi_rq, msg.data_len),
	ABI_OFFSETOF_ipmi_rq__msg__data = offsetof(struct ipmi_rq, msg.data),

	/* struct ipmi_rq_entry - opaque because it embeds struct ipmi_rq. */
	ABI_SIZEOF_ipmi_rq_entry = sizeof(struct ipmi_rq_entry),
	ABI_ALIGNOF_ipmi_rq_entry = _Alignof(struct ipmi_rq_entry),
	ABI_OFFSETOF_ipmi_rq_entry__req = offsetof(struct ipmi_rq_entry, req),
	ABI_OFFSETOF_ipmi_rq_entry__intf = offsetof(struct ipmi_rq_entry, intf),
	ABI_OFFSETOF_ipmi_rq_entry__rq_seq =
		offsetof(struct ipmi_rq_entry, rq_seq),
	ABI_OFFSETOF_ipmi_rq_entry__msg_data =
		offsetof(struct ipmi_rq_entry, msg_data),
	ABI_OFFSETOF_ipmi_rq_entry__msg_len =
		offsetof(struct ipmi_rq_entry, msg_len),
	ABI_OFFSETOF_ipmi_rq_entry__bridging_level =
		offsetof(struct ipmi_rq_entry, bridging_level),
	ABI_OFFSETOF_ipmi_rq_entry__next = offsetof(struct ipmi_rq_entry, next),
};
