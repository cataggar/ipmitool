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
#include <ipmitool/ipmi_event.h>
#include <ipmitool/ipmi_sdr.h>
#include <ipmitool/ipmi_sel.h>

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

	/*
	 * struct platform_event_msg - opaque: `event_type:7` / `event_dir:1`
	 * are bitfields.  The byte holding them is pinned by `event_data`.
	 */
	ABI_SIZEOF_platform_event_msg = sizeof(struct platform_event_msg),
	ABI_ALIGNOF_platform_event_msg = _Alignof(struct platform_event_msg),
	ABI_OFFSETOF_platform_event_msg__evm_rev =
		offsetof(struct platform_event_msg, evm_rev),
	ABI_OFFSETOF_platform_event_msg__sensor_type =
		offsetof(struct platform_event_msg, sensor_type),
	ABI_OFFSETOF_platform_event_msg__sensor_num =
		offsetof(struct platform_event_msg, sensor_num),
	ABI_OFFSETOF_platform_event_msg__event_data =
		offsetof(struct platform_event_msg, event_data),

	/*
	 * struct sel_event_record - opaque because its `standard_type` arm
	 * carries the same `event_type:7` / `event_dir:1` pair.
	 */
	ABI_SIZEOF_sel_event_record = sizeof(struct sel_event_record),
	ABI_ALIGNOF_sel_event_record = _Alignof(struct sel_event_record),
	ABI_OFFSETOF_sel_event_record__record_id =
		offsetof(struct sel_event_record, record_id),
	ABI_OFFSETOF_sel_event_record__record_type =
		offsetof(struct sel_event_record, record_type),
	ABI_OFFSETOF_sel_event_record__sel_type =
		offsetof(struct sel_event_record, sel_type),
	ABI_OFFSETOF_sel_event_record__std__timestamp =
		offsetof(struct sel_event_record, sel_type.standard_type.timestamp),
	ABI_OFFSETOF_sel_event_record__std__gen_id =
		offsetof(struct sel_event_record, sel_type.standard_type.gen_id),
	ABI_OFFSETOF_sel_event_record__std__evm_rev =
		offsetof(struct sel_event_record, sel_type.standard_type.evm_rev),
	ABI_OFFSETOF_sel_event_record__std__sensor_type =
		offsetof(struct sel_event_record, sel_type.standard_type.sensor_type),
	ABI_OFFSETOF_sel_event_record__std__sensor_num =
		offsetof(struct sel_event_record, sel_type.standard_type.sensor_num),
	ABI_OFFSETOF_sel_event_record__std__event_data =
		offsetof(struct sel_event_record, sel_type.standard_type.event_data),

	/*
	 * struct sdr_record_common_sensor - opaque: `keys.lun` / `keys.channel`
	 * and the `sensor.init` / `sensor.capabilities` sub-structs are all
	 * bitfields.  Only the prefix `lib/ipmi_event.c` reads is listed; the
	 * byte carrying the lun/channel bitfields is named via the field that
	 * follows it.
	 */
	ABI_OFFSETOF_sdr_common__keys__owner_id =
		offsetof(struct sdr_record_common_sensor, keys.owner_id),
	ABI_OFFSETOF_sdr_common__keys__sensor_num =
		offsetof(struct sdr_record_common_sensor, keys.sensor_num),
	ABI_OFFSETOF_sdr_common__keys__flags =
		offsetof(struct sdr_record_common_sensor, keys.sensor_num) - 1,
	ABI_OFFSETOF_sdr_common__sensor__type =
		offsetof(struct sdr_record_common_sensor, sensor.type),
	ABI_OFFSETOF_sdr_common__event_type =
		offsetof(struct sdr_record_common_sensor, event_type),

	/*
	 * struct sdr_record_list - not opaque, but `translate-c` drops the
	 * ATTRIBUTE_PACKING and emits a naturally aligned struct, so the Zig
	 * view of it is wrong by 8 bytes at `record`.  A hand written mirror
	 * checked against these constants is the only safe way to read it.
	 */
	ABI_SIZEOF_sdr_record_list = sizeof(struct sdr_record_list),
	ABI_ALIGNOF_sdr_record_list = _Alignof(struct sdr_record_list),
	ABI_OFFSETOF_sdr_record_list__id = offsetof(struct sdr_record_list, id),
	ABI_OFFSETOF_sdr_record_list__version =
		offsetof(struct sdr_record_list, version),
	ABI_OFFSETOF_sdr_record_list__type =
		offsetof(struct sdr_record_list, type),
	ABI_OFFSETOF_sdr_record_list__length =
		offsetof(struct sdr_record_list, length),
	ABI_OFFSETOF_sdr_record_list__raw = offsetof(struct sdr_record_list, raw),
	ABI_OFFSETOF_sdr_record_list__next =
		offsetof(struct sdr_record_list, next),
	ABI_OFFSETOF_sdr_record_list__record =
		offsetof(struct sdr_record_list, record),
};
