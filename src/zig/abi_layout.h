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

#include <netinet/in.h>
#include <sys/socket.h>

#include <ipmitool/ipmi.h>
#include <ipmitool/ipmi_event.h>
#include <ipmitool/ipmi_sdr.h>
#include <ipmitool/ipmi_sensor.h>
#include <ipmitool/ipmi_sel.h>
#include <ipmitool/ipmi_channel.h>

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
	 * `lib/ipmi_sensor.c` additionally reads the entity id/instance pair and
	 * the Units 1 byte.  `entity.instance:7` and `unit.analog:2` are
	 * bitfields, so both are named through the addressable field next to
	 * them: the instance byte follows `entity.id`, and the units byte
	 * precedes `unit.type.base`.
	 */
	ABI_OFFSETOF_sdr_common__entity__id =
		offsetof(struct sdr_record_common_sensor, entity.id),
	ABI_OFFSETOF_sdr_common__entity__instance =
		offsetof(struct sdr_record_common_sensor, entity.id) + 1,
	ABI_OFFSETOF_sdr_common__unit =
		offsetof(struct sdr_record_common_sensor, unit.type.base) - 1,
	ABI_OFFSETOF_sdr_common__unit__type__base =
		offsetof(struct sdr_record_common_sensor, unit.type.base),
	ABI_OFFSETOF_sdr_common__unit__type__modifier =
		offsetof(struct sdr_record_common_sensor, unit.type.modifier),

	/*
	 * struct entity_id - opaque: `instance:7` / `logical:1` are bitfields.
	 * `lib/ipmi_sel.c` builds one on the stack for
	 * ipmi_sdr_find_sdr_byentity(), so the mirror needs its size.
	 */
	ABI_SIZEOF_entity_id = sizeof(struct entity_id),
	ABI_ALIGNOF_entity_id = _Alignof(struct entity_id),
	ABI_OFFSETOF_entity_id__id = offsetof(struct entity_id, id),

	/*
	 * The ID string of every SDR record type `lib/ipmi_sel.c` can be handed
	 * by ipmi_sdr_find_sdr_bynumtype(), plus the entity pair it copies out
	 * of a full/compact or event-only record.  All six record types are
	 * `opaque {}` on the Zig side, so the printer indexes them as bytes.
	 */
	ABI_OFFSETOF_sdr_compact__id_string =
		offsetof(struct sdr_record_compact_sensor, id_string),
	ABI_OFFSETOF_sdr_eventonly__id_string =
		offsetof(struct sdr_record_eventonly_sensor, id_string),
	ABI_OFFSETOF_sdr_eventonly__entity__id =
		offsetof(struct sdr_record_eventonly_sensor, entity.id),
	ABI_OFFSETOF_sdr_eventonly__entity__instance =
		offsetof(struct sdr_record_eventonly_sensor, entity.id) + 1,
	ABI_OFFSETOF_sdr_fruloc__id_string =
		offsetof(struct sdr_record_fru_locator, id_string),
	ABI_OFFSETOF_sdr_mcloc__id_string =
		offsetof(struct sdr_record_mc_locator, id_string),
	ABI_OFFSETOF_sdr_genloc__id_string =
		offsetof(struct sdr_record_generic_locator, id_string),

	/*
	 * struct sdr_record_full_sensor / struct sdr_record_compact_sensor -
	 * opaque, because both embed struct sdr_record_common_sensor.  Only the
	 * fields `lib/ipmi_sensor.c` touches are listed: the reading factors it
	 * overwrites from a Get Sensor Reading Factors response, the hysteresis
	 * pair it forwards to ipmi_sdr_print_sensor_hysteresis(), and the ID
	 * string it prints.
	 */
	ABI_SIZEOF_sdr_record_full_sensor = sizeof(struct sdr_record_full_sensor),
	ABI_SIZEOF_sdr_full__mtol =
		sizeof(((struct sdr_record_full_sensor *)0)->mtol),
	ABI_SIZEOF_sdr_full__bacc =
		sizeof(((struct sdr_record_full_sensor *)0)->bacc),
	ABI_OFFSETOF_sdr_full__mtol = offsetof(struct sdr_record_full_sensor, mtol),
	ABI_OFFSETOF_sdr_full__bacc = offsetof(struct sdr_record_full_sensor, bacc),
	ABI_OFFSETOF_sdr_full__hysteresis__positive =
		offsetof(struct sdr_record_full_sensor, threshold.hysteresis.positive),
	ABI_OFFSETOF_sdr_full__hysteresis__negative =
		offsetof(struct sdr_record_full_sensor, threshold.hysteresis.negative),
	ABI_OFFSETOF_sdr_full__id_string =
		offsetof(struct sdr_record_full_sensor, id_string),
	ABI_OFFSETOF_sdr_compact__hysteresis__positive =
		offsetof(struct sdr_record_compact_sensor,
			 threshold.hysteresis.positive),
	ABI_OFFSETOF_sdr_compact__hysteresis__negative =
		offsetof(struct sdr_record_compact_sensor,
			 threshold.hysteresis.negative),

	/*
	 * struct sdr_get_rs - not opaque, and its five fields happen to sit at
	 * the same offsets packed and unpacked, but translate-c still drops the
	 * ATTRIBUTE_PACKING and so gets the size wrong.  `lib/ipmi_sensor.c`
	 * only reads `type` out of it; the assertion keeps that honest.
	 */
	ABI_SIZEOF_sdr_get_rs = sizeof(struct sdr_get_rs),
	ABI_OFFSETOF_sdr_get_rs__next = offsetof(struct sdr_get_rs, next),
	ABI_OFFSETOF_sdr_get_rs__id = offsetof(struct sdr_get_rs, id),
	ABI_OFFSETOF_sdr_get_rs__version = offsetof(struct sdr_get_rs, version),
	ABI_OFFSETOF_sdr_get_rs__type = offsetof(struct sdr_get_rs, type),
	ABI_OFFSETOF_sdr_get_rs__length = offsetof(struct sdr_get_rs, length),

	/*
	 * struct sensor_set_thresh_rq - the eight byte Set Sensor Thresholds
	 * request body.  No bitfields, but it *is* inside a `#pragma pack'
	 * region, so the mirror needs checking like every other packed type.
	 */
	ABI_SIZEOF_sensor_set_thresh_rq = sizeof(struct sensor_set_thresh_rq),
	ABI_OFFSETOF_sensor_set_thresh_rq__sensor_num =
		offsetof(struct sensor_set_thresh_rq, sensor_num),
	ABI_OFFSETOF_sensor_set_thresh_rq__set_mask =
		offsetof(struct sensor_set_thresh_rq, set_mask),
	ABI_OFFSETOF_sensor_set_thresh_rq__lower_non_crit =
		offsetof(struct sensor_set_thresh_rq, lower_non_crit),
	ABI_OFFSETOF_sensor_set_thresh_rq__lower_crit =
		offsetof(struct sensor_set_thresh_rq, lower_crit),
	ABI_OFFSETOF_sensor_set_thresh_rq__lower_non_recov =
		offsetof(struct sensor_set_thresh_rq, lower_non_recov),
	ABI_OFFSETOF_sensor_set_thresh_rq__upper_non_crit =
		offsetof(struct sensor_set_thresh_rq, upper_non_crit),
	ABI_OFFSETOF_sensor_set_thresh_rq__upper_crit =
		offsetof(struct sensor_set_thresh_rq, upper_crit),
	ABI_OFFSETOF_sensor_set_thresh_rq__upper_non_recov =
		offsetof(struct sensor_set_thresh_rq, upper_non_recov),

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

	/* The rest of ipmi_sdr.h, for src/zig/cmd/sdr.zig.  That port mirrors
	 * every SDR record type in full rather than indexing a handful of byte
	 * offsets, because it reads nearly every field, so what it needs is one
	 * size per record plus the offsets of the fields that follow a bitfield
	 * group (bitfield members have no address of their own).
	 */
	ABI_SIZEOF_sdr_get_rq = sizeof(struct sdr_get_rq),
	ABI_OFFSETOF_sdr_get_rq__id = offsetof(struct sdr_get_rq, id),
	ABI_OFFSETOF_sdr_get_rq__offset = offsetof(struct sdr_get_rq, offset),
	ABI_OFFSETOF_sdr_get_rq__length = offsetof(struct sdr_get_rq, length),

	ABI_SIZEOF_sdr_repo_info_rs = sizeof(struct sdr_repo_info_rs),
	ABI_OFFSETOF_sdr_repo_info_rs__count =
		offsetof(struct sdr_repo_info_rs, count),
	ABI_OFFSETOF_sdr_repo_info_rs__free =
		offsetof(struct sdr_repo_info_rs, free),
	ABI_OFFSETOF_sdr_repo_info_rs__add_stamp =
		offsetof(struct sdr_repo_info_rs, add_stamp),
	ABI_OFFSETOF_sdr_repo_info_rs__erase_stamp =
		offsetof(struct sdr_repo_info_rs, erase_stamp),
	ABI_OFFSETOF_sdr_repo_info_rs__op_support =
		offsetof(struct sdr_repo_info_rs, op_support),

	ABI_SIZEOF_sdr_device_info_rs = sizeof(struct sdr_device_info_rs),
	ABI_OFFSETOF_sdr_device_info_rs__flags =
		offsetof(struct sdr_device_info_rs, flags),
	ABI_OFFSETOF_sdr_device_info_rs__popChangeInd =
		offsetof(struct sdr_device_info_rs, popChangeInd),

	ABI_SIZEOF_get_sdr_repository_info_rsp =
		sizeof(struct get_sdr_repository_info_rsp),
	ABI_OFFSETOF_get_sdr_repository_info_rsp__record_count_lsb =
		offsetof(struct get_sdr_repository_info_rsp, record_count_lsb),
	ABI_OFFSETOF_get_sdr_repository_info_rsp__record_count_msb =
		offsetof(struct get_sdr_repository_info_rsp, record_count_msb),
	ABI_OFFSETOF_get_sdr_repository_info_rsp__free_space =
		offsetof(struct get_sdr_repository_info_rsp, free_space),
	ABI_OFFSETOF_get_sdr_repository_info_rsp__most_recent_addition_timestamp =
		offsetof(struct get_sdr_repository_info_rsp,
			 most_recent_addition_timestamp),
	ABI_OFFSETOF_get_sdr_repository_info_rsp__most_recent_erase_timestamp =
		offsetof(struct get_sdr_repository_info_rsp,
			 most_recent_erase_timestamp),

	ABI_SIZEOF_sdr_record_mask = sizeof(struct sdr_record_mask),
	ABI_SIZEOF_sdr_record_common_sensor =
		sizeof(struct sdr_record_common_sensor),
	ABI_OFFSETOF_sdr_common__sensor__init =
		offsetof(struct sdr_record_common_sensor, sensor.type) - 2,
	ABI_OFFSETOF_sdr_common__mask =
		offsetof(struct sdr_record_common_sensor, mask),

	ABI_OFFSETOF_sdr_full__linearization =
		offsetof(struct sdr_record_full_sensor, linearization),
	ABI_OFFSETOF_sdr_full__analog_flag =
		offsetof(struct sdr_record_full_sensor, nominal_read) - 1,
	ABI_OFFSETOF_sdr_full__nominal_read =
		offsetof(struct sdr_record_full_sensor, nominal_read),
	ABI_OFFSETOF_sdr_full__normal_max =
		offsetof(struct sdr_record_full_sensor, normal_max),
	ABI_OFFSETOF_sdr_full__normal_min =
		offsetof(struct sdr_record_full_sensor, normal_min),
	ABI_OFFSETOF_sdr_full__sensor_max =
		offsetof(struct sdr_record_full_sensor, sensor_max),
	ABI_OFFSETOF_sdr_full__sensor_min =
		offsetof(struct sdr_record_full_sensor, sensor_min),
	ABI_OFFSETOF_sdr_full__threshold =
		offsetof(struct sdr_record_full_sensor, threshold),
	ABI_OFFSETOF_sdr_full__oem =
		offsetof(struct sdr_record_full_sensor, oem),
	ABI_OFFSETOF_sdr_full__id_code =
		offsetof(struct sdr_record_full_sensor, id_code),

	ABI_SIZEOF_sdr_record_compact_sensor =
		sizeof(struct sdr_record_compact_sensor),
	ABI_OFFSETOF_sdr_compact__share =
		offsetof(struct sdr_record_compact_sensor, share),
	ABI_OFFSETOF_sdr_compact__oem =
		offsetof(struct sdr_record_compact_sensor, oem),
	ABI_OFFSETOF_sdr_compact__id_code =
		offsetof(struct sdr_record_compact_sensor, id_code),

	ABI_SIZEOF_sdr_record_eventonly_sensor =
		sizeof(struct sdr_record_eventonly_sensor),
	ABI_OFFSETOF_sdr_eventonly__keys__sensor_num =
		offsetof(struct sdr_record_eventonly_sensor, keys.sensor_num),
	ABI_OFFSETOF_sdr_eventonly__sensor_type =
		offsetof(struct sdr_record_eventonly_sensor, sensor_type),
	ABI_OFFSETOF_sdr_eventonly__event_type =
		offsetof(struct sdr_record_eventonly_sensor, event_type),
	ABI_OFFSETOF_sdr_eventonly__share =
		offsetof(struct sdr_record_eventonly_sensor, share),
	ABI_OFFSETOF_sdr_eventonly__oem =
		offsetof(struct sdr_record_eventonly_sensor, oem),
	ABI_OFFSETOF_sdr_eventonly__id_code =
		offsetof(struct sdr_record_eventonly_sensor, id_code),

	ABI_SIZEOF_sdr_record_mc_locator = sizeof(struct sdr_record_mc_locator),
	ABI_OFFSETOF_sdr_mcloc__dev_support =
		offsetof(struct sdr_record_mc_locator, dev_support),
	ABI_OFFSETOF_sdr_mcloc__entity =
		offsetof(struct sdr_record_mc_locator, entity),
	ABI_OFFSETOF_sdr_mcloc__oem =
		offsetof(struct sdr_record_mc_locator, oem),
	ABI_OFFSETOF_sdr_mcloc__id_code =
		offsetof(struct sdr_record_mc_locator, id_code),

	ABI_SIZEOF_sdr_record_fru_locator =
		sizeof(struct sdr_record_fru_locator),
	ABI_OFFSETOF_sdr_fruloc__device_id =
		offsetof(struct sdr_record_fru_locator, device_id),
	ABI_OFFSETOF_sdr_fruloc__dev_type =
		offsetof(struct sdr_record_fru_locator, dev_type),
	ABI_OFFSETOF_sdr_fruloc__dev_type_modifier =
		offsetof(struct sdr_record_fru_locator, dev_type_modifier),
	ABI_OFFSETOF_sdr_fruloc__entity =
		offsetof(struct sdr_record_fru_locator, entity),
	ABI_OFFSETOF_sdr_fruloc__oem =
		offsetof(struct sdr_record_fru_locator, oem),
	ABI_OFFSETOF_sdr_fruloc__id_code =
		offsetof(struct sdr_record_fru_locator, id_code),

	ABI_SIZEOF_sdr_record_generic_locator =
		sizeof(struct sdr_record_generic_locator),
	ABI_OFFSETOF_sdr_genloc__dev_slave_addr =
		offsetof(struct sdr_record_generic_locator, dev_slave_addr),
	ABI_OFFSETOF_sdr_genloc__dev_type =
		offsetof(struct sdr_record_generic_locator, dev_type),
	ABI_OFFSETOF_sdr_genloc__dev_type_modifier =
		offsetof(struct sdr_record_generic_locator, dev_type_modifier),
	ABI_OFFSETOF_sdr_genloc__entity =
		offsetof(struct sdr_record_generic_locator, entity),
	ABI_OFFSETOF_sdr_genloc__oem =
		offsetof(struct sdr_record_generic_locator, oem),
	ABI_OFFSETOF_sdr_genloc__id_code =
		offsetof(struct sdr_record_generic_locator, id_code),

	ABI_SIZEOF_sdr_record_entity_assoc =
		sizeof(struct sdr_record_entity_assoc),
	ABI_OFFSETOF_sdr_entassoc__entity_id_1 =
		offsetof(struct sdr_record_entity_assoc, entity_id_1),
	ABI_OFFSETOF_sdr_entassoc__entity_inst_4 =
		offsetof(struct sdr_record_entity_assoc, entity_inst_4),

	ABI_SIZEOF_sdr_record_oem = sizeof(struct sdr_record_oem),
	ABI_ALIGNOF_sdr_record_oem = _Alignof(struct sdr_record_oem),
	ABI_OFFSETOF_sdr_record_oem__data_len =
		offsetof(struct sdr_record_oem, data_len),

	ABI_SIZEOF_ipmi_sdr_iterator = sizeof(struct ipmi_sdr_iterator),
	ABI_ALIGNOF_ipmi_sdr_iterator = _Alignof(struct ipmi_sdr_iterator),
	ABI_OFFSETOF_ipmi_sdr_iterator__total =
		offsetof(struct ipmi_sdr_iterator, total),
	ABI_OFFSETOF_ipmi_sdr_iterator__next =
		offsetof(struct ipmi_sdr_iterator, next),
	ABI_OFFSETOF_ipmi_sdr_iterator__use_built_in =
		offsetof(struct ipmi_sdr_iterator, use_built_in),

	ABI_SIZEOF_sensor_reading = sizeof(struct sensor_reading),
	ABI_ALIGNOF_sensor_reading = _Alignof(struct sensor_reading),
	ABI_OFFSETOF_sensor_reading__full = offsetof(struct sensor_reading, full),
	ABI_OFFSETOF_sensor_reading__compact =
		offsetof(struct sensor_reading, compact),
	ABI_OFFSETOF_sensor_reading__s_reading_valid =
		offsetof(struct sensor_reading, s_reading_valid),
	ABI_OFFSETOF_sensor_reading__s_reading =
		offsetof(struct sensor_reading, s_reading),
	ABI_OFFSETOF_sensor_reading__s_has_analog_value =
		offsetof(struct sensor_reading, s_has_analog_value),
	ABI_OFFSETOF_sensor_reading__s_a_val =
		offsetof(struct sensor_reading, s_a_val),
	ABI_OFFSETOF_sensor_reading__s_a_str =
		offsetof(struct sensor_reading, s_a_str),
	ABI_OFFSETOF_sensor_reading__s_a_units =
		offsetof(struct sensor_reading, s_a_units),

	/* struct get_channel_auth_cap_rsp - opaque: bytes 1-3 are all bitfields.
	 * Only three offsets are addressable; the bitfield bytes are pinned by
	 * the fields on either side of them.
	 */
	ABI_SIZEOF_get_channel_auth_cap_rsp =
		sizeof(struct get_channel_auth_cap_rsp),
	ABI_ALIGNOF_get_channel_auth_cap_rsp =
		_Alignof(struct get_channel_auth_cap_rsp),
	ABI_OFFSETOF_get_channel_auth_cap_rsp__channel_number =
		offsetof(struct get_channel_auth_cap_rsp, channel_number),
	ABI_OFFSETOF_get_channel_auth_cap_rsp__oem_id =
		offsetof(struct get_channel_auth_cap_rsp, oem_id),
	ABI_OFFSETOF_get_channel_auth_cap_rsp__oem_aux_data =
		offsetof(struct get_channel_auth_cap_rsp, oem_aux_data),

	/* The two cipher suite records are inside a `#pragma pack' region, which
	 * translate-c silently ignores.  Both happen to be all-uint8_t so the
	 * packed and unpacked layouts agree, but the port reads them byte by byte
	 * and only needs their sizes, which the parser compares against the
	 * remaining data length.
	 */
	ABI_SIZEOF_std_cipher_suite_record =
		sizeof(struct std_cipher_suite_record_t),
	ABI_SIZEOF_oem_cipher_suite_record =
		sizeof(struct oem_cipher_suite_record_t),
	ABI_OFFSETOF_oem_cipher_suite_record__iana =
		offsetof(struct oem_cipher_suite_record_t, iana),
	ABI_OFFSETOF_oem_cipher_suite_record__auth_alg =
		offsetof(struct oem_cipher_suite_record_t, auth_alg),

	/*
	 * struct sockaddr_in6 - not opaque, but `s6_addr` is a *macro* naming a
	 * member of an anonymous union inside `struct in6_addr`, and the union
	 * member is spelled differently by every libc (`__in6_u.__u6_addr8` on
	 * glibc, `__in6_union.__s6_addr` on musl).  `translate-c` cannot follow
	 * the macro, so `src/zig/intf/registry.zig` uses `std.posix.sockaddr.in6`
	 * — which Zig defines per target, including the BSD `sin6_len` byte — and
	 * pins it against these numbers instead.  The offsets still come from the
	 * C compiler for the real target, so the check is as strong as a direct
	 * comparison would have been.
	 */
	ABI_SIZEOF_sockaddr_in6 = sizeof(struct sockaddr_in6),
	ABI_ALIGNOF_sockaddr_in6 = _Alignof(struct sockaddr_in6),
	ABI_OFFSETOF_sockaddr_in6__sin6_family =
		offsetof(struct sockaddr_in6, sin6_family),
	ABI_OFFSETOF_sockaddr_in6__sin6_port =
		offsetof(struct sockaddr_in6, sin6_port),
	ABI_OFFSETOF_sockaddr_in6__sin6_flowinfo =
		offsetof(struct sockaddr_in6, sin6_flowinfo),
	ABI_OFFSETOF_sockaddr_in6__sin6_addr =
		offsetof(struct sockaddr_in6, sin6_addr),
	ABI_OFFSETOF_sockaddr_in6__sin6_scope_id =
		offsetof(struct sockaddr_in6, sin6_scope_id),
};
