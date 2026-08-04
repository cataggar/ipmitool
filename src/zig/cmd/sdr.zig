//! Port of `lib/ipmi_sdr.c` and `lib/ipmi_sdradd.c`: the `sdr` command, the
//! Sensor Data Record repository iterator and cache, the record printers, and
//! the reading-conversion math (`sdr_convert_sensor_reading()` and friends)
//! that `lib/ipmi_sensor.c`, `lib/ipmi_sel.c`, `lib/ipmi_fru.c`,
//! `lib/ipmi_dcmi.c`, `lib/ipmi_picmg.c` and several transports link against.
//!
//! Selected with `zig build -Dzig-modules=sdr`, which drops both C files from
//! the compile and links this module instead.
//!
//! Things worth knowing before reading on:
//!
//! * **Fifty-one symbols cross the ABI**, forty-six from `lib/ipmi_sdr.c` and
//!   five from `lib/ipmi_sdradd.c`.  This is by far the widest seam in the
//!   tree: `ipmi_sdr.c` is the shared decoding substrate, so `ipmi_sensor`
//!   and `ipmi_sel` - already ported - call *into* this module, and the
//!   `sen_*` and `sl_*` golden snapshots are the regression net that proves
//!   the ground did not move underneath them.
//!
//! * **Every SDR record type lives inside a `#pragma pack` region**, which
//!   `translate-c` silently ignores (see doc/zig-migration/interop-seams.md).
//!   So all of them get hand written `align(1)` mirrors here, checked against
//!   `abi_layout.h` with `abi.assertOpaqueLayout()`.  Nothing in this file
//!   reads an SDR record through a `translate-c` type.
//!
//! * **The M/B/exponent math is bit-exact.**  `__TO_M`, `__TO_B`, `__TO_ACC`,
//!   `__TO_ACC_EXP`, `__TO_R_EXP`, `__TO_B_EXP` and `tos32()` are macros that
//!   byte-swap a little endian field and then sign extend a 10- or 4-bit
//!   two's complement value.  They are ported as functions with the same
//!   intermediate widths: `tos32()` operates in `int`, and the M and B fields
//!   are 10 bits wide with their top two bits carried in a *different* byte.
//!
//! * **Upstream defects are reproduced deliberately** - see issue #50.
//!
//! * **The exports are gathered in `exportSymbols()`**, which
//!   `src/zig/exports.zig` invokes at comptime only when `sdr` is selected.
//!
//! Allocation: `malloc`/`calloc`/`realloc`/`free` through the bridge, because
//! the SDR cache is walked and freed by C code in `lib/ipmi_sensor.c`,
//! `lib/ipmi_fru.c` and `lib/ipmi_sdradd.c`.

const std = @import("std");
const builtin = @import("builtin");

const c = @import("ipmi_c");
const abi = @import("../abi.zig");
const ipmi = @import("../core/ipmi.zig");
const intf_mod = @import("../intf/intf.zig");

const Intf = intf_mod.Intf;
const Request = ipmi.Request;
const Response = ipmi.Response;

const endian = builtin.target.cpu.arch.endian();

const netfn_se: u6 = @intCast(c.IPMI_NETFN_SE);
const netfn_storage: u6 = @intCast(c.IPMI_NETFN_STORAGE);

// ---------------------------------------------------------------------------
// SDR record mirrors
//
// Every struct below is inside a `#pragma pack(push, 1)` region in
// `include/ipmitool/ipmi_sdr.h`, so `translate-c` reports the wrong offsets
// for it.  Each mirror uses `align(1)` fields and is pinned against
// `abi_layout.h` at the bottom of the file.
//
// Bitfield groups are `packed struct`es.  C allocates bitfields from the least
// significant bit on little endian targets and from the most significant bit
// on big endian ones, while a Zig packed struct always starts at the least
// significant bit, so each group is declared in target order - exactly as
// `src/zig/core/ipmi.zig` does for `netfn`/`lun`.
// ---------------------------------------------------------------------------

/// `struct entity_id` (`include/ipmitool/ipmi_entity.h`).
const EntityId = extern struct {
    id: u8 = 0,
    instance: packed struct(u8) {
        instance: u7 = 0,
        logical: u1 = 0,
    } = .{},
};

/// `struct sdr_get_rs`: the five byte SDR record header.
const SdrGetRs = extern struct {
    next: u16 align(1) = 0,
    id: u16 align(1) = 0,
    version: u8 = 0,
    type: u8 = 0,
    length: u8 = 0,
};

/// `struct sdr_get_rq`: the Get SDR request body.
const SdrGetRq = extern struct {
    reserve_id: u16 align(1) = 0,
    id: u16 align(1) = 0,
    offset: u8 = 0,
    length: u8 = 0,
};

/// `struct sdr_repo_info_rs`: the Get SDR Repository Info reply.
const SdrRepoInfoRs = extern struct {
    version: u8 = 0,
    count: u16 align(1) = 0,
    free: u16 align(1) = 0,
    add_stamp: u32 align(1) = 0,
    erase_stamp: u32 align(1) = 0,
    op_support: u8 = 0,
};

/// `struct sdr_device_info_rs`: the Get Device SDR Info reply.
const SdrDeviceInfoRs = extern struct {
    count: u8 = 0,
    flags: u8 = 0,
    popChangeInd: [3]u8 = @splat(0),
};

/// The first word of the threshold arm of `struct sdr_record_mask`.
const MaskAssert = switch (endian) {
    .little => packed struct(u16) {
        assert_lnc_low: u1 = 0,
        assert_lnc_high: u1 = 0,
        assert_lcr_low: u1 = 0,
        assert_lcr_high: u1 = 0,
        assert_lnr_low: u1 = 0,
        assert_lnr_high: u1 = 0,
        assert_unc_low: u1 = 0,
        assert_unc_high: u1 = 0,
        assert_ucr_low: u1 = 0,
        assert_ucr_high: u1 = 0,
        assert_unr_low: u1 = 0,
        assert_unr_high: u1 = 0,
        status_lnc: u1 = 0,
        status_lcr: u1 = 0,
        status_lnr: u1 = 0,
        reserved: u1 = 0,
    },
    .big => packed struct(u16) {
        reserved: u1 = 0,
        status_lnr: u1 = 0,
        status_lcr: u1 = 0,
        status_lnc: u1 = 0,
        assert_unr_high: u1 = 0,
        assert_unr_low: u1 = 0,
        assert_ucr_high: u1 = 0,
        assert_ucr_low: u1 = 0,
        assert_unc_high: u1 = 0,
        assert_unc_low: u1 = 0,
        assert_lnr_high: u1 = 0,
        assert_lnr_low: u1 = 0,
        assert_lcr_high: u1 = 0,
        assert_lcr_low: u1 = 0,
        assert_lnc_high: u1 = 0,
        assert_lnc_low: u1 = 0,
    },
};

/// The second word of the threshold arm of `struct sdr_record_mask`.
const MaskDeassert = switch (endian) {
    .little => packed struct(u16) {
        deassert_lnc_low: u1 = 0,
        deassert_lnc_high: u1 = 0,
        deassert_lcr_low: u1 = 0,
        deassert_lcr_high: u1 = 0,
        deassert_lnr_low: u1 = 0,
        deassert_lnr_high: u1 = 0,
        deassert_unc_low: u1 = 0,
        deassert_unc_high: u1 = 0,
        deassert_ucr_low: u1 = 0,
        deassert_ucr_high: u1 = 0,
        deassert_unr_low: u1 = 0,
        deassert_unr_high: u1 = 0,
        status_unc: u1 = 0,
        status_ucr: u1 = 0,
        status_unr: u1 = 0,
        reserved_2: u1 = 0,
    },
    .big => packed struct(u16) {
        reserved_2: u1 = 0,
        status_unr: u1 = 0,
        status_ucr: u1 = 0,
        status_unc: u1 = 0,
        deassert_unr_high: u1 = 0,
        deassert_unr_low: u1 = 0,
        deassert_ucr_high: u1 = 0,
        deassert_ucr_low: u1 = 0,
        deassert_unc_high: u1 = 0,
        deassert_unc_low: u1 = 0,
        deassert_lnr_high: u1 = 0,
        deassert_lnr_low: u1 = 0,
        deassert_lcr_high: u1 = 0,
        deassert_lcr_low: u1 = 0,
        deassert_lnc_high: u1 = 0,
        deassert_lnc_low: u1 = 0,
    },
};

/// The settable-threshold view of the third word of `struct sdr_record_mask`.
const MaskSet = switch (endian) {
    .little => packed struct(u16) {
        readable: u8 = 0,
        lnc: u1 = 0,
        lcr: u1 = 0,
        lnr: u1 = 0,
        unc: u1 = 0,
        ucr: u1 = 0,
        unr: u1 = 0,
        reserved: u2 = 0,
    },
    .big => packed struct(u16) {
        reserved: u2 = 0,
        unr: u1 = 0,
        ucr: u1 = 0,
        unc: u1 = 0,
        lnr: u1 = 0,
        lcr: u1 = 0,
        lnc: u1 = 0,
        readable: u8 = 0,
    },
};

/// The readable-threshold view of the third word of `struct sdr_record_mask`.
const MaskRead = switch (endian) {
    .little => packed struct(u16) {
        lnc: u1 = 0,
        lcr: u1 = 0,
        lnr: u1 = 0,
        unc: u1 = 0,
        ucr: u1 = 0,
        unr: u1 = 0,
        reserved: u2 = 0,
        settable: u8 = 0,
    },
    .big => packed struct(u16) {
        settable: u8 = 0,
        reserved: u2 = 0,
        unr: u1 = 0,
        ucr: u1 = 0,
        unc: u1 = 0,
        lnr: u1 = 0,
        lcr: u1 = 0,
        lnc: u1 = 0,
    },
};

/// `struct sdr_record_mask`: six bytes read three different ways.  The C is a
/// union of a discrete view and a threshold view; the mirror keeps the raw
/// words and offers the same three readings as accessors, which is exactly
/// what the union does at the byte level.
const SdrRecordMask = extern struct {
    w0: u16 align(1) = 0,
    w1: u16 align(1) = 0,
    w2: u16 align(1) = 0,

    /// `mask.type.discrete.assert_event`
    fn assertEvent(self: *const SdrRecordMask) u16 {
        return self.w0;
    }
    /// `mask.type.discrete.deassert_event`
    fn deassertEvent(self: *const SdrRecordMask) u16 {
        return self.w1;
    }
    /// `mask.type.discrete.read`
    fn readMask(self: *const SdrRecordMask) u16 {
        return self.w2;
    }
    /// `mask.type.threshold.assert_*` / `status_*`
    fn assertBits(self: *const SdrRecordMask) MaskAssert {
        return @bitCast(self.w0);
    }
    /// `mask.type.threshold.deassert_*` / `status_*`
    fn deassertBits(self: *const SdrRecordMask) MaskDeassert {
        return @bitCast(self.w1);
    }
    /// `mask.type.threshold.set`
    fn setBits(self: *const SdrRecordMask) MaskSet {
        return @bitCast(self.w2);
    }
    /// `mask.type.threshold.read`
    fn readBits(self: *const SdrRecordMask) MaskRead {
        return @bitCast(self.w2);
    }
};

/// `struct sdr_record_common_sensor`: the 18 byte prefix every sensor record
/// shares.  The C freely casts a full or compact record to this type.
const CommonSensor = extern struct {
    keys: extern struct {
        owner_id: u8 = 0,
        flags: switch (endian) {
            .little => packed struct(u8) {
                lun: u2 = 0,
                __reserved: u2 = 0,
                channel: u4 = 0,
            },
            .big => packed struct(u8) {
                channel: u4 = 0,
                __reserved: u2 = 0,
                lun: u2 = 0,
            },
        } = .{},
        sensor_num: u8 = 0,
    } = .{},

    entity: EntityId = .{},

    sensor: extern struct {
        init: switch (endian) {
            .little => packed struct(u8) {
                sensor_scan: u1 = 0,
                event_gen: u1 = 0,
                type: u1 = 0,
                hysteresis: u1 = 0,
                thresholds: u1 = 0,
                events: u1 = 0,
                scanning: u1 = 0,
                __reserved: u1 = 0,
            },
            .big => packed struct(u8) {
                __reserved: u1 = 0,
                scanning: u1 = 0,
                events: u1 = 0,
                thresholds: u1 = 0,
                hysteresis: u1 = 0,
                type: u1 = 0,
                event_gen: u1 = 0,
                sensor_scan: u1 = 0,
            },
        } = .{},
        capabilities: switch (endian) {
            .little => packed struct(u8) {
                event_msg: u2 = 0,
                threshold: u2 = 0,
                hysteresis: u2 = 0,
                rearm: u1 = 0,
                ignore: u1 = 0,
            },
            .big => packed struct(u8) {
                ignore: u1 = 0,
                rearm: u1 = 0,
                hysteresis: u2 = 0,
                threshold: u2 = 0,
                event_msg: u2 = 0,
            },
        } = .{},
        type: u8 = 0,
    } = .{},

    event_type: u8 = 0,

    mask: SdrRecordMask align(1) = .{},

    unit: extern struct {
        flags: switch (endian) {
            .little => packed struct(u8) {
                pct: u1 = 0,
                modifier: u2 = 0,
                rate: u3 = 0,
                analog: u2 = 0,
            },
            .big => packed struct(u8) {
                analog: u2 = 0,
                rate: u3 = 0,
                modifier: u2 = 0,
                pct: u1 = 0,
            },
        } = .{},
        type: extern struct {
            base: u8 = 0,
            modifier: u8 = 0,
        } = .{},
    } = .{},
};

/// The `share` byte pair of a compact or event-only record.
const ShareBytes = extern struct {
    a: switch (endian) {
        .little => packed struct(u8) {
            count: u4 = 0,
            mod_type: u2 = 0,
            __reserved: u2 = 0,
        },
        .big => packed struct(u8) {
            __reserved: u2 = 0,
            mod_type: u2 = 0,
            count: u4 = 0,
        },
    } = .{},
    b: switch (endian) {
        .little => packed struct(u8) {
            mod_offset: u7 = 0,
            entity_inst: u1 = 0,
        },
        .big => packed struct(u8) {
            entity_inst: u1 = 0,
            mod_offset: u7 = 0,
        },
    } = .{},
};

/// `struct sdr_record_full_sensor`.
const FullSensor = extern struct {
    cmn: CommonSensor align(1) = .{},
    linearization: u8 = 0,
    mtol: u16 align(1) = 0,
    bacc: u32 align(1) = 0,
    analog_flag: switch (endian) {
        .little => packed struct(u8) {
            nominal_read: u1 = 0,
            normal_max: u1 = 0,
            normal_min: u1 = 0,
            __reserved: u5 = 0,
        },
        .big => packed struct(u8) {
            __reserved: u5 = 0,
            normal_min: u1 = 0,
            normal_max: u1 = 0,
            nominal_read: u1 = 0,
        },
    } = .{},
    nominal_read: u8 = 0,
    normal_max: u8 = 0,
    normal_min: u8 = 0,
    sensor_max: u8 = 0,
    sensor_min: u8 = 0,
    threshold: extern struct {
        upper: extern struct {
            non_recover: u8 = 0,
            critical: u8 = 0,
            non_critical: u8 = 0,
        } = .{},
        lower: extern struct {
            non_recover: u8 = 0,
            critical: u8 = 0,
            non_critical: u8 = 0,
        } = .{},
        hysteresis: extern struct {
            positive: u8 = 0,
            negative: u8 = 0,
        } = .{},
    } = .{},
    __reserved: [2]u8 = @splat(0),
    oem: u8 = 0,
    id_code: u8 = 0,
    id_string: [16]u8 = @splat(0),
};

/// `struct sdr_record_compact_sensor`.
const CompactSensor = extern struct {
    cmn: CommonSensor align(1) = .{},
    share: ShareBytes align(1) = .{},
    threshold: extern struct {
        hysteresis: extern struct {
            positive: u8 = 0,
            negative: u8 = 0,
        } = .{},
    } = .{},
    __reserved: [3]u8 = @splat(0),
    oem: u8 = 0,
    id_code: u8 = 0,
    id_string: [16]u8 = @splat(0),
};

/// `struct sdr_record_eventonly_sensor`.  Note the `keys` bitfield differs
/// from the common record's: the middle two bits are `fru_owner`, not padding.
const EventonlySensor = extern struct {
    keys: extern struct {
        owner_id: u8 = 0,
        flags: switch (endian) {
            .little => packed struct(u8) {
                lun: u2 = 0,
                fru_owner: u2 = 0,
                channel: u4 = 0,
            },
            .big => packed struct(u8) {
                channel: u4 = 0,
                fru_owner: u2 = 0,
                lun: u2 = 0,
            },
        } = .{},
        sensor_num: u8 = 0,
    } = .{},
    entity: EntityId = .{},
    sensor_type: u8 = 0,
    event_type: u8 = 0,
    share: ShareBytes align(1) = .{},
    __reserved: u8 = 0,
    oem: u8 = 0,
    id_code: u8 = 0,
    id_string: [16]u8 = @splat(0),
};

/// `struct sdr_record_mc_locator`.
const McLocator = extern struct {
    dev_slave_addr: u8 = 0,
    chan: switch (endian) {
        .little => packed struct(u8) {
            channel_num: u4 = 0,
            __reserved2: u4 = 0,
        },
        .big => packed struct(u8) {
            __reserved2: u4 = 0,
            channel_num: u4 = 0,
        },
    } = .{},
    power: switch (endian) {
        .little => packed struct(u8) {
            global_init: u4 = 0,
            __reserved3: u1 = 0,
            pwr_state_notif: u3 = 0,
        },
        .big => packed struct(u8) {
            pwr_state_notif: u3 = 0,
            __reserved3: u1 = 0,
            global_init: u4 = 0,
        },
    } = .{},
    dev_support: u8 = 0,
    __reserved4: [3]u8 = @splat(0),
    entity: EntityId = .{},
    oem: u8 = 0,
    id_code: u8 = 0,
    id_string: [16]u8 = @splat(0),
};

/// `struct sdr_record_fru_locator`.
const FruLocator = extern struct {
    dev_slave_addr: u8 = 0,
    device_id: u8 = 0,
    access: switch (endian) {
        .little => packed struct(u8) {
            bus: u3 = 0,
            lun: u2 = 0,
            __reserved2: u2 = 0,
            logical: u1 = 0,
        },
        .big => packed struct(u8) {
            logical: u1 = 0,
            __reserved2: u2 = 0,
            lun: u2 = 0,
            bus: u3 = 0,
        },
    } = .{},
    chan: switch (endian) {
        .little => packed struct(u8) {
            __reserved3: u4 = 0,
            channel_num: u4 = 0,
        },
        .big => packed struct(u8) {
            channel_num: u4 = 0,
            __reserved3: u4 = 0,
        },
    } = .{},
    __reserved4: u8 = 0,
    dev_type: u8 = 0,
    dev_type_modifier: u8 = 0,
    entity: EntityId = .{},
    oem: u8 = 0,
    id_code: u8 = 0,
    id_string: [16]u8 = @splat(0),
};

/// `struct sdr_record_generic_locator`.
const GenericLocator = extern struct {
    dev_access_addr: u8 = 0,
    dev_slave_addr: u8 = 0,
    access: switch (endian) {
        .little => packed struct(u8) {
            bus: u3 = 0,
            lun: u2 = 0,
            channel_num: u3 = 0,
        },
        .big => packed struct(u8) {
            channel_num: u3 = 0,
            lun: u2 = 0,
            bus: u3 = 0,
        },
    } = .{},
    span: switch (endian) {
        .little => packed struct(u8) {
            __reserved1: u5 = 0,
            addr_span: u3 = 0,
        },
        .big => packed struct(u8) {
            addr_span: u3 = 0,
            __reserved1: u5 = 0,
        },
    } = .{},
    __reserved2: u8 = 0,
    dev_type: u8 = 0,
    dev_type_modifier: u8 = 0,
    entity: EntityId = .{},
    oem: u8 = 0,
    id_code: u8 = 0,
    id_string: [16]u8 = @splat(0),
};

/// `struct sdr_record_entity_assoc`.
const EntityAssoc = extern struct {
    entity: EntityId = .{},
    flags: switch (endian) {
        .little => packed struct(u8) {
            __reserved: u5 = 0,
            isaccessable: u1 = 0,
            islinked: u1 = 0,
            isrange: u1 = 0,
        },
        .big => packed struct(u8) {
            isrange: u1 = 0,
            islinked: u1 = 0,
            isaccessable: u1 = 0,
            __reserved: u5 = 0,
        },
    } = .{},
    entity_id_1: u8 = 0,
    entity_inst_1: u8 = 0,
    entity_id_2: u8 = 0,
    entity_inst_2: u8 = 0,
    entity_id_3: u8 = 0,
    entity_inst_3: u8 = 0,
    entity_id_4: u8 = 0,
    entity_inst_4: u8 = 0,
};

/// `struct sdr_record_oem`.  Outside the `#pragma pack` region, so this is a
/// plain natural-alignment struct exactly as C sees it.
const SdrRecordOem = extern struct {
    data: ?[*]u8 = null,
    data_len: c_int = 0,
};

/// `struct sdr_record_list`.  `translate-c` produces a type for this one but
/// drops the packing, putting `record` at offset 24 instead of 21.
const SdrRecordList = extern struct {
    id: u16 align(1) = 0,
    version: u8 = 0,
    type: u8 = 0,
    length: u8 = 0,
    raw: ?[*]u8 align(1) = null,
    next: ?*SdrRecordList align(1) = null,
    /// The C `record` union; every arm is a pointer to one of the mirrors
    /// above, so a single untyped pointer represents all nine.
    record: ?*anyopaque align(1) = null,

    fn common(self: *const SdrRecordList) *CommonSensor {
        return @ptrCast(@alignCast(self.record.?));
    }
    fn full(self: *const SdrRecordList) *FullSensor {
        return @ptrCast(@alignCast(self.record.?));
    }
    fn compact(self: *const SdrRecordList) *CompactSensor {
        return @ptrCast(@alignCast(self.record.?));
    }
    fn eventonly(self: *const SdrRecordList) *EventonlySensor {
        return @ptrCast(@alignCast(self.record.?));
    }
    fn genloc(self: *const SdrRecordList) *GenericLocator {
        return @ptrCast(@alignCast(self.record.?));
    }
    fn fruloc(self: *const SdrRecordList) *FruLocator {
        return @ptrCast(@alignCast(self.record.?));
    }
    fn mcloc(self: *const SdrRecordList) *McLocator {
        return @ptrCast(@alignCast(self.record.?));
    }
    fn entassoc(self: *const SdrRecordList) *EntityAssoc {
        return @ptrCast(@alignCast(self.record.?));
    }
    fn oem(self: *const SdrRecordList) *SdrRecordOem {
        return @ptrCast(@alignCast(self.record.?));
    }
};

/// `struct ipmi_sdr_iterator`.  Outside the `#pragma pack` region.
const SdrIterator = extern struct {
    reservation: u16 = 0,
    total: c_int = 0,
    next: c_int = 0,
    use_built_in: c_int = 0,
};

/// `struct sensor_reading`.  Outside the `#pragma pack` region; the mirror
/// exists only so the port can spell the field names.
const SensorReading = extern struct {
    s_id: [17]u8 = @splat(0),
    full: ?*FullSensor = null,
    compact: ?*CompactSensor = null,
    s_reading_valid: u8 = 0,
    s_scanning_disabled: u8 = 0,
    s_reading_unavailable: u8 = 0,
    s_reading: u8 = 0,
    s_data2: u8 = 0,
    s_data3: u8 = 0,
    s_has_analog_value: u8 = 0,
    s_a_val: f64 = 0,
    s_a_str: [16]u8 = @splat(0),
    s_a_units: ?[*:0]const u8 = null,
};

// ---------------------------------------------------------------------------
// Layout assertions
//
// Every number below comes from `abi_layout.h`, i.e. from the C compiler
// building for the same target, so these stay correct when cross compiling and
// under either `HAVE_PRAGMA_PACK` setting.  Bitfield members have no address,
// so each group is pinned by the offset of the field that follows it.
// ---------------------------------------------------------------------------

comptime {
    @setEvalBranchQuota(20000);
    abi.assertOpaqueLayout(SdrGetRs, .{
        .size = c.ABI_SIZEOF_sdr_get_rs,
        .alignment = 1,
        .fields = &.{
            .{ .name = "next", .offset = c.ABI_OFFSETOF_sdr_get_rs__next },
            .{ .name = "id", .offset = c.ABI_OFFSETOF_sdr_get_rs__id },
            .{ .name = "version", .offset = c.ABI_OFFSETOF_sdr_get_rs__version },
            .{ .name = "type", .offset = c.ABI_OFFSETOF_sdr_get_rs__type },
            .{ .name = "length", .offset = c.ABI_OFFSETOF_sdr_get_rs__length },
        },
    });
    abi.assertOpaqueLayout(SdrGetRq, .{
        .size = c.ABI_SIZEOF_sdr_get_rq,
        .alignment = 1,
        .fields = &.{
            .{ .name = "id", .offset = c.ABI_OFFSETOF_sdr_get_rq__id },
            .{ .name = "offset", .offset = c.ABI_OFFSETOF_sdr_get_rq__offset },
            .{ .name = "length", .offset = c.ABI_OFFSETOF_sdr_get_rq__length },
        },
    });
    abi.assertOpaqueLayout(SdrRepoInfoRs, .{
        .size = c.ABI_SIZEOF_sdr_repo_info_rs,
        .alignment = 1,
        .fields = &.{
            .{ .name = "count", .offset = c.ABI_OFFSETOF_sdr_repo_info_rs__count },
            .{ .name = "free", .offset = c.ABI_OFFSETOF_sdr_repo_info_rs__free },
            .{ .name = "add_stamp", .offset = c.ABI_OFFSETOF_sdr_repo_info_rs__add_stamp },
            .{ .name = "erase_stamp", .offset = c.ABI_OFFSETOF_sdr_repo_info_rs__erase_stamp },
            .{ .name = "op_support", .offset = c.ABI_OFFSETOF_sdr_repo_info_rs__op_support },
        },
    });
    abi.assertOpaqueLayout(SdrDeviceInfoRs, .{
        .size = c.ABI_SIZEOF_sdr_device_info_rs,
        .alignment = 1,
        .fields = &.{
            .{ .name = "flags", .offset = c.ABI_OFFSETOF_sdr_device_info_rs__flags },
            .{ .name = "popChangeInd", .offset = c.ABI_OFFSETOF_sdr_device_info_rs__popChangeInd },
        },
    });
    abi.assertOpaqueLayout(SdrRecordMask, .{
        .size = c.ABI_SIZEOF_sdr_record_mask,
        .alignment = 1,
        .fields = &.{},
    });
    abi.assertOpaqueLayout(CommonSensor, .{
        .size = c.ABI_SIZEOF_sdr_record_common_sensor,
        .alignment = 1,
        .fields = &.{
            .{ .name = "keys.owner_id", .offset = c.ABI_OFFSETOF_sdr_common__keys__owner_id },
            .{ .name = "keys.flags", .offset = c.ABI_OFFSETOF_sdr_common__keys__flags },
            .{ .name = "keys.sensor_num", .offset = c.ABI_OFFSETOF_sdr_common__keys__sensor_num },
            .{ .name = "entity.id", .offset = c.ABI_OFFSETOF_sdr_common__entity__id },
            .{ .name = "entity.instance", .offset = c.ABI_OFFSETOF_sdr_common__entity__instance },
            .{ .name = "sensor.init", .offset = c.ABI_OFFSETOF_sdr_common__sensor__init },
            .{ .name = "sensor.type", .offset = c.ABI_OFFSETOF_sdr_common__sensor__type },
            .{ .name = "event_type", .offset = c.ABI_OFFSETOF_sdr_common__event_type },
            .{ .name = "mask", .offset = c.ABI_OFFSETOF_sdr_common__mask },
            .{ .name = "unit.flags", .offset = c.ABI_OFFSETOF_sdr_common__unit },
            .{ .name = "unit.type.base", .offset = c.ABI_OFFSETOF_sdr_common__unit__type__base },
            .{ .name = "unit.type.modifier", .offset = c.ABI_OFFSETOF_sdr_common__unit__type__modifier },
        },
    });
    abi.assertOpaqueLayout(FullSensor, .{
        .size = c.ABI_SIZEOF_sdr_record_full_sensor,
        .alignment = 1,
        .fields = &.{
            .{ .name = "linearization", .offset = c.ABI_OFFSETOF_sdr_full__linearization },
            .{ .name = "mtol", .offset = c.ABI_OFFSETOF_sdr_full__mtol },
            .{ .name = "bacc", .offset = c.ABI_OFFSETOF_sdr_full__bacc },
            .{ .name = "analog_flag", .offset = c.ABI_OFFSETOF_sdr_full__analog_flag },
            .{ .name = "nominal_read", .offset = c.ABI_OFFSETOF_sdr_full__nominal_read },
            .{ .name = "normal_max", .offset = c.ABI_OFFSETOF_sdr_full__normal_max },
            .{ .name = "normal_min", .offset = c.ABI_OFFSETOF_sdr_full__normal_min },
            .{ .name = "sensor_max", .offset = c.ABI_OFFSETOF_sdr_full__sensor_max },
            .{ .name = "sensor_min", .offset = c.ABI_OFFSETOF_sdr_full__sensor_min },
            .{ .name = "threshold", .offset = c.ABI_OFFSETOF_sdr_full__threshold },
            .{ .name = "threshold.hysteresis.positive", .offset = c.ABI_OFFSETOF_sdr_full__hysteresis__positive },
            .{ .name = "threshold.hysteresis.negative", .offset = c.ABI_OFFSETOF_sdr_full__hysteresis__negative },
            .{ .name = "oem", .offset = c.ABI_OFFSETOF_sdr_full__oem },
            .{ .name = "id_code", .offset = c.ABI_OFFSETOF_sdr_full__id_code },
            .{ .name = "id_string", .offset = c.ABI_OFFSETOF_sdr_full__id_string },
        },
    });
    abi.assertOpaqueLayout(CompactSensor, .{
        .size = c.ABI_SIZEOF_sdr_record_compact_sensor,
        .alignment = 1,
        .fields = &.{
            .{ .name = "share", .offset = c.ABI_OFFSETOF_sdr_compact__share },
            .{ .name = "threshold.hysteresis.positive", .offset = c.ABI_OFFSETOF_sdr_compact__hysteresis__positive },
            .{ .name = "threshold.hysteresis.negative", .offset = c.ABI_OFFSETOF_sdr_compact__hysteresis__negative },
            .{ .name = "oem", .offset = c.ABI_OFFSETOF_sdr_compact__oem },
            .{ .name = "id_code", .offset = c.ABI_OFFSETOF_sdr_compact__id_code },
            .{ .name = "id_string", .offset = c.ABI_OFFSETOF_sdr_compact__id_string },
        },
    });
    abi.assertOpaqueLayout(EventonlySensor, .{
        .size = c.ABI_SIZEOF_sdr_record_eventonly_sensor,
        .alignment = 1,
        .fields = &.{
            .{ .name = "keys.sensor_num", .offset = c.ABI_OFFSETOF_sdr_eventonly__keys__sensor_num },
            .{ .name = "entity.id", .offset = c.ABI_OFFSETOF_sdr_eventonly__entity__id },
            .{ .name = "entity.instance", .offset = c.ABI_OFFSETOF_sdr_eventonly__entity__instance },
            .{ .name = "sensor_type", .offset = c.ABI_OFFSETOF_sdr_eventonly__sensor_type },
            .{ .name = "event_type", .offset = c.ABI_OFFSETOF_sdr_eventonly__event_type },
            .{ .name = "share", .offset = c.ABI_OFFSETOF_sdr_eventonly__share },
            .{ .name = "oem", .offset = c.ABI_OFFSETOF_sdr_eventonly__oem },
            .{ .name = "id_code", .offset = c.ABI_OFFSETOF_sdr_eventonly__id_code },
            .{ .name = "id_string", .offset = c.ABI_OFFSETOF_sdr_eventonly__id_string },
        },
    });
    abi.assertOpaqueLayout(McLocator, .{
        .size = c.ABI_SIZEOF_sdr_record_mc_locator,
        .alignment = 1,
        .fields = &.{
            .{ .name = "dev_support", .offset = c.ABI_OFFSETOF_sdr_mcloc__dev_support },
            .{ .name = "entity", .offset = c.ABI_OFFSETOF_sdr_mcloc__entity },
            .{ .name = "oem", .offset = c.ABI_OFFSETOF_sdr_mcloc__oem },
            .{ .name = "id_code", .offset = c.ABI_OFFSETOF_sdr_mcloc__id_code },
            .{ .name = "id_string", .offset = c.ABI_OFFSETOF_sdr_mcloc__id_string },
        },
    });
    abi.assertOpaqueLayout(FruLocator, .{
        .size = c.ABI_SIZEOF_sdr_record_fru_locator,
        .alignment = 1,
        .fields = &.{
            .{ .name = "device_id", .offset = c.ABI_OFFSETOF_sdr_fruloc__device_id },
            .{ .name = "dev_type", .offset = c.ABI_OFFSETOF_sdr_fruloc__dev_type },
            .{ .name = "dev_type_modifier", .offset = c.ABI_OFFSETOF_sdr_fruloc__dev_type_modifier },
            .{ .name = "entity", .offset = c.ABI_OFFSETOF_sdr_fruloc__entity },
            .{ .name = "oem", .offset = c.ABI_OFFSETOF_sdr_fruloc__oem },
            .{ .name = "id_code", .offset = c.ABI_OFFSETOF_sdr_fruloc__id_code },
            .{ .name = "id_string", .offset = c.ABI_OFFSETOF_sdr_fruloc__id_string },
        },
    });
    abi.assertOpaqueLayout(GenericLocator, .{
        .size = c.ABI_SIZEOF_sdr_record_generic_locator,
        .alignment = 1,
        .fields = &.{
            .{ .name = "dev_slave_addr", .offset = c.ABI_OFFSETOF_sdr_genloc__dev_slave_addr },
            .{ .name = "dev_type", .offset = c.ABI_OFFSETOF_sdr_genloc__dev_type },
            .{ .name = "dev_type_modifier", .offset = c.ABI_OFFSETOF_sdr_genloc__dev_type_modifier },
            .{ .name = "entity", .offset = c.ABI_OFFSETOF_sdr_genloc__entity },
            .{ .name = "oem", .offset = c.ABI_OFFSETOF_sdr_genloc__oem },
            .{ .name = "id_code", .offset = c.ABI_OFFSETOF_sdr_genloc__id_code },
            .{ .name = "id_string", .offset = c.ABI_OFFSETOF_sdr_genloc__id_string },
        },
    });
    abi.assertOpaqueLayout(EntityAssoc, .{
        .size = c.ABI_SIZEOF_sdr_record_entity_assoc,
        .alignment = 1,
        .fields = &.{
            .{ .name = "entity_id_1", .offset = c.ABI_OFFSETOF_sdr_entassoc__entity_id_1 },
            .{ .name = "entity_inst_4", .offset = c.ABI_OFFSETOF_sdr_entassoc__entity_inst_4 },
        },
    });
    abi.assertOpaqueLayout(SdrRecordOem, .{
        .size = c.ABI_SIZEOF_sdr_record_oem,
        .alignment = c.ABI_ALIGNOF_sdr_record_oem,
        .fields = &.{
            .{ .name = "data_len", .offset = c.ABI_OFFSETOF_sdr_record_oem__data_len },
        },
    });
    abi.assertOpaqueLayout(SdrRecordList, .{
        .size = c.ABI_SIZEOF_sdr_record_list,
        .alignment = c.ABI_ALIGNOF_sdr_record_list,
        .fields = &.{
            .{ .name = "id", .offset = c.ABI_OFFSETOF_sdr_record_list__id },
            .{ .name = "version", .offset = c.ABI_OFFSETOF_sdr_record_list__version },
            .{ .name = "type", .offset = c.ABI_OFFSETOF_sdr_record_list__type },
            .{ .name = "length", .offset = c.ABI_OFFSETOF_sdr_record_list__length },
            .{ .name = "raw", .offset = c.ABI_OFFSETOF_sdr_record_list__raw },
            .{ .name = "next", .offset = c.ABI_OFFSETOF_sdr_record_list__next },
            .{ .name = "record", .offset = c.ABI_OFFSETOF_sdr_record_list__record },
        },
    });
    abi.assertOpaqueLayout(SdrIterator, .{
        .size = c.ABI_SIZEOF_ipmi_sdr_iterator,
        .alignment = c.ABI_ALIGNOF_ipmi_sdr_iterator,
        .fields = &.{
            .{ .name = "total", .offset = c.ABI_OFFSETOF_ipmi_sdr_iterator__total },
            .{ .name = "next", .offset = c.ABI_OFFSETOF_ipmi_sdr_iterator__next },
            .{ .name = "use_built_in", .offset = c.ABI_OFFSETOF_ipmi_sdr_iterator__use_built_in },
        },
    });
    abi.assertOpaqueLayout(SensorReading, .{
        .size = c.ABI_SIZEOF_sensor_reading,
        .alignment = c.ABI_ALIGNOF_sensor_reading,
        .fields = &.{
            .{ .name = "full", .offset = c.ABI_OFFSETOF_sensor_reading__full },
            .{ .name = "compact", .offset = c.ABI_OFFSETOF_sensor_reading__compact },
            .{ .name = "s_reading_valid", .offset = c.ABI_OFFSETOF_sensor_reading__s_reading_valid },
            .{ .name = "s_reading", .offset = c.ABI_OFFSETOF_sensor_reading__s_reading },
            .{ .name = "s_has_analog_value", .offset = c.ABI_OFFSETOF_sensor_reading__s_has_analog_value },
            .{ .name = "s_a_val", .offset = c.ABI_OFFSETOF_sensor_reading__s_a_val },
            .{ .name = "s_a_str", .offset = c.ABI_OFFSETOF_sensor_reading__s_a_str },
            .{ .name = "s_a_units", .offset = c.ABI_OFFSETOF_sensor_reading__s_a_units },
        },
    });
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// `UNIT_TYPE_MAX`: the ID of "grams".
const unit_type_max = 92;
/// `UNIT_TYPE_LONGEST_NAME`: the length of "color temp deg K".
const unit_type_longest_name = 19;
/// `sensor_type_max`.
const sensor_type_max = 0x2c;

const SDR_RECORD_TYPE_FULL_SENSOR = 0x01;
const SDR_RECORD_TYPE_COMPACT_SENSOR = 0x02;
const SDR_RECORD_TYPE_EVENTONLY_SENSOR = 0x03;
const SDR_RECORD_TYPE_ENTITY_ASSOC = 0x08;
const SDR_RECORD_TYPE_DEVICE_ENTITY_ASSOC = 0x09;
const SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR = 0x10;
const SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR = 0x11;
const SDR_RECORD_TYPE_MC_DEVICE_LOCATOR = 0x12;
const SDR_RECORD_TYPE_MC_CONFIRMATION = 0x13;
const SDR_RECORD_TYPE_BMC_MSG_CHANNEL_INFO = 0x14;
const SDR_RECORD_TYPE_OEM = 0xc0;

const SDR_SENSOR_L_LINEAR = 0x00;
const SDR_SENSOR_L_LN = 0x01;
const SDR_SENSOR_L_LOG10 = 0x02;
const SDR_SENSOR_L_LOG2 = 0x03;
const SDR_SENSOR_L_E = 0x04;
const SDR_SENSOR_L_EXP10 = 0x05;
const SDR_SENSOR_L_EXP2 = 0x06;
const SDR_SENSOR_L_1_X = 0x07;
const SDR_SENSOR_L_SQR = 0x08;
const SDR_SENSOR_L_CUBE = 0x09;
const SDR_SENSOR_L_SQRT = 0x0a;
const SDR_SENSOR_L_CUBERT = 0x0b;
const SDR_SENSOR_L_NONLINEAR = 0x70;

const SDR_UNIT_MOD_NONE = 0;
const SDR_UNIT_MOD_DIV = 1;
const SDR_UNIT_MOD_MUL = 2;

const SDR_SENSOR_STAT_LO_NC = 1 << 0;
const SDR_SENSOR_STAT_LO_CR = 1 << 1;
const SDR_SENSOR_STAT_LO_NR = 1 << 2;
const SDR_SENSOR_STAT_HI_NC = 1 << 3;
const SDR_SENSOR_STAT_HI_CR = 1 << 4;
const SDR_SENSOR_STAT_HI_NR = 1 << 5;

const READING_UNAVAILABLE = 0x20;
const SCANNING_DISABLED = 0x40;
const EVENT_MSG_DISABLED = 0x80;

const GET_SDR_REPO_INFO = 0x20;
const GET_SDR_ALLOC_INFO = 0x21;
const GET_SDR_RESERVE_REPO = 0x22;
const GET_SDR = 0x23;
const GET_SDR_ENTIRE_RECORD = 0xff;

const GET_DEVICE_SDR_INFO = 0x20;
const GET_DEVICE_SDR = 0x21;
const GET_SENSOR_HYSTERESIS = 0x25;
const GET_SENSOR_THRESHOLDS = 0x27;
const GET_SENSOR_EVENT_ENABLE = 0x29;
const GET_SENSOR_EVENT_STATUS = 0x2b;
const GET_SENSOR_READING = 0x2d;

const ANALOG_SENSOR = 0;
const DISCRETE_SENSOR = 1;

/// IPMI 2.0 Table 43-15, Sensor Unit Type Codes.
const unit_desc = [_][*:0]const u8{
    "unspecified",
    "degrees C",
    "degrees F",
    "degrees K",
    "Volts",
    "Amps",
    "Watts",
    "Joules",
    "Coulombs",
    "VA",
    "Nits",
    "lumen",
    "lux",
    "Candela",
    "kPa",
    "PSI",
    "Newton",
    "CFM",
    "RPM",
    "Hz",
    "microsecond",
    "millisecond",
    "second",
    "minute",
    "hour",
    "day",
    "week",
    "mil",
    "inches",
    "feet",
    "cu in",
    "cu feet",
    "mm",
    "cm",
    "m",
    "cu cm",
    "cu m",
    "liters",
    "fluid ounce",
    "radians",
    "steradians",
    "revolutions",
    "cycles",
    "gravities",
    "ounce",
    "pound",
    "ft-lb",
    "oz-in",
    "gauss",
    "gilberts",
    "henry",
    "millihenry",
    "farad",
    "microfarad",
    "ohms",
    "siemens",
    "mole",
    "becquerel",
    "PPM",
    "reserved",
    "Decibels",
    "DbA",
    "DbC",
    "gray",
    "sievert",
    "color temp deg K",
    "bit",
    "kilobit",
    "megabit",
    "gigabit",
    "byte",
    "kilobyte",
    "megabyte",
    "gigabyte",
    "word",
    "dword",
    "qword",
    "line",
    "hit",
    "miss",
    "retry",
    "reset",
    "overflow",
    "underrun",
    "collision",
    "packets",
    "messages",
    "characters",
    "error",
    "correctable error",
    "uncorrectable error",
    "fatal error",
    "grams",
};

/// Sensor type codes, IPMI v2.0 Table 42-3.
const sensor_type_desc = [_][*:0]const u8{
    "reserved",
    "Temperature",
    "Voltage",
    "Current",
    "Fan",
    "Physical Security",
    "Platform Security",
    "Processor",
    "Power Supply",
    "Power Unit",
    "Cooling Device",
    "Other",
    "Memory",
    "Drive Slot / Bay",
    "POST Memory Resize",
    "System Firmwares",
    "Event Logging Disabled",
    "Watchdog1",
    "System Event",
    "Critical Interrupt",
    "Button",
    "Module / Board",
    "Microcontroller",
    "Add-in Card",
    "Chassis",
    "Chip Set",
    "Other FRU",
    "Cable / Interconnect",
    "Terminator",
    "System Boot Initiated",
    "Boot Error",
    "OS Boot",
    "OS Critical Stop",
    "Slot / Connector",
    "System ACPI Power State",
    "Watchdog2",
    "Platform Alert",
    "Entity Presence",
    "Monitor ASIC",
    "LAN",
    "Management Subsys Health",
    "Battery",
    "Session Audit",
    "Version Change",
    "FRU State",
};

// ---------------------------------------------------------------------------
// File statics
// ---------------------------------------------------------------------------

/// `use_built_in`: walk the Device SDRs instead of the SDR repository.
var use_built_in: c_int = 0;
/// `sdr_max_read_len`: clamped by the transport's response size limit.
var sdr_max_read_len: c_int = 0;
/// `sdr_extended`: `sdr elist` prints wider threshold status strings.
var sdr_extended: c_int = 0;
/// `sdriana`: the manufacturer ID of the last MC locator record printed.
var sdriana: c_long = 0;

var sdr_list_head: ?*SdrRecordList = null;
var sdr_list_tail: ?*SdrRecordList = null;
var sdr_list_itr: ?*SdrIterator = null;

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

fn cIntf(intf: *Intf) [*c]c.struct_ipmi_intf {
    return @ptrCast(intf);
}

/// One `intf->sendrecv()` round trip.
fn sendrecv(intf: *Intf, req: *Request) ?*Response {
    const send = intf.sendrecv orelse return null;
    return send(intf, req);
}

/// The `verbose` global lives in `src/ipmitool.c`.
fn verbose() c_int {
    return c.verbose;
}

fn csvOutput() bool {
    return c.csv_output != 0;
}

fn ccString(ccode: u8) [*c]const u8 {
    return c.val2str(ccode, c.completion_code_vals);
}

fn eql(a: [*c]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(@as([*:0]const u8, @ptrCast(a))), b);
}

/// C's `?:` over two string literals, which have different Zig types.
fn pick(cond: bool, a: [*:0]const u8, b: [*:0]const u8) [*:0]const u8 {
    return if (cond) a else b;
}

/// `IS_THRESHOLD_SENSOR()`.
fn isThresholdSensor(s: *const CommonSensor) bool {
    return s.event_type == 1;
}

/// `UNITS_ARE_DISCRETE()`.
fn unitsAreDiscrete(s: *const CommonSensor) bool {
    return s.unit.flags.analog == 3;
}

/// `IS_READING_UNAVAILABLE()`.
fn isReadingUnavailable(v: u8) bool {
    return (v & READING_UNAVAILABLE) != 0;
}

/// `IS_SCANNING_DISABLED()`.
fn isScanningDisabled(v: u8) bool {
    return (v & SCANNING_DISABLED) == 0;
}

/// `IS_EVENT_MSG_DISABLED()`.
fn isEventMsgDisabled(v: u8) bool {
    return (v & EVENT_MSG_DISABLED) == 0;
}

/// `BRIDGE_TO_SENSOR()`.
fn bridgeToSensor(intf: *Intf, addr: u8, chan: u8) bool {
    const same_ipmb = chan == 0 and intf.target_ipmb_addr != 0 and
        intf.target_ipmb_addr == addr;
    const same_target = addr == intf.target_addr and chan == intf.target_channel;
    return !(same_ipmb or same_target);
}

/// `tos32(val, bits)`, with the C macro's `int` arithmetic.  The macro
/// evaluates `val` three times; every call site passes a side-effect-free
/// expression, so a function is equivalent.
fn tos32(val: c_int, comptime bits: u5) c_int {
    const sign_bit: c_int = @as(c_int, 1) << bits - 1;
    if ((val & sign_bit) != 0) {
        return -%(val & sign_bit) | val;
    }
    return val;
}

/// `BSWAP_16()` from `include/ipmitool/bswap.h`.
fn bswap16(v: u16) u16 {
    return (v >> 8) | (v << 8);
}

/// `BSWAP_32()`.
fn bswap32(v: u32) u32 {
    return ((v & 0xff000000) >> 24) | ((v & 0x00ff0000) >> 8) |
        ((v & 0x0000ff00) << 8) | ((v & 0x000000ff) << 24);
}

/// The `mtol` word as the macros see it: byte-swapped on little endian, raw on
/// big endian.
fn hostMtol(mtol: u16) u32 {
    return switch (endian) {
        .little => bswap16(mtol),
        .big => mtol,
    };
}

/// The `bacc` dword as the macros see it.
fn hostBacc(bacc: u32) u32 {
    return switch (endian) {
        .little => bswap32(bacc),
        .big => bacc,
    };
}

/// `__TO_TOL()`.
fn toTol(mtol: u16) u16 {
    return @intCast(hostMtol(mtol) & 0x3f);
}

/// `__TO_M()`.  Ten bits: the low eight in the high byte of the word, the top
/// two in bits 6-7 of the low byte.
fn toM(mtol: u16) i16 {
    const v = hostMtol(mtol);
    const raw: c_int = @bitCast(((v & 0xff00) >> 8) | ((v & 0xc0) << 2));
    return @truncate(tos32(raw, 10));
}

/// `__TO_B()`.
fn toB(bacc: u32) i32 {
    const v = hostBacc(bacc);
    const raw: c_int = @bitCast(((v & 0xff000000) >> 24) | ((v & 0xc00000) >> 14));
    return tos32(raw, 10);
}

/// `__TO_R_EXP()`.
fn toRExp(bacc: u32) i32 {
    const raw: c_int = @bitCast((hostBacc(bacc) & 0xf0) >> 4);
    return tos32(raw, 4);
}

/// `__TO_B_EXP()`.
fn toBExp(bacc: u32) i32 {
    const raw: c_int = @bitCast(hostBacc(bacc) & 0xf);
    return tos32(raw, 4);
}

// ---------------------------------------------------------------------------
// Reading conversion
// ---------------------------------------------------------------------------

/// `ipmi_sdr_get_unit_string()`.  The returned pointer is into a function
/// static, exactly as in C, so callers must copy before the next call.
///
/// The buffer is twice the longest unit name plus `'%'`, the relation and the
/// terminator.
var unitstr_buf: [2 * unit_type_longest_name + 2 + 1]u8 = @splat(0);

fn getUnitString(pct: bool, relation: u8, base: u8, modifier: u8) callconv(.c) [*c]const u8 {
    const pctstr: [*:0]const u8 = pick(pct, "% ", "");
    const basestr: [*:0]const u8 =
        if (base <= unit_type_max) unit_desc[base] else "invalid";
    const modstr: [*:0]const u8 =
        if (modifier <= unit_type_max) unit_desc[modifier] else "invalid";

    switch (relation) {
        SDR_UNIT_MOD_MUL => {
            _ = c.snprintf(&unitstr_buf, unitstr_buf.len, "%s%s*%s", pctstr, basestr, modstr);
        },
        SDR_UNIT_MOD_DIV => {
            _ = c.snprintf(&unitstr_buf, unitstr_buf.len, "%s%s/%s", pctstr, basestr, modstr);
        },
        // SDR_UNIT_MOD_NONE and everything else.
        else => {
            // "percent" only when the base unit is "unspecified".
            if (base == 0 and pct) {
                _ = c.snprintf(&unitstr_buf, unitstr_buf.len, "percent");
            } else {
                _ = c.snprintf(&unitstr_buf, unitstr_buf.len, "%s%s", pctstr, basestr);
            }
        },
    }
    return &unitstr_buf;
}

/// `sdr_sensor_has_analog_reading()`.
fn sensorHasAnalogReading(intf: *Intf, sr: *SensorReading) c_int {
    // Compact sensors cannot return analog values.
    const full = sr.full orelse return 0;

    // Per the spec only full threshold sensors provide analog readings, but HP
    // packs analog readings into some non-threshold sensors, so the check is
    // relaxed for them - see the comment in lib/ipmi_sdr.c.
    if (unitsAreDiscrete(&full.cmn)) {
        return 0;
    }
    if (!isThresholdSensor(&full.cmn)) {
        const u = full.cmn.unit;
        if ((u.flags.pct | u.flags.modifier | @as(u8, @intCast(u.type.base)) |
            @as(u8, @intCast(u.type.modifier))) != 0)
        {
            if (intf.manufacturer_id != .hp) {
                return 0;
            }
        } else {
            return 0;
        }
    }

    // A sensor with linearization needs its reading factors refreshed.
    if (full.linearization >= SDR_SENSOR_L_NONLINEAR and full.linearization <= 0x7f) {
        if (c.ipmi_sensor_get_sensor_reading_factors(
            cIntf(intf),
            @ptrCast(full),
            sr.s_reading,
        ) < 0) {
            sr.s_reading_valid = 0;
            return 0;
        }
    }

    return 1;
}

/// The 12-arm linearization switch shared by the three conversion functions.
fn linearize(linearization: u8, value: f64) f64 {
    return switch (linearization & 0x7f) {
        SDR_SENSOR_L_LN => c.log(value),
        SDR_SENSOR_L_LOG10 => c.log10(value),
        SDR_SENSOR_L_LOG2 => c.log(value) / c.log(2.0),
        SDR_SENSOR_L_E => c.exp(value),
        SDR_SENSOR_L_EXP10 => c.pow(10.0, value),
        SDR_SENSOR_L_EXP2 => c.pow(2.0, value),
        // 1/x without the divide-by-zero exception.
        SDR_SENSOR_L_1_X => c.pow(value, -1.0),
        SDR_SENSOR_L_SQR => c.pow(value, 2.0),
        SDR_SENSOR_L_CUBE => c.pow(value, 3.0),
        SDR_SENSOR_L_SQRT => c.sqrt(value),
        SDR_SENSOR_L_CUBERT => c.cbrt(value),
        // SDR_SENSOR_L_LINEAR and everything else.
        else => value,
    };
}

/// `sdr_convert_sensor_reading()`: raw reading to floating point.
fn convertSensorReading(sensor: *FullSensor, val_in: u8) callconv(.c) f64 {
    var val = val_in;
    const m: c_int = toM(sensor.mtol);
    const b: c_int = toB(sensor.bacc);
    const k1: c_int = toBExp(sensor.bacc);
    const k2: c_int = toRExp(sensor.bacc);

    var result: f64 = undefined;
    switch (sensor.cmn.unit.flags.analog) {
        0 => {
            result = (@as(f64, @floatFromInt(m *% @as(c_int, val))) +
                @as(f64, @floatFromInt(b)) * c.pow(10, @floatFromInt(k1))) *
                c.pow(10, @floatFromInt(k2));
        },
        1, 2 => {
            // One's complement: the C adds one to the raw byte first, then
            // falls through into the two's complement arm.
            if (sensor.cmn.unit.flags.analog == 1 and (val & 0x80) != 0) {
                val +%= 1;
            }
            const sval: c_int = @as(i8, @bitCast(val));
            result = (@as(f64, @floatFromInt(m *% sval)) +
                @as(f64, @floatFromInt(b)) * c.pow(10, @floatFromInt(k1))) *
                c.pow(10, @floatFromInt(k2));
        },
        // Not an analog sensor.
        else => return 0.0,
    }

    return linearize(sensor.linearization, result);
}

/// `sdr_convert_sensor_hysterisis()`.  B is irrelevant for a raw comparison,
/// so only M and the R exponent are applied.
fn convertSensorHysterisis(sensor: *FullSensor, val_in: u8) callconv(.c) f64 {
    var val = val_in;
    const m: c_int = toM(sensor.mtol);
    const k2: c_int = toRExp(sensor.bacc);

    var result: f64 = undefined;
    switch (sensor.cmn.unit.flags.analog) {
        0 => {
            result = @as(f64, @floatFromInt(m *% @as(c_int, val))) *
                c.pow(10, @floatFromInt(k2));
        },
        1, 2 => {
            if (sensor.cmn.unit.flags.analog == 1 and (val & 0x80) != 0) {
                val +%= 1;
            }
            const sval: c_int = @as(i8, @bitCast(val));
            result = @as(f64, @floatFromInt(m *% sval)) * c.pow(10, @floatFromInt(k2));
        },
        else => return 0.0,
    }

    return linearize(sensor.linearization, result);
}

/// `sdr_convert_sensor_tolerance()`: as suggested in IPMI 1.5 section 30.4.1,
/// the tolerance is half a raw count times M.
fn convertSensorTolerance(sensor: *FullSensor, val_in: u8) callconv(.c) f64 {
    var val = val_in;
    const m: c_int = toM(sensor.mtol);
    const k2: c_int = toRExp(sensor.bacc);

    var result: f64 = undefined;
    switch (sensor.cmn.unit.flags.analog) {
        0 => {
            result = (@as(f64, @floatFromInt(m)) * @as(f64, @floatFromInt(val)) / 2) *
                c.pow(10, @floatFromInt(k2));
        },
        1, 2 => {
            if (sensor.cmn.unit.flags.analog == 1 and (val & 0x80) != 0) {
                val +%= 1;
            }
            const sval: i8 = @bitCast(val);
            result = @as(f64, @floatFromInt(m)) * (@as(f64, @floatFromInt(sval)) / 2) *
                c.pow(10, @floatFromInt(k2));
        },
        else => return 0.0,
    }

    return linearize(sensor.linearization, result);
}

/// `sdr_convert_sensor_value_to_raw()`.
fn convertSensorValueToRaw(sensor: *FullSensor, val: f64) callconv(.c) u8 {
    // Only works for analog sensors.
    if (unitsAreDiscrete(&sensor.cmn)) {
        return 0;
    }

    const m: c_int = toM(sensor.mtol);
    const b: c_int = toB(sensor.bacc);
    const k1: c_int = toBExp(sensor.bacc);
    const k2: c_int = toRExp(sensor.bacc);

    // Do not divide by zero.
    if (m == 0) {
        return 0;
    }

    const result = ((val / c.pow(10, @floatFromInt(k2))) -
        (@as(f64, @floatFromInt(b)) * c.pow(10, @floatFromInt(k1)))) /
        @as(f64, @floatFromInt(m));

    if ((result - @as(f64, @floatFromInt(narrowInt(result)))) >= 0.5) {
        return narrowU8(c.ceil(result));
    }
    return narrowU8(result);
}

/// C's `(int)` cast of a `double`, which is undefined out of range; the
/// hardware behaviour on the targets this builds for is a saturating convert,
/// and `@intFromFloat` would panic instead.
fn narrowInt(v: f64) c_int {
    if (std.math.isNan(v)) return 0;
    if (v >= @as(f64, @floatFromInt(std.math.maxInt(c_int)))) return std.math.maxInt(c_int);
    if (v <= @as(f64, @floatFromInt(std.math.minInt(c_int)))) return std.math.minInt(c_int);
    return @intFromFloat(v);
}

/// C's `(uint8_t)` cast of a `double`: truncate towards zero into `int`, then
/// take the low byte.
fn narrowU8(v: f64) u8 {
    return @truncate(@as(u32, @bitCast(narrowInt(v))));
}

// ---------------------------------------------------------------------------
// Per-sensor IPMI requests
//
// All five follow the same shape: optionally retarget the interface at the
// sensor's owner, issue one Sensor/Event command, restore the interface.
// ---------------------------------------------------------------------------

/// The `BRIDGE_TO_SENSOR()` save/restore pair the five wrappers share.
const Bridge = struct {
    active: bool,
    save_addr: u32 = undefined,
    save_channel: u32 = undefined,

    fn begin(intf: *Intf, target: u8, channel: u8) Bridge {
        if (!bridgeToSensor(intf, target, channel)) return .{ .active = false };
        const b: Bridge = .{
            .active = true,
            .save_addr = intf.target_addr,
            .save_channel = intf.target_channel,
        };
        intf.target_addr = target;
        intf.target_channel = channel;
        return b;
    }

    fn end(self: Bridge, intf: *Intf) void {
        if (!self.active) return;
        intf.target_addr = self.save_addr;
        intf.target_channel = @truncate(self.save_channel);
    }
};

/// `ipmi_sdr_get_sensor_thresholds()`.
fn getSensorThresholds(
    intf: *Intf,
    sensor: u8,
    target: u8,
    lun: u8,
    channel: u8,
) callconv(.c) ?*Response {
    var sensor_num = sensor;
    const bridge = Bridge.begin(intf, target, channel);

    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_se;
    req.msg.netfn_lun.lun = @truncate(lun);
    req.msg.cmd = GET_SENSOR_THRESHOLDS;
    req.msg.data = @ptrCast(&sensor_num);
    req.msg.data_len = @sizeOf(u8);

    const rsp = sendrecv(intf, &req);
    bridge.end(intf);
    return rsp;
}

/// `ipmi_sdr_get_sensor_hysteresis()`.
fn getSensorHysteresis(
    intf: *Intf,
    sensor: u8,
    target: u8,
    lun: u8,
    channel: u8,
) callconv(.c) ?*Response {
    const bridge = Bridge.begin(intf, target, channel);

    var rqdata: [2]u8 = .{ sensor, 0xff };

    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_se;
    req.msg.netfn_lun.lun = @truncate(lun);
    req.msg.cmd = GET_SENSOR_HYSTERESIS;
    req.msg.data = &rqdata;
    req.msg.data_len = 2;

    const rsp = sendrecv(intf, &req);
    bridge.end(intf);
    return rsp;
}

/// `ipmi_sdr_get_sensor_reading()`.  No bridging: this one always talks to the
/// interface's current target.
fn getSensorReading(intf: *Intf, sensor: u8) callconv(.c) ?*Response {
    var sensor_num = sensor;

    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_se;
    req.msg.cmd = GET_SENSOR_READING;
    req.msg.data = @ptrCast(&sensor_num);
    req.msg.data_len = 1;

    return sendrecv(intf, &req);
}

/// `ipmi_sdr_get_sensor_reading_ipmb()`.
fn getSensorReadingIpmb(
    intf: *Intf,
    sensor: u8,
    target: u8,
    lun: u8,
    channel: u8,
) callconv(.c) ?*Response {
    var sensor_num = sensor;
    if (bridgeToSensor(intf, target, channel)) {
        c.lprintf(c.LOG_DEBUG, "Bridge to Sensor Intf my/%#x tgt/%#x:%#x Sdr tgt/%#x:%#x\n", intf.my_addr, intf.target_addr, intf.target_channel, target, channel);
    }
    const bridge = Bridge.begin(intf, target, channel);

    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_se;
    req.msg.netfn_lun.lun = @truncate(lun);
    req.msg.cmd = GET_SENSOR_READING;
    req.msg.data = @ptrCast(&sensor_num);
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req);
    bridge.end(intf);
    return rsp;
}

/// `ipmi_sdr_get_sensor_event_status()`.
fn getSensorEventStatus(
    intf: *Intf,
    sensor: u8,
    target: u8,
    lun: u8,
    channel: u8,
) callconv(.c) ?*Response {
    var sensor_num = sensor;
    const bridge = Bridge.begin(intf, target, channel);

    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_se;
    req.msg.netfn_lun.lun = @truncate(lun);
    req.msg.cmd = GET_SENSOR_EVENT_STATUS;
    req.msg.data = @ptrCast(&sensor_num);
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req);
    bridge.end(intf);
    return rsp;
}

/// `ipmi_sdr_get_sensor_event_enable()`.
fn getSensorEventEnable(
    intf: *Intf,
    sensor: u8,
    target: u8,
    lun: u8,
    channel: u8,
) callconv(.c) ?*Response {
    var sensor_num = sensor;
    const bridge = Bridge.begin(intf, target, channel);

    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_se;
    req.msg.netfn_lun.lun = @truncate(lun);
    req.msg.cmd = GET_SENSOR_EVENT_ENABLE;
    req.msg.data = @ptrCast(&sensor_num);
    req.msg.data_len = 1;

    const rsp = sendrecv(intf, &req);
    bridge.end(intf);
    return rsp;
}

/// `ipmi_sdr_get_thresh_status()`: the two- or three-letter threshold status.
fn getThreshStatus(sr: *SensorReading, invalidstr: [*c]const u8) callconv(.c) [*c]const u8 {
    if (sr.s_reading_valid == 0) {
        return invalidstr;
    }
    const stat = sr.s_data2;
    if ((stat & SDR_SENSOR_STAT_LO_NR) != 0) {
        return if (verbose() != 0)
            "Lower Non-Recoverable"
        else if (sdr_extended != 0) "lnr" else "nr";
    } else if ((stat & SDR_SENSOR_STAT_HI_NR) != 0) {
        return if (verbose() != 0)
            "Upper Non-Recoverable"
        else if (sdr_extended != 0) "unr" else "nr";
    } else if ((stat & SDR_SENSOR_STAT_LO_CR) != 0) {
        return if (verbose() != 0)
            "Lower Critical"
        else if (sdr_extended != 0) "lcr" else "cr";
    } else if ((stat & SDR_SENSOR_STAT_HI_CR) != 0) {
        return if (verbose() != 0)
            "Upper Critical"
        else if (sdr_extended != 0) "ucr" else "cr";
    } else if ((stat & SDR_SENSOR_STAT_LO_NC) != 0) {
        return if (verbose() != 0)
            "Lower Non-Critical"
        else if (sdr_extended != 0) "lnc" else "nc";
    } else if ((stat & SDR_SENSOR_STAT_HI_NC) != 0) {
        return if (verbose() != 0)
            "Upper Non-Critical"
        else if (sdr_extended != 0) "unc" else "nc";
    }
    return "ok";
}

// ---------------------------------------------------------------------------
// SDR repository iteration
// ---------------------------------------------------------------------------

/// The function-static reply buffer of `ipmi_sdr_get_header()`.
var sdr_rs_static: SdrGetRs = .{};

/// `ipmi_sdr_get_header()`: read the five byte header of `itr->next`.
fn getHeader(intf: *Intf, itr: *SdrIterator) ?*SdrGetRs {
    var sdr_rq: SdrGetRq = .{};
    sdr_rq.reserve_id = itr.reservation;
    sdr_rq.id = @truncate(@as(c_uint, @bitCast(itr.next)));
    sdr_rq.offset = 0;
    // Only get the header.
    sdr_rq.length = 5;

    var req: Request = std.mem.zeroes(Request);
    if (itr.use_built_in == 0) {
        req.msg.netfn_lun.netfn = netfn_storage;
        req.msg.cmd = GET_SDR;
    } else {
        req.msg.netfn_lun.netfn = netfn_se;
        req.msg.cmd = GET_DEVICE_SDR;
    }
    req.msg.data = @ptrCast(&sdr_rq);
    req.msg.data_len = @sizeOf(SdrGetRq);

    var rsp: ?*Response = null;
    var tries: c_int = 0;
    while (tries < 5) : (tries += 1) {
        sdr_rq.reserve_id = itr.reservation;
        rsp = sendrecv(intf, &req);
        if (rsp == null) {
            c.lprintf(c.LOG_ERR, "Get SDR %04x command failed", itr.next);
            continue;
        } else if (rsp.?.ccode == 0xc5) {
            // Lost reservation.
            c.lprintf(c.LOG_DEBUG, "SDR reservation %04x cancelled. Sleeping a bit and retrying...", itr.reservation);

            _ = c.sleep(@bitCast(c.rand() & 3));

            if (getReservation(intf, itr.use_built_in, &itr.reservation) < 0) {
                c.lprintf(c.LOG_ERR, "Unable to renew SDR reservation");
                return null;
            }
        } else if (rsp.?.ccode != 0) {
            c.lprintf(c.LOG_ERR, "Get SDR %04x command failed: %s", itr.next, ccString(rsp.?.ccode));
            continue;
        } else {
            break;
        }
    }

    if (tries == 5) return null;
    const reply = rsp orelse return null;

    c.lprintf(c.LOG_DEBUG, "SDR record ID   : 0x%04x", itr.next);

    @memcpy(
        std.mem.asBytes(&sdr_rs_static),
        reply.data[0..@sizeOf(SdrGetRs)],
    );

    if (sdr_rs_static.length == 0) {
        c.lprintf(c.LOG_ERR, "SDR record id 0x%04x: invalid length %d", itr.next, sdr_rs_static.length);
        return null;
    }

    // Some boards return a record id different from the one requested; put the
    // original back so the follow-up body read does not fail with 0xcb.  The
    // record ID 0000h is the documented exception (IPMI v2.0 section 33.12).
    if (itr.next != 0x0000 and sdr_rs_static.id != itr.next) {
        c.lprintf(c.LOG_DEBUG, "SDR record id mismatch: 0x%04x", sdr_rs_static.id);
        sdr_rs_static.id = @truncate(@as(c_uint, @bitCast(itr.next)));
    }

    c.lprintf(c.LOG_DEBUG, "SDR record type : 0x%02x", sdr_rs_static.type);
    c.lprintf(c.LOG_DEBUG, "SDR record next : 0x%04x", sdr_rs_static.next);
    c.lprintf(c.LOG_DEBUG, "SDR record bytes: %d", sdr_rs_static.length);

    return &sdr_rs_static;
}

/// `ipmi_sdr_get_next_header()`.
fn getNextHeader(intf: *Intf, itr: *SdrIterator) callconv(.c) ?*SdrGetRs {
    if (itr.next == 0xffff) return null;

    const header = getHeader(intf, itr) orelse return null;
    itr.next = header.next;
    return header;
}

// ---------------------------------------------------------------------------
// Event status / event enable printers
// ---------------------------------------------------------------------------

/// The threshold-condition tables both event printers share.  Declared once at
/// file scope rather than as two identical function locals.
const assert_cond_1 = [_]c.struct_valstr{
    .{ .val = 0x80, .str = "unc+" },
    .{ .val = 0x40, .str = "unc-" },
    .{ .val = 0x20, .str = "lnr+" },
    .{ .val = 0x10, .str = "lnr-" },
    .{ .val = 0x08, .str = "lcr+" },
    .{ .val = 0x04, .str = "lcr-" },
    .{ .val = 0x02, .str = "lnc+" },
    .{ .val = 0x01, .str = "lnc-" },
    .{ .val = 0x00, .str = null },
};

const assert_cond_2 = [_]c.struct_valstr{
    .{ .val = 0x08, .str = "unr+" },
    .{ .val = 0x04, .str = "unr-" },
    .{ .val = 0x02, .str = "ucr+" },
    .{ .val = 0x01, .str = "ucr-" },
    .{ .val = 0x00, .str = null },
};

/// `ipmi_sdr_print_sensor_event_status()`.
fn printSensorEventStatus(
    intf: *Intf,
    sensor_num: u8,
    sensor_type: u8,
    event_type: u8,
    numeric_fmt: c_int,
    target: u8,
    lun: u8,
    channel: u8,
) callconv(.c) c_int {
    const rsp = getSensorEventStatus(intf, sensor_num, target, lun, channel) orelse {
        c.lprintf(
            c.LOG_DEBUG,
            "Error reading event status for sensor #%02x",
            @as(c_uint, sensor_num),
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            c.LOG_DEBUG,
            "Error reading event status for sensor #%02x: %s",
            @as(c_uint, sensor_num),
            ccString(rsp.ccode),
        );
        return -1;
    }
    // Upstream assumes data_len >= 1 here.
    if (isReadingUnavailable(rsp.data[0])) {
        _ = c.printf(" Event Status          : Unavailable\n");
        return 0;
    }
    if (isScanningDisabled(rsp.data[0])) {
        // Upstream leaves the body commented out; the test is kept so the
        // branch structure matches.
    }
    if (isEventMsgDisabled(rsp.data[0])) {
        _ = c.printf(" Event Status          : Event Messages Disabled\n");
    }

    switch (numeric_fmt) {
        DISCRETE_SENSOR => {
            if (rsp.data_len == 2) {
                printDiscreteState(intf, "Assertion Events", sensor_type, event_type, rsp.data[1], 0);
            } else if (rsp.data_len > 2) {
                printDiscreteState(intf, "Assertion Events", sensor_type, event_type, rsp.data[1], rsp.data[2]);
            }
            if (rsp.data_len == 4) {
                printDiscreteState(intf, "Deassertion Events", sensor_type, event_type, rsp.data[3], 0);
            } else if (rsp.data_len > 4) {
                printDiscreteState(intf, "Deassertion Events", sensor_type, event_type, rsp.data[3], rsp.data[4]);
            }
        },

        ANALOG_SENSOR => {
            _ = c.printf(" Assertion Events      : ");
            for (0..8) |i| {
                if ((rsp.data[1] & (@as(u32, 1) << @intCast(i))) != 0) {
                    _ = c.printf("%s ", c.val2str(@as(u32, 1) << @intCast(i), &assert_cond_1));
                }
            }
            if (rsp.data_len > 2) {
                for (0..4) |i| {
                    if ((rsp.data[2] & (@as(u32, 1) << @intCast(i))) != 0) {
                        _ = c.printf("%s ", c.val2str(@as(u32, 1) << @intCast(i), &assert_cond_2));
                    }
                }
                _ = c.printf("\n");
                if ((rsp.data_len == 4 and rsp.data[3] != 0) or
                    (rsp.data_len > 4 and (rsp.data[3] != 0 and rsp.data[4] != 0)))
                {
                    _ = c.printf(" Deassertion Events    : ");
                    for (0..8) |i| {
                        if ((rsp.data[3] & (@as(u32, 1) << @intCast(i))) != 0) {
                            _ = c.printf("%s ", c.val2str(@as(u32, 1) << @intCast(i), &assert_cond_1));
                        }
                    }
                    if (rsp.data_len > 4) {
                        for (0..4) |i| {
                            if ((rsp.data[4] & (@as(u32, 1) << @intCast(i))) != 0) {
                                _ = c.printf("%s ", c.val2str(@as(u32, 1) << @intCast(i), &assert_cond_2));
                            }
                        }
                    }
                    _ = c.printf("\n");
                }
            } else {
                _ = c.printf("\n");
            }
        },

        else => {},
    }

    return 0;
}

/// `ipmi_sdr_print_sensor_mask()`.  Upstream disabled the whole body with an
/// unconditional `return 0` (CVS rev 1.53) and left the code in place; it is
/// ported the same way so the symbol keeps its behaviour.
fn printSensorMask(
    intf: *Intf,
    mask: *SdrRecordMask,
    sensor_type: u8,
    event_type: u8,
    numeric_fmt: c_int,
) c_int {
    _ = intf;
    _ = mask;
    _ = sensor_type;
    _ = event_type;
    _ = numeric_fmt;
    return 0;
}

/// `ipmi_sdr_print_sensor_event_enable()`.
fn printSensorEventEnable(
    intf: *Intf,
    sensor_num: u8,
    sensor_type: u8,
    event_type: u8,
    numeric_fmt: c_int,
    target: u8,
    lun: u8,
    channel: u8,
) callconv(.c) c_int {
    const rsp = getSensorEventEnable(intf, sensor_num, target, lun, channel) orelse {
        c.lprintf(
            c.LOG_DEBUG,
            "Error reading event enable for sensor #%02x",
            @as(c_uint, sensor_num),
        );
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            c.LOG_DEBUG,
            "Error reading event enable for sensor #%02x: %s",
            @as(c_uint, sensor_num),
            ccString(rsp.ccode),
        );
        return -1;
    }

    if (isScanningDisabled(rsp.data[0])) {
        // Body commented out upstream, as in the event-status printer.
    }
    if (isEventMsgDisabled(rsp.data[0])) {
        _ = c.printf(" Event Enable          : Event Messages Disabled\n");
    }

    switch (numeric_fmt) {
        DISCRETE_SENSOR => {
            if (rsp.data_len == 2) {
                printDiscreteState(intf, "Assertions Enabled", sensor_type, event_type, rsp.data[1], 0);
            } else if (rsp.data_len > 2) {
                printDiscreteState(intf, "Assertions Enabled", sensor_type, event_type, rsp.data[1], rsp.data[2]);
            }
            if (rsp.data_len == 4) {
                printDiscreteState(intf, "Deassertions Enabled", sensor_type, event_type, rsp.data[3], 0);
            } else if (rsp.data_len > 4) {
                printDiscreteState(intf, "Deassertions Enabled", sensor_type, event_type, rsp.data[3], rsp.data[4]);
            }
        },

        ANALOG_SENSOR => {
            _ = c.printf(" Assertions Enabled    : ");
            for (0..8) |i| {
                if ((rsp.data[1] & (@as(u32, 1) << @intCast(i))) != 0) {
                    _ = c.printf("%s ", c.val2str(@as(u32, 1) << @intCast(i), &assert_cond_1));
                }
            }
            if (rsp.data_len > 2) {
                for (0..4) |i| {
                    if ((rsp.data[2] & (@as(u32, 1) << @intCast(i))) != 0) {
                        _ = c.printf("%s ", c.val2str(@as(u32, 1) << @intCast(i), &assert_cond_2));
                    }
                }
                _ = c.printf("\n");
                // Note the `||` here where the event-status printer has `&&`.
                if ((rsp.data_len == 4 and rsp.data[3] != 0) or
                    (rsp.data_len > 4 and (rsp.data[3] != 0 or rsp.data[4] != 0)))
                {
                    _ = c.printf(" Deassertions Enabled  : ");
                    for (0..8) |i| {
                        if ((rsp.data[3] & (@as(u32, 1) << @intCast(i))) != 0) {
                            _ = c.printf("%s ", c.val2str(@as(u32, 1) << @intCast(i), &assert_cond_1));
                        }
                    }
                    if (rsp.data_len > 4) {
                        for (0..4) |i| {
                            if ((rsp.data[4] & (@as(u32, 1) << @intCast(i))) != 0) {
                                _ = c.printf("%s ", c.val2str(@as(u32, 1) << @intCast(i), &assert_cond_2));
                            }
                        }
                    }
                    _ = c.printf("\n");
                }
            } else {
                _ = c.printf("\n");
            }
        },

        else => {},
    }

    return 0;
}

/// `ipmi_sdr_print_sensor_hysteresis()`.
///
/// Compact records can carry a positive/negative hysteresis pair but it can
/// never be analog, so `!full` is checked as well as the discrete-units bit in
/// case a compact sensor is misidentified.
fn printSensorHysteresis(
    sensor: *CommonSensor,
    full: ?*FullSensor,
    hysteresis_value: u8,
    hvstr: [*c]const u8,
) callconv(.c) void {
    if (full == null or unitsAreDiscrete(sensor)) {
        if (hysteresis_value == 0x00 or hysteresis_value == 0xff) {
            _ = c.printf(" %s   : Unspecified\n", hvstr);
        } else {
            _ = c.printf(" %s   : 0x%02X\n", hvstr, @as(c_uint, hysteresis_value));
        }
        return;
    }
    const creading = convertSensorHysterisis(full.?, hysteresis_value);
    if (hysteresis_value == 0x00 or hysteresis_value == 0xff or creading == 0.0) {
        _ = c.printf(" %s   : Unspecified\n", hvstr);
    } else {
        _ = c.printf(" %s   : %.3f\n", hvstr, creading);
    }
}

/// `print_sensor_min_max()`.
fn printSensorMinMax(full_opt: ?*FullSensor) void {
    // No min/max for a compact SDR record.
    const full = full_opt orelse return;

    var creading: f64 = 0.0;
    const is_analog = !unitsAreDiscrete(&full.cmn);
    if (is_analog) creading = convertSensorReading(full, full.sensor_min);
    const analog = full.cmn.unit.flags.analog;
    if ((analog == 0 and full.sensor_min == 0x00) or
        (analog == 1 and full.sensor_min == 0xff) or
        (analog == 2 and full.sensor_min == 0x80) or
        (is_analog and creading == 0.0))
    {
        _ = c.printf(" Minimum sensor range  : Unspecified\n");
    } else {
        if (is_analog) {
            _ = c.printf(" Minimum sensor range  : %.3f\n", creading);
        } else {
            _ = c.printf(" Minimum sensor range  : 0x%02X\n", @as(c_uint, full.sensor_min));
        }
    }
    if (is_analog) creading = convertSensorReading(full, full.sensor_max);
    if ((analog == 0 and full.sensor_max == 0xff) or
        (analog == 1 and full.sensor_max == 0x00) or
        (analog == 2 and full.sensor_max == 0x7f) or
        (is_analog and creading == 0.0))
    {
        _ = c.printf(" Maximum sensor range  : Unspecified\n");
    } else {
        if (is_analog) {
            _ = c.printf(" Maximum sensor range  : %.3f\n", creading);
        } else {
            _ = c.printf(" Maximum sensor range  : 0x%02X\n", @as(c_uint, full.sensor_max));
        }
    }
}

/// `print_csv_discrete()`.
fn printCsvDiscrete(intf: *Intf, sensor: *CommonSensor, sr: *const SensorReading) void {
    if (sr.s_reading_valid == 0 or sr.s_reading_unavailable != 0) {
        _ = c.printf(
            "%02Xh,ns,%d.%d,No Reading",
            @as(c_uint, sensor.keys.sensor_num),
            @as(c_int, sensor.entity.id),
            @as(c_int, sensor.entity.instance.instance),
        );
        return;
    }

    if (sr.s_has_analog_value != 0) {
        _ = c.printf("%s,%s,", &sr.s_a_str, sr.s_a_units);
    } else {
        _ = c.printf("%02Xh,", @as(c_uint, sensor.keys.sensor_num));
    }
    _ = c.printf(
        "ok,%d.%d,",
        @as(c_int, sensor.entity.id),
        @as(c_int, sensor.entity.instance.instance),
    );
    printDiscreteStateMini(
        intf,
        null,
        ", ",
        sensor.sensor.type,
        sensor.event_type,
        sr.s_data2,
        sr.s_data3,
    );
}

// ---------------------------------------------------------------------------
// Full / compact sensor printing
// ---------------------------------------------------------------------------

/// The function-static reading of `ipmi_sdr_read_sensor_value()`.
var sensor_reading_static: SensorReading = .{};

/// `ipmi_sdr_read_sensor_value()`.
fn readSensorValue(
    intf: *Intf,
    sensor_opt: ?*CommonSensor,
    sdr_record_type: u8,
    precision: c_int,
) callconv(.c) ?*SensorReading {
    const sensor = sensor_opt orelse return null;

    const sr = &sensor_reading_static;
    // Initialise to a reading-valid value of zero.
    sr.* = .{};

    switch (sdr_record_type) {
        SDR_RECORD_TYPE_FULL_SENSOR => {
            const full: *FullSensor = @ptrCast(sensor);
            sr.full = full;
            var idlen: c_uint = full.id_code & 0x1f;
            idlen = if (idlen < sr.s_id.len) idlen else sr.s_id.len - 1;
            @memcpy(sr.s_id[0..idlen], full.id_string[0..idlen]);
        },
        SDR_RECORD_TYPE_COMPACT_SENSOR => {
            const compact: *CompactSensor = @ptrCast(sensor);
            sr.compact = compact;
            var idlen: c_uint = compact.id_code & 0x1f;
            idlen = if (idlen < sr.s_id.len) idlen else sr.s_id.len - 1;
            @memcpy(sr.s_id[0..idlen], compact.id_string[0..idlen]);
        },
        else => return null,
    }

    const rsp_opt = getSensorReadingIpmb(
        intf,
        sensor.keys.sensor_num,
        sensor.keys.owner_id,
        sensor.keys.flags.lun,
        sensor.keys.flags.channel,
    );
    // Init the analog value to a floating point zero, with no converted
    // string and no units.
    sr.s_a_val = 0.0;
    sr.s_a_str[0] = 0;
    sr.s_a_units = "";

    const rsp = rsp_opt orelse {
        c.lprintf(
            c.LOG_DEBUG,
            "Error reading sensor %s (#%02x)",
            &sr.s_id,
            @as(c_uint, sensor.keys.sensor_num),
        );
        return sr;
    };

    if (rsp.ccode != 0) {
        if (!((sr.full != null and rsp.ccode == 0xcb) or
            (sr.compact != null and rsp.ccode == 0xcd)))
        {
            c.lprintf(
                c.LOG_DEBUG,
                "Error reading sensor %s (#%02x): %s",
                &sr.s_id,
                @as(c_uint, sensor.keys.sensor_num),
                ccString(rsp.ccode),
            );
        }
        return sr;
    }

    if (rsp.data_len < 2) {
        // Both the value (data[0]) and its validity (data[1]) are needed to
        // interpret the reading.
        c.lprintf(
            c.LOG_DEBUG,
            "Error reading sensor %s invalid len %d",
            &sr.s_id,
            rsp.data_len,
        );
        return sr;
    }

    if (isReadingUnavailable(rsp.data[1])) {
        sr.s_reading_unavailable = 1;
    }

    if (isScanningDisabled(rsp.data[1])) {
        sr.s_scanning_disabled = 1;
        c.lprintf(
            c.LOG_DEBUG,
            "Sensor %s (#%02x) scanning disabled",
            &sr.s_id,
            @as(c_uint, sensor.keys.sensor_num),
        );
        return sr;
    }
    if (sr.s_reading_unavailable == 0) {
        sr.s_reading_valid = 1;
        sr.s_reading = rsp.data[0];
    }
    if (rsp.data_len > 2) sr.s_data2 = rsp.data[2];
    if (rsp.data_len > 3) sr.s_data3 = rsp.data[3];
    if (sensorHasAnalogReading(intf, sr) != 0) {
        sr.s_has_analog_value = 1;
        if (sr.s_reading_valid != 0) {
            sr.s_a_val = convertSensorReading(sr.full.?, sr.s_reading);
        }
        const unit = sr.full.?.cmn.unit;
        sr.s_a_units = @ptrCast(getUnitString(
            unit.flags.pct != 0,
            unit.flags.modifier,
            unit.type.base,
            unit.type.modifier,
        ));
        _ = c.snprintf(
            &sr.s_a_str,
            sr.s_a_str.len,
            "%.*f",
            if (sr.s_a_val == @as(f64, @floatFromInt(narrowInt(sr.s_a_val)))) @as(c_int, 0) else precision,
            sr.s_a_val,
        );
    }
    return sr;
}

/// `SENSOR_PRINT_CSV()`.
fn sensorPrintCsv(full: *FullSensor, flag: bool, read: u8) void {
    if (flag) {
        if (unitsAreDiscrete(&full.cmn)) {
            _ = c.printf("0x%02X,", @as(c_uint, read));
        } else {
            _ = c.printf("%.3f,", convertSensorReading(full, read));
        }
    } else {
        _ = c.printf(",");
    }
}

/// `SENSOR_PRINT_NORMAL()`.
fn sensorPrintNormal(full: *FullSensor, name: [*:0]const u8, flag: u1, read: u8) void {
    if (flag != 0) {
        _ = c.printf(" %-21s : ", name);
        if (unitsAreDiscrete(&full.cmn)) {
            _ = c.printf("0x%02X\n", @as(c_uint, read));
        } else {
            _ = c.printf("%.3f\n", convertSensorReading(full, read));
        }
    }
}

/// `SENSOR_PRINT_THRESH()`.
fn sensorPrintThresh(full: *FullSensor, name: [*:0]const u8, read: u8, flag: u1) void {
    if (full.cmn.sensor.init.thresholds != 0 and flag != 0) {
        _ = c.printf(" %-21s : ", name);
        if (unitsAreDiscrete(&full.cmn)) {
            _ = c.printf("0x%02X\n", @as(c_uint, read));
        } else {
            _ = c.printf("%.3f\n", convertSensorReading(full, read));
        }
    }
}

/// `ipmi_sdr_print_sensor_fc()`: the full and compact record printer.
fn printSensorFc(intf: *Intf, sensor: *CommonSensor, sdr_record_type: u8) callconv(.c) c_int {
    var sval: [16]u8 = undefined;

    const sr = readSensorValue(intf, sensor, sdr_record_type, 2) orelse return -1;

    const target = sensor.keys.owner_id;
    const lun = sensor.keys.flags.lun;
    const channel = sensor.keys.flags.channel;

    // CSV OUTPUT
    if (csvOutput()) {
        _ = c.printf("%s,", &sr.s_id);
        if (!isThresholdSensor(sensor)) {
            printCsvDiscrete(intf, sensor, sr);
            _ = c.printf("\n");
        } else {
            if (sr.s_reading_valid != 0) {
                if (sr.s_has_analog_value != 0) {
                    _ = c.printf(
                        "%.*f,",
                        if (sr.s_a_val == @as(f64, @floatFromInt(narrowInt(sr.s_a_val)))) @as(c_int, 0) else 3,
                        sr.s_a_val,
                    );
                    _ = c.printf("%s,%s", sr.s_a_units, getThreshStatus(sr, "ns"));
                } else {
                    printCsvDiscrete(intf, sensor, sr);
                }
            } else {
                _ = c.printf(",,ns");
            }

            if (verbose() != 0) {
                _ = c.printf(
                    ",%d.%d,%s,%s,",
                    @as(c_int, sensor.entity.id),
                    @as(c_int, sensor.entity.instance.instance),
                    c.val2str(sensor.entity.id, c.entity_id_vals),
                    c.ipmi_get_sensor_type(cIntf(intf), sensor.sensor.type),
                );

                if (sr.full) |full| {
                    const read_mask = sensor.mask.readBits();
                    sensorPrintCsv(full, full.analog_flag.nominal_read != 0, full.nominal_read);
                    sensorPrintCsv(full, full.analog_flag.normal_min != 0, full.normal_min);
                    sensorPrintCsv(full, full.analog_flag.normal_max != 0, full.normal_max);
                    sensorPrintCsv(full, read_mask.unr != 0, full.threshold.upper.non_recover);
                    sensorPrintCsv(full, read_mask.ucr != 0, full.threshold.upper.critical);
                    sensorPrintCsv(full, read_mask.unc != 0, full.threshold.upper.non_critical);
                    sensorPrintCsv(full, read_mask.lnr != 0, full.threshold.lower.non_recover);
                    sensorPrintCsv(full, read_mask.lcr != 0, full.threshold.lower.critical);
                    sensorPrintCsv(full, read_mask.lnc != 0, full.threshold.lower.non_critical);

                    if (unitsAreDiscrete(sensor)) {
                        _ = c.printf(
                            "0x%02X,0x%02X",
                            @as(c_uint, full.sensor_min),
                            @as(c_uint, full.sensor_max),
                        );
                    } else {
                        _ = c.printf(
                            "%.3f,%.3f",
                            convertSensorReading(full, full.sensor_min),
                            convertSensorReading(full, full.sensor_max),
                        );
                    }
                } else {
                    _ = c.printf(",,,,,,,,,,");
                }
            }
            _ = c.printf("\n");
        }

        return 0;
    }

    // NORMAL OUTPUT
    if (verbose() == 0 and sdr_extended == 0) {
        _ = c.printf("%-16s | ", &sr.s_id);

        @memset(&sval, 0);

        if (sr.s_reading_valid != 0) {
            if (sr.s_has_analog_value != 0) {
                _ = c.snprintf(&sval, sval.len, "%s %s", &sr.s_a_str, sr.s_a_units);
            } else {
                _ = c.snprintf(&sval, sval.len, "0x%02x", @as(c_uint, sr.s_reading));
            }
        } else if (sr.s_scanning_disabled != 0) {
            _ = c.snprintf(&sval, sval.len, pick(sr.full != null, "disabled", "Not Readable"));
        } else {
            _ = c.snprintf(&sval, sval.len, pick(sr.full != null, "no reading", "Not Readable"));
        }

        _ = c.printf("%s", &sval);

        var i: usize = c.strlen(&sval);
        while (i <= sval.len) : (i += 1) {
            _ = c.printf(" ");
        }
        _ = c.printf(" | ");

        if (isThresholdSensor(sensor)) {
            _ = c.printf("%s", getThreshStatus(sr, "ns"));
        } else {
            _ = c.printf("%s", pick(sr.s_reading_valid != 0, "ok", "ns"));
        }

        _ = c.printf("\n");

        return 0;
    } else if (verbose() == 0 and sdr_extended == 1) {
        _ = c.printf("%-16s | %02Xh | ", &sr.s_id, @as(c_uint, sensor.keys.sensor_num));

        if (isThresholdSensor(sensor)) {
            _ = c.printf(
                "%-3s | %2d.%1d | ",
                getThreshStatus(sr, "ns"),
                @as(c_int, sensor.entity.id),
                @as(c_int, sensor.entity.instance.instance),
            );
        } else {
            _ = c.printf(
                "%-3s | %2d.%1d | ",
                pick(sr.s_reading_valid != 0, "ok", "ns"),
                @as(c_int, sensor.entity.id),
                @as(c_int, sensor.entity.instance.instance),
            );
        }

        @memset(&sval, 0);

        if (sr.s_reading_valid != 0) {
            if (isThresholdSensor(sensor) and sr.s_has_analog_value != 0) {
                _ = c.snprintf(&sval, sval.len, "%s %s", &sr.s_a_str, sr.s_a_units);
            } else {
                var header: [*c]const u8 = null;
                if (sr.s_has_analog_value != 0) {
                    _ = c.printf("%s %s", &sr.s_a_str, sr.s_a_units);
                    header = ", ";
                }
                printDiscreteStateMini(
                    intf,
                    header,
                    ", ",
                    sensor.sensor.type,
                    sensor.event_type,
                    sr.s_data2,
                    sr.s_data3,
                );
            }
        } else if (sr.s_scanning_disabled != 0) {
            _ = c.snprintf(&sval, sval.len, "Disabled");
        } else {
            _ = c.snprintf(&sval, sval.len, "No Reading");
        }

        _ = c.printf("%s\n", &sval);
        return 0;
    }

    // VERBOSE OUTPUT
    _ = c.printf(
        "Sensor ID              : %s (0x%x)\n",
        &sr.s_id,
        @as(c_uint, sensor.keys.sensor_num),
    );
    _ = c.printf(
        " Entity ID             : %d.%d (%s)\n",
        @as(c_int, sensor.entity.id),
        @as(c_int, sensor.entity.instance.instance),
        c.val2str(sensor.entity.id, c.entity_id_vals),
    );

    if (!isThresholdSensor(sensor)) {
        _ = c.printf(
            " Sensor Type (Discrete): %s (0x%02x)\n",
            c.ipmi_get_sensor_type(cIntf(intf), sensor.sensor.type),
            @as(c_uint, sensor.sensor.type),
        );
        c.lprintf(
            c.LOG_DEBUG,
            " Event Type Code       : 0x%02x",
            @as(c_uint, sensor.event_type),
        );

        _ = c.printf(" Sensor Reading        : ");
        if (sr.s_reading_valid != 0) {
            if (sr.s_has_analog_value != 0) {
                _ = c.printf("%s %s\n", &sr.s_a_str, sr.s_a_units);
            } else {
                _ = c.printf("%xh\n", @as(c_uint, sr.s_reading));
            }
        } else if (sr.s_scanning_disabled != 0) {
            _ = c.printf("Disabled\n");
        } else {
            _ = c.printf("No Reading\n");
        }

        _ = c.printf(" Event Message Control : ");
        switch (sensor.sensor.capabilities.event_msg) {
            0 => _ = c.printf("Per-threshold\n"),
            1 => _ = c.printf("Entire Sensor Only\n"),
            2 => _ = c.printf("Global Disable Only\n"),
            3 => _ = c.printf("No Events From Sensor\n"),
        }

        printDiscreteState(
            intf,
            "States Asserted",
            sensor.sensor.type,
            sensor.event_type,
            sr.s_data2,
            sr.s_data3,
        );
        _ = printSensorMask(intf, &sensor.mask, sensor.sensor.type, sensor.event_type, DISCRETE_SENSOR);
        _ = printSensorEventStatus(
            intf,
            sensor.keys.sensor_num,
            sensor.sensor.type,
            sensor.event_type,
            DISCRETE_SENSOR,
            target,
            lun,
            channel,
        );
        _ = printSensorEventEnable(
            intf,
            sensor.keys.sensor_num,
            sensor.sensor.type,
            sensor.event_type,
            DISCRETE_SENSOR,
            target,
            lun,
            channel,
        );
        _ = c.printf(
            " OEM                   : %X\n",
            @as(c_uint, if (sr.full) |f| f.oem else sr.compact.?.oem),
        );
        _ = c.printf("\n");

        return 0;
    }

    _ = c.printf(
        " Sensor Type (Threshold)  : %s (0x%02x)\n",
        c.ipmi_get_sensor_type(cIntf(intf), sensor.sensor.type),
        @as(c_uint, sensor.sensor.type),
    );

    _ = c.printf(" Sensor Reading        : ");
    if (sr.s_reading_valid != 0) {
        if (sr.full) |full| {
            const raw_tol = toTol(full.mtol);
            if (unitsAreDiscrete(sensor)) {
                _ = c.printf(
                    "0x%02X (+/- 0x%02X) %s\n",
                    @as(c_uint, sr.s_reading),
                    @as(c_uint, raw_tol),
                    sr.s_a_units,
                );
            } else {
                const tol = convertSensorTolerance(full, @truncate(raw_tol));
                _ = c.printf(
                    "%.*f (+/- %.*f) %s\n",
                    if (sr.s_a_val == @as(f64, @floatFromInt(narrowInt(sr.s_a_val)))) @as(c_int, 0) else 3,
                    sr.s_a_val,
                    if (tol == @as(f64, @floatFromInt(narrowInt(tol)))) @as(c_int, 0) else 3,
                    tol,
                    sr.s_a_units,
                );
            }
        } else {
            _ = c.printf("0x%02X %s\n", @as(c_uint, sr.s_reading), sr.s_a_units);
        }
    } else if (sr.s_scanning_disabled != 0) {
        _ = c.printf("Disabled\n");
    } else {
        _ = c.printf("No Reading\n");
    }

    _ = c.printf(" Status                : %s\n", getThreshStatus(sr, "Not Available"));

    if (sr.full) |full| {
        const read_mask = sensor.mask.readBits();
        sensorPrintNormal(full, "Nominal Reading", full.analog_flag.nominal_read, full.nominal_read);
        sensorPrintNormal(full, "Normal Minimum", full.analog_flag.normal_min, full.normal_min);
        sensorPrintNormal(full, "Normal Maximum", full.analog_flag.normal_max, full.normal_max);

        sensorPrintThresh(full, "Upper non-recoverable", full.threshold.upper.non_recover, read_mask.unr);
        sensorPrintThresh(full, "Upper critical", full.threshold.upper.critical, read_mask.ucr);
        sensorPrintThresh(full, "Upper non-critical", full.threshold.upper.non_critical, read_mask.unc);
        sensorPrintThresh(full, "Lower non-recoverable", full.threshold.lower.non_recover, read_mask.lnr);
        sensorPrintThresh(full, "Lower critical", full.threshold.lower.critical, read_mask.lcr);
        sensorPrintThresh(full, "Lower non-critical", full.threshold.lower.non_critical, read_mask.lnc);
    }
    printSensorHysteresis(
        sensor,
        sr.full,
        if (sr.full) |f| f.threshold.hysteresis.positive else sr.compact.?.threshold.hysteresis.positive,
        "Positive Hysteresis",
    );
    printSensorHysteresis(
        sensor,
        sr.full,
        if (sr.full) |f| f.threshold.hysteresis.negative else sr.compact.?.threshold.hysteresis.negative,
        "Negative Hysteresis",
    );

    printSensorMinMax(sr.full);

    _ = c.printf(" Event Message Control : ");
    switch (sensor.sensor.capabilities.event_msg) {
        0 => _ = c.printf("Per-threshold\n"),
        1 => _ = c.printf("Entire Sensor Only\n"),
        2 => _ = c.printf("Global Disable Only\n"),
        3 => _ = c.printf("No Events From Sensor\n"),
    }

    const read_mask = sensor.mask.readBits();
    const set_mask = sensor.mask.setBits();

    _ = c.printf(" Readable Thresholds   : ");
    switch (sensor.sensor.capabilities.threshold) {
        0 => _ = c.printf("No Thresholds\n"),
        // 1: readable according to mask; 2: readable and settable.
        1, 2 => {
            if (read_mask.lnr != 0) _ = c.printf("lnr ");
            if (read_mask.lcr != 0) _ = c.printf("lcr ");
            if (read_mask.lnc != 0) _ = c.printf("lnc ");
            if (read_mask.unc != 0) _ = c.printf("unc ");
            if (read_mask.ucr != 0) _ = c.printf("ucr ");
            if (read_mask.unr != 0) _ = c.printf("unr ");
            _ = c.printf("\n");
        },
        3 => _ = c.printf("Thresholds Fixed\n"),
    }

    _ = c.printf(" Settable Thresholds   : ");
    switch (sensor.sensor.capabilities.threshold) {
        0 => _ = c.printf("No Thresholds\n"),
        1, 2 => {
            if (set_mask.lnr != 0) _ = c.printf("lnr ");
            if (set_mask.lcr != 0) _ = c.printf("lcr ");
            if (set_mask.lnc != 0) _ = c.printf("lnc ");
            if (set_mask.unc != 0) _ = c.printf("unc ");
            if (set_mask.ucr != 0) _ = c.printf("ucr ");
            if (set_mask.unr != 0) _ = c.printf("unr ");
            _ = c.printf("\n");
        },
        3 => _ = c.printf("Thresholds Fixed\n"),
    }

    const assert_bits = sensor.mask.assertBits();
    const deassert_bits = sensor.mask.deassertBits();
    if (assert_bits.status_lnr != 0 or assert_bits.status_lcr != 0 or
        assert_bits.status_lnc != 0 or deassert_bits.status_unc != 0 or
        deassert_bits.status_ucr != 0 or deassert_bits.status_unr != 0)
    {
        _ = c.printf(" Threshold Read Mask   : ");
        if (assert_bits.status_lnr != 0) _ = c.printf("lnr ");
        if (assert_bits.status_lcr != 0) _ = c.printf("lcr ");
        if (assert_bits.status_lnc != 0) _ = c.printf("lnc ");
        if (deassert_bits.status_unc != 0) _ = c.printf("unc ");
        if (deassert_bits.status_ucr != 0) _ = c.printf("ucr ");
        if (deassert_bits.status_unr != 0) _ = c.printf("unr ");
        _ = c.printf("\n");
    }

    _ = printSensorMask(intf, &sensor.mask, sensor.sensor.type, sensor.event_type, ANALOG_SENSOR);
    _ = printSensorEventStatus(
        intf,
        sensor.keys.sensor_num,
        sensor.sensor.type,
        sensor.event_type,
        ANALOG_SENSOR,
        target,
        lun,
        channel,
    );

    _ = printSensorEventEnable(
        intf,
        sensor.keys.sensor_num,
        sensor.sensor.type,
        sensor.event_type,
        ANALOG_SENSOR,
        target,
        lun,
        channel,
    );

    _ = c.printf("\n");
    return 0;
}

// ---------------------------------------------------------------------------
// Discrete state printers and the simple record printers
// ---------------------------------------------------------------------------

/// `get_offset()`: the index of the single set bit, 0 if there isn't exactly
/// one.  Upstream `static inline`; nothing else in the tree calls it.
fn getOffset(x: u8) c_int {
    var i: u3 = 0;
    while (true) : (i += 1) {
        if (x >> i == 1) return i;
        if (i == 7) break;
    }
    return 0;
}

/// `ipmi_sdr_print_discrete_state_mini()`.
fn printDiscreteStateMini(
    intf: *Intf,
    header: [*c]const u8,
    separator: [*c]const u8,
    sensor_type: u8,
    event_type: u8,
    state1: u8,
    state2: u8,
) callconv(.c) void {
    var pre: c_int = 0;
    var count: c_int = 0;

    if (state1 == 0 and (state2 & 0x7f) == 0) return;

    if (header != null) {
        _ = c.printf("%s", header);
    }

    var evt = c.ipmi_get_first_event_sensor_type(cIntf(intf), sensor_type, event_type);
    while (evt != null) : (evt = c.ipmi_get_next_event_sensor_type(evt)) {
        if (evt.*.data != 0xff) {
            continue;
        }

        if (evt.*.offset > 7) {
            if (((@as(u32, 1) << @intCast(evt.*.offset - 8)) & (state2 & 0x7f)) != 0) {
                if (pre != 0) {
                    _ = c.printf("%s", separator);
                }
                pre += 1;
                if (evt.*.desc != null) {
                    _ = c.printf("%s", evt.*.desc);
                }
            }
        } else {
            if (((@as(u32, 1) << @intCast(evt.*.offset)) & state1) != 0) {
                if (pre != 0) {
                    _ = c.printf("%s", separator);
                }
                pre += 1;
                if (evt.*.desc != null) {
                    _ = c.printf("%s", evt.*.desc);
                }
            }
        }
        count += 1;
    }
}

/// `ipmi_sdr_print_discrete_state()`.
fn printDiscreteState(
    intf: *Intf,
    desc: [*c]const u8,
    sensor_type: u8,
    event_type: u8,
    state1: u8,
    state2: u8,
) callconv(.c) void {
    var pre: c_int = 0;
    var count: c_int = 0;

    if (state1 == 0 and (state2 & 0x7f) == 0) return;

    var evt = c.ipmi_get_first_event_sensor_type(cIntf(intf), sensor_type, event_type);
    while (evt != null) : (evt = c.ipmi_get_next_event_sensor_type(evt)) {
        if (evt.*.data != 0xff) {
            continue;
        }

        if (pre == 0) {
            _ = c.printf(
                " %-21s : %s\n",
                desc,
                c.ipmi_get_sensor_type(cIntf(intf), sensor_type),
            );
            pre = 1;
        }

        if (evt.*.offset > 7) {
            if (((@as(u32, 1) << @intCast(evt.*.offset - 8)) & (state2 & 0x7f)) != 0) {
                if (evt.*.desc != null) {
                    _ = c.printf("                         [%s]\n", evt.*.desc);
                } else {
                    _ = c.printf("                         [no description]\n");
                }
            }
        } else {
            if (((@as(u32, 1) << @intCast(evt.*.offset)) & state1) != 0) {
                if (evt.*.desc != null) {
                    _ = c.printf("                         [%s]\n", evt.*.desc);
                } else {
                    _ = c.printf("                         [no description]\n");
                }
            }
        }
        count += 1;
    }
}

/// `ipmi_sdr_print_sensor_eventonly()`.
fn printSensorEventonly(intf: *Intf, sensor_opt: ?*EventonlySensor) callconv(.c) c_int {
    var desc: [17]u8 = undefined;

    const sensor = sensor_opt orelse return -1;

    @memset(&desc, 0);
    _ = c.snprintf(
        &desc,
        desc.len,
        "%.*s",
        @as(c_int, (sensor.id_code & 0x1f)) + 1,
        &sensor.id_string,
    );

    const name: [*c]const u8 = if (sensor.id_code != 0) &desc else "";

    if (verbose() != 0) {
        _ = c.printf(
            "Sensor ID              : %s (0x%x)\n",
            name,
            @as(c_uint, sensor.keys.sensor_num),
        );
        _ = c.printf(
            "Entity ID              : %d.%d (%s)\n",
            @as(c_int, sensor.entity.id),
            @as(c_int, sensor.entity.instance.instance),
            c.val2str(sensor.entity.id, c.entity_id_vals),
        );
        _ = c.printf(
            "Sensor Type            : %s (0x%02x)\n",
            c.ipmi_get_sensor_type(cIntf(intf), sensor.sensor_type),
            @as(c_uint, sensor.sensor_type),
        );
        c.lprintf(
            c.LOG_DEBUG,
            "Event Type Code        : 0x%02x",
            @as(c_uint, sensor.event_type),
        );
        _ = c.printf("\n");
    } else {
        if (csvOutput()) {
            _ = c.printf(
                "%s,%02Xh,ns,%d.%d,Event-Only\n",
                name,
                @as(c_uint, sensor.keys.sensor_num),
                @as(c_int, sensor.entity.id),
                @as(c_int, sensor.entity.instance.instance),
            );
        } else if (sdr_extended != 0) {
            _ = c.printf(
                "%-16s | %02Xh | ns  | %2d.%1d | Event-Only\n",
                name,
                @as(c_uint, sensor.keys.sensor_num),
                @as(c_int, sensor.entity.id),
                @as(c_int, sensor.entity.instance.instance),
            );
        } else {
            _ = c.printf("%-16s | Event-Only        | ns\n", name);
        }
    }

    return 0;
}

/// `ipmi_sdr_print_sensor_mc_locator()`.
fn printSensorMcLocator(mc_opt: ?*McLocator) callconv(.c) c_int {
    var desc: [17]u8 = undefined;

    const mc = mc_opt orelse return -1;

    @memset(&desc, 0);
    _ = c.snprintf(&desc, desc.len, "%.*s", @as(c_int, (mc.id_code & 0x1f)) + 1, &mc.id_string);

    const name: [*c]const u8 = if (mc.id_code != 0) &desc else "";
    const notif = mc.power.pwr_state_notif;
    const global_init = mc.power.global_init;

    if (verbose() == 0) {
        if (csvOutput()) {
            _ = c.printf(
                "%s,00h,ok,%d.%d\n",
                name,
                @as(c_int, mc.entity.id),
                @as(c_int, mc.entity.instance.instance),
            );
        } else if (sdr_extended != 0) {
            _ = c.printf(
                "%-16s | 00h | ok  | %2d.%1d | ",
                name,
                @as(c_int, mc.entity.id),
                @as(c_int, mc.entity.instance.instance),
            );

            _ = c.printf(
                "%s MC @ %02Xh\n",
                pick((notif & 0x1) != 0, "Static", "Dynamic"),
                @as(c_uint, mc.dev_slave_addr),
            );
        } else {
            _ = c.printf(
                "%-16s | %s MC @ %02Xh %s | ok\n",
                name,
                pick((notif & 0x1) != 0, "Static", "Dynamic"),
                @as(c_uint, mc.dev_slave_addr),
                pick((notif & 0x1) != 0, " ", ""),
            );
        }

        return 0;
    }

    _ = c.printf("Device ID              : %s\n", &mc.id_string);
    _ = c.printf(
        "Entity ID              : %d.%d (%s)\n",
        @as(c_int, mc.entity.id),
        @as(c_int, mc.entity.instance.instance),
        c.val2str(mc.entity.id, c.entity_id_vals),
    );

    _ = c.printf("Device Slave Address   : %02Xh\n", @as(c_uint, mc.dev_slave_addr));
    _ = c.printf("Channel Number         : %01Xh\n", @as(c_uint, mc.chan.channel_num));

    _ = c.printf("ACPI System P/S Notif  : %sRequired\n", pick((notif & 0x4) != 0, "", "Not "));
    _ = c.printf("ACPI Device P/S Notif  : %sRequired\n", pick((notif & 0x2) != 0, "", "Not "));
    _ = c.printf("Controller Presence    : %s\n", pick((notif & 0x1) != 0, "Static", "Dynamic"));
    _ = c.printf("Logs Init Agent Errors : %s\n", pick((global_init & 0x8) != 0, "Yes", "No"));

    _ = c.printf("Event Message Gen      : ");
    if ((global_init & 0x3) == 0) {
        _ = c.printf("Enable\n");
    } else if ((global_init & 0x3) == 0x1) {
        _ = c.printf("Disable\n");
    } else if ((global_init & 0x3) == 0x2) {
        _ = c.printf("Do Not Init Controller\n");
    } else {
        _ = c.printf("Reserved\n");
    }

    _ = c.printf("Device Capabilities\n");
    _ = c.printf(" Chassis Device        : %s\n", pick((mc.dev_support & 0x80) != 0, "Yes", "No"));
    _ = c.printf(" Bridge                : %s\n", pick((mc.dev_support & 0x40) != 0, "Yes", "No"));
    _ = c.printf(" IPMB Event Generator  : %s\n", pick((mc.dev_support & 0x20) != 0, "Yes", "No"));
    _ = c.printf(" IPMB Event Receiver   : %s\n", pick((mc.dev_support & 0x10) != 0, "Yes", "No"));
    _ = c.printf(" FRU Inventory Device  : %s\n", pick((mc.dev_support & 0x08) != 0, "Yes", "No"));
    _ = c.printf(" SEL Device            : %s\n", pick((mc.dev_support & 0x04) != 0, "Yes", "No"));
    _ = c.printf(" SDR Repository        : %s\n", pick((mc.dev_support & 0x02) != 0, "Yes", "No"));
    _ = c.printf(" Sensor Device         : %s\n", pick((mc.dev_support & 0x01) != 0, "Yes", "No"));

    _ = c.printf("\n");

    return 0;
}

/// `ipmi_sdr_print_sensor_generic_locator()`.  Upstream dereferences `dev`
/// without a null check, unlike the MC and event-only printers.
fn printSensorGenericLocator(dev: *GenericLocator) callconv(.c) c_int {
    var desc: [17]u8 = undefined;

    @memset(&desc, 0);
    _ = c.snprintf(&desc, desc.len, "%.*s", @as(c_int, (dev.id_code & 0x1f)) + 1, &dev.id_string);

    const name: [*c]const u8 = if (dev.id_code != 0) &desc else "";

    if (verbose() == 0) {
        if (csvOutput()) {
            _ = c.printf(
                "%s,00h,ns,%d.%d\n",
                name,
                @as(c_int, dev.entity.id),
                @as(c_int, dev.entity.instance.instance),
            );
        } else if (sdr_extended != 0) {
            _ = c.printf(
                "%-16s | 00h | ns  | %2d.%1d | Generic Device @%02Xh:%02Xh.%1d\n",
                name,
                @as(c_int, dev.entity.id),
                @as(c_int, dev.entity.instance.instance),
                @as(c_uint, dev.dev_access_addr),
                @as(c_uint, dev.dev_slave_addr),
                @as(c_int, dev.oem),
            );
        } else {
            _ = c.printf(
                "%-16s | Generic @%02X:%02X.%-2d | ok\n",
                name,
                @as(c_uint, dev.dev_access_addr),
                @as(c_uint, dev.dev_slave_addr),
                @as(c_int, dev.oem),
            );
        }

        return 0;
    }

    _ = c.printf("Device ID              : %s\n", &dev.id_string);
    _ = c.printf(
        "Entity ID              : %d.%d (%s)\n",
        @as(c_int, dev.entity.id),
        @as(c_int, dev.entity.instance.instance),
        c.val2str(dev.entity.id, c.entity_id_vals),
    );

    _ = c.printf("Device Access Address  : %02Xh\n", @as(c_uint, dev.dev_access_addr));
    _ = c.printf("Device Slave Address   : %02Xh\n", @as(c_uint, dev.dev_slave_addr));
    _ = c.printf("Address Span           : %02Xh\n", @as(c_uint, dev.span.addr_span));
    _ = c.printf("Channel Number         : %01Xh\n", @as(c_uint, dev.access.channel_num));
    _ = c.printf(
        "LUN.Bus                : %01Xh.%01Xh\n",
        @as(c_uint, dev.access.lun),
        @as(c_uint, dev.access.bus),
    );
    _ = c.printf(
        "Device Type.Modifier   : %01Xh.%01Xh (%s)\n",
        @as(c_uint, dev.dev_type),
        @as(c_uint, dev.dev_type_modifier),
        c.val2str(
            @as(u32, dev.dev_type) << 8 | @as(u32, dev.dev_type_modifier),
            c.entity_device_type_vals,
        ),
    );
    _ = c.printf("OEM                    : %02Xh\n", @as(c_uint, dev.oem));
    _ = c.printf("\n");

    return 0;
}

/// `ipmi_sdr_print_sensor_fru_locator()`.  Also unchecked upstream.
fn printSensorFruLocator(fru: *FruLocator) callconv(.c) c_int {
    var desc: [17]u8 = undefined;

    @memset(&desc, 0);
    _ = c.snprintf(&desc, desc.len, "%.*s", @as(c_int, (fru.id_code & 0x1f)) + 1, &fru.id_string);

    const name: [*c]const u8 = if (fru.id_code != 0) &desc else "";
    const logical = fru.access.logical != 0;

    if (verbose() == 0) {
        if (csvOutput()) {
            _ = c.printf(
                "%s,00h,ns,%d.%d\n",
                name,
                @as(c_int, fru.entity.id),
                @as(c_int, fru.entity.instance.instance),
            );
        } else if (sdr_extended != 0) {
            _ = c.printf(
                "%-16s | 00h | ns  | %2d.%1d | %s FRU @%02Xh\n",
                name,
                @as(c_int, fru.entity.id),
                @as(c_int, fru.entity.instance.instance),
                pick(logical, "Logical", "Physical"),
                @as(c_uint, fru.device_id),
            );
        } else {
            _ = c.printf(
                "%-16s | %s FRU @%02Xh %02x.%x | ok\n",
                name,
                pick(logical, "Log", "Phy"),
                @as(c_uint, fru.device_id),
                @as(c_uint, fru.entity.id),
                @as(c_uint, fru.entity.instance.instance),
            );
        }

        return 0;
    }

    _ = c.printf("Device ID              : %s\n", &fru.id_string);
    _ = c.printf(
        "Entity ID              : %d.%d (%s)\n",
        @as(c_int, fru.entity.id),
        @as(c_int, fru.entity.instance.instance),
        c.val2str(fru.entity.id, c.entity_id_vals),
    );

    _ = c.printf("Device Access Address  : %02Xh\n", @as(c_uint, fru.dev_slave_addr));
    _ = c.printf(
        "%s: %02Xh\n",
        pick(logical, "Logical FRU Device     ", "Slave Address          "),
        @as(c_uint, fru.device_id),
    );
    _ = c.printf("Channel Number         : %01Xh\n", @as(c_uint, fru.chan.channel_num));
    _ = c.printf(
        "LUN.Bus                : %01Xh.%01Xh\n",
        @as(c_uint, fru.access.lun),
        @as(c_uint, fru.access.bus),
    );
    _ = c.printf(
        "Device Type.Modifier   : %01Xh.%01Xh (%s)\n",
        @as(c_uint, fru.dev_type),
        @as(c_uint, fru.dev_type_modifier),
        c.val2str(
            @as(u32, fru.dev_type) << 8 | @as(u32, fru.dev_type_modifier),
            c.entity_device_type_vals,
        ),
    );
    _ = c.printf("OEM                    : %02Xh\n", @as(c_uint, fru.oem));
    _ = c.printf("\n");

    return 0;
}

// ---------------------------------------------------------------------------
// OEM records and the record dispatchers
// ---------------------------------------------------------------------------

/// `ipmi_sdr_print_sensor_oem_intel()`.
fn printSensorOemIntel(oem: *SdrRecordOem) c_int {
    const data = oem.data.?;
    // Record sub-type.
    switch (data[3]) {
        // Power Unit Map.
        0x02 => {
            if (verbose() != 0) {
                _ = c.printf(
                    "Sensor ID              : Power Unit Redundancy (0x%x)\n",
                    @as(c_uint, data[4]),
                );
                _ = c.printf("Sensor Type            : Intel OEM - Power Unit Map\n");
                _ = c.printf("Redundant Supplies     : %d", @as(c_int, data[6]));
                if (data[5] != 0) {
                    _ = c.printf(" (flags %xh)", @as(c_uint, data[5]));
                }
                _ = c.printf("\n");
            }

            switch (oem.data_len) {
                // SR1300, non-redundant.
                7 => {
                    if (verbose() != 0) {
                        _ = c.printf("Power Redundancy       : No\n");
                    } else if (csvOutput()) {
                        _ = c.printf("Power Redundancy,Not Available,nr\n");
                    } else {
                        _ = c.printf("Power Redundancy | Not Available     | nr\n");
                    }
                },
                // SR2300, redundant, PS1 and PS2 present.
                8 => {
                    if (verbose() != 0) {
                        _ = c.printf("Power Redundancy       : No\n");
                        _ = c.printf("Power Supply 2 Sensor  : %x\n", @as(c_uint, data[8]));
                    } else if (csvOutput()) {
                        _ = c.printf("Power Redundancy,PS@%02xh,nr\n", @as(c_uint, data[8]));
                    } else {
                        _ = c.printf(
                            "Power Redundancy | PS@%02xh            | nr\n",
                            @as(c_uint, data[8]),
                        );
                    }
                },
                // SR2300, non-redundant, PSx present.
                9 => {
                    if (verbose() != 0) {
                        _ = c.printf("Power Redundancy       : Yes\n");
                        _ = c.printf("Power Supply Sensor    : %x\n", @as(c_uint, data[7]));
                        _ = c.printf("Power Supply Sensor    : %x\n", @as(c_uint, data[8]));
                    } else if (csvOutput()) {
                        _ = c.printf(
                            "Power Redundancy,PS@%02xh + PS@%02xh,ok\n",
                            @as(c_uint, data[7]),
                            @as(c_uint, data[8]),
                        );
                    } else {
                        _ = c.printf(
                            "Power Redundancy | PS@%02xh + PS@%02xh   | ok\n",
                            @as(c_uint, data[7]),
                            @as(c_uint, data[8]),
                        );
                    }
                },
                else => {},
            }
            if (verbose() != 0) {
                _ = c.printf("\n");
            }
        },
        // Fan Speed Control, System Information, Ambient Temperature Fan
        // Speed Control: all three are empty cases upstream.
        0x03, 0x06, 0x07 => {},
        else => {
            c.lprintf(
                c.LOG_DEBUG,
                "Unknown Intel OEM SDR Record type %02x",
                @as(c_uint, data[3]),
            );
        },
    }

    return 0;
}

/// `ipmi_sdr_print_sensor_oem()`: keyed off manufacturer ID and record
/// sub-type.  Only Intel is decoded.
fn printSensorOem(oem_opt: ?*SdrRecordOem) c_int {
    var rc: c_int = 0;

    const oem = oem_opt orelse return -1;
    if (oem.data_len == 0 or oem.data == null) return -1;

    if (verbose() > 2) {
        c.printbuf(oem.data, oem.data_len, "OEM Record");
    }

    const data = oem.data.?;
    if (data[0] == 0x57 and data[1] == 0x01 and data[2] == 0x00) {
        rc = printSensorOemIntel(oem);
    }

    return rc;
}

/// The C casts `raw` to a record pointer and dereferences it without a null
/// check, so a null `raw` faults there exactly as it would here.  Runtime
/// safety is disabled so the Zig reproduces that fault rather than trapping
/// with a different message.
fn rawAs(comptime T: type, raw: ?[*]u8) *T {
    @setRuntimeSafety(false);
    return @ptrFromInt(@intFromPtr(raw));
}

/// `ipmi_sdr_print_name_from_rawentry()`.
fn printNameFromRawentry(id: u16, rtype: u8, raw: ?[*]u8) callconv(.c) c_int {
    var rc: c_int = 0;
    var desc: [17]u8 = undefined;
    var id_string: [*c]const u8 = undefined;
    var id_code: u8 = undefined;
    // Note: filled with spaces, not zeroes, and left unterminated when the
    // record type is not one of the four handled below.
    @memset(&desc, ' ');

    switch (rtype) {
        SDR_RECORD_TYPE_FULL_SENSOR => {
            const full = rawAs(FullSensor, raw);
            id_code = full.id_code;
            id_string = &full.id_string;
        },
        SDR_RECORD_TYPE_COMPACT_SENSOR => {
            const compact = rawAs(CompactSensor, raw);
            id_code = compact.id_code;
            id_string = &compact.id_string;
        },
        SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
            const eventonly = rawAs(EventonlySensor, raw);
            id_code = eventonly.id_code;
            id_string = &eventonly.id_string;
        },
        SDR_RECORD_TYPE_MC_DEVICE_LOCATOR => {
            const mcloc = rawAs(McLocator, raw);
            id_code = mcloc.id_code;
            id_string = &mcloc.id_string;
        },
        else => rc = -1,
    }
    if (rc == 0) {
        _ = c.snprintf(&desc, desc.len, "%.*s", @as(c_int, (id_code & 0x1f)) + 1, id_string);
    }

    c.lprintf(c.LOG_INFO, "ID: 0x%04x , NAME: %-16s", @as(c_uint, id), &desc);
    return rc;
}

/// `ipmi_sdr_print_rawentry()`.
fn printRawentry(intf: *Intf, rtype: u8, raw: [*]u8, len: c_int) callconv(.c) c_int {
    var rc: c_int = 0;

    switch (rtype) {
        SDR_RECORD_TYPE_FULL_SENSOR, SDR_RECORD_TYPE_COMPACT_SENSOR => {
            rc = printSensorFc(intf, @ptrCast(raw), rtype);
        },
        SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
            rc = printSensorEventonly(intf, @ptrCast(raw));
        },
        SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR => {
            rc = printSensorGenericLocator(@ptrCast(raw));
        },
        SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR => {
            rc = printSensorFruLocator(@ptrCast(raw));
        },
        SDR_RECORD_TYPE_MC_DEVICE_LOCATOR => {
            rc = printSensorMcLocator(@ptrCast(raw));
        },
        SDR_RECORD_TYPE_ENTITY_ASSOC => {},
        SDR_RECORD_TYPE_OEM => {
            var oem: SdrRecordOem = .{ .data = raw, .data_len = len };
            rc = printSensorOem(&oem);
        },
        // Not implemented upstream.
        SDR_RECORD_TYPE_DEVICE_ENTITY_ASSOC,
        SDR_RECORD_TYPE_MC_CONFIRMATION,
        SDR_RECORD_TYPE_BMC_MSG_CHANNEL_INFO,
        => {},
        else => {},
    }

    return rc;
}

/// `ipmi_sdr_print_listentry()`.
fn printListentry(intf: *Intf, entry: *SdrRecordList) callconv(.c) c_int {
    var rc: c_int = 0;

    switch (entry.type) {
        SDR_RECORD_TYPE_FULL_SENSOR, SDR_RECORD_TYPE_COMPACT_SENSOR => {
            rc = printSensorFc(intf, entry.common(), entry.type);
        },
        SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
            rc = printSensorEventonly(intf, entry.eventonly());
        },
        SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR => {
            rc = printSensorGenericLocator(entry.genloc());
        },
        SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR => {
            rc = printSensorFruLocator(entry.fruloc());
        },
        SDR_RECORD_TYPE_MC_DEVICE_LOCATOR => {
            rc = printSensorMcLocator(entry.mcloc());
        },
        SDR_RECORD_TYPE_ENTITY_ASSOC => {},
        SDR_RECORD_TYPE_OEM => {
            rc = printSensorOem(entry.oem());
        },
        SDR_RECORD_TYPE_DEVICE_ENTITY_ASSOC,
        SDR_RECORD_TYPE_MC_CONFIRMATION,
        SDR_RECORD_TYPE_BMC_MSG_CHANNEL_INFO,
        => {},
        else => {},
    }

    return rc;
}

// ---------------------------------------------------------------------------
// The SDR walk
// ---------------------------------------------------------------------------

/// `ipmi_sdr_print_sdr()`: walk the repository, printing and caching.
fn printSdr(intf: *Intf, rtype: u8) callconv(.c) c_int {
    var rc: c_int = 0;

    c.lprintf(c.LOG_DEBUG, "Querying SDR for sensor list");

    if (sdr_list_itr == null) {
        sdr_list_itr = sdrStart(intf, 0);
        if (sdr_list_itr == null) {
            c.lprintf(c.LOG_ERR, "Unable to open SDR for reading");
            return -1;
        }
    }

    var e = sdr_list_head;
    while (e) |entry| : (e = entry.next) {
        if (rtype != entry.type and rtype != 0xff and rtype != 0xfe) continue;
        if (rtype == 0xfe and
            entry.type != SDR_RECORD_TYPE_FULL_SENSOR and
            entry.type != SDR_RECORD_TYPE_COMPACT_SENSOR) continue;
        if (printListentry(intf, entry) < 0) rc = -1;
    }

    while (getNextHeader(intf, sdr_list_itr.?)) |header| {
        const rec = getRecord(intf, header, sdr_list_itr.?) orelse {
            c.lprintf(c.LOG_ERR, "ipmitool: ipmi_sdr_get_record() failed");
            rc = -1;
            continue;
        };

        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                c.free(rec);
                break;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);
        sdrr.id = header.id;
        sdrr.type = header.type;

        switch (header.type) {
            SDR_RECORD_TYPE_FULL_SENSOR,
            SDR_RECORD_TYPE_COMPACT_SENSOR,
            SDR_RECORD_TYPE_EVENTONLY_SENSOR,
            SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR,
            SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR,
            SDR_RECORD_TYPE_MC_DEVICE_LOCATOR,
            SDR_RECORD_TYPE_ENTITY_ASSOC,
            => sdrr.record = rec,
            else => {
                c.free(rec);
                c.free(sdrr);
                continue;
            },
        }

        c.lprintf(c.LOG_DEBUG, "SDR record ID   : 0x%04x", @as(c_uint, sdrr.id));

        if (rtype == header.type or rtype == 0xff or
            (rtype == 0xfe and
                (header.type == SDR_RECORD_TYPE_FULL_SENSOR or
                    header.type == SDR_RECORD_TYPE_COMPACT_SENSOR)))
        {
            if (printRawentry(intf, header.type, @ptrCast(rec), header.length) < 0) rc = -1;
        }

        // Add to the global record list.
        if (sdr_list_head == null) {
            sdr_list_head = sdrr;
        } else {
            sdr_list_tail.?.next = sdrr;
        }

        sdr_list_tail = sdrr;
    }

    return rc;
}

/// `ipmi_sdr_get_reservation()`.  Silent on error: the caller reports.
fn getReservation(intf: *Intf, use_builtin: c_int, reserve_id: *u16) callconv(.c) c_int {
    var req: Request = std.mem.zeroes(Request);

    if (use_builtin == 0) {
        req.msg.netfn_lun.netfn = netfn_storage;
    } else {
        req.msg.netfn_lun.netfn = netfn_se;
    }

    req.msg.cmd = GET_SDR_RESERVE_REPO;
    const rsp = sendrecv(intf, &req) orelse return -1;
    if (rsp.ccode != 0) return -1;

    // `struct sdr_reserve_repo_rs` is a bare little endian `uint16_t`.
    reserve_id.* = std.mem.bytesToValue(u16, rsp.data[0..2]);
    c.lprintf(c.LOG_DEBUG, "SDR reservation ID %04x", @as(c_uint, reserve_id.*));

    return 0;
}

/// `ipmi_sdr_start()`: allocate and prime an iterator.
fn sdrStart(intf: *Intf, use_builtin: c_int) callconv(.c) ?*SdrIterator {
    const itr: *SdrIterator = @ptrCast(@alignCast(
        c.malloc(@sizeOf(SdrIterator)) orelse {
            c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
            return null;
        },
    ));

    // Check the SDR repository capability.
    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = @intCast(c.IPMI_NETFN_APP);
    req.msg.cmd = c.BMC_GET_DEVICE_ID;
    req.msg.data_len = 0;

    var rsp = sendrecv(intf, &req) orelse {
        c.lprintf(c.LOG_ERR, "Get Device ID command failed");
        c.free(itr);
        return null;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            c.LOG_ERR,
            "Get Device ID command failed: %#x %s",
            @as(c_uint, rsp.ccode),
            ccString(rsp.ccode),
        );
        c.free(itr);
        return null;
    }
    const devid: [*]u8 = &rsp.data;

    // `IPM_DEV_MANUFACTURER_ID()` is `ipmi24toh()` over `manufacturer_id[3]`,
    // which starts at offset 6 of `struct ipm_devid_rsp`.
    sdriana = @intCast(ipmi24toh(devid[6..9]));

    // `device_revision` is byte 1, `adtl_device_support` byte 5.
    if (use_builtin == 0 and (devid[1] & c.IPM_DEV_DEVICE_ID_SDR_MASK) != 0) {
        if ((devid[5] & 0x02) == 0) {
            if ((devid[5] & 0x01) != 0) {
                c.lprintf(c.LOG_DEBUG, "Using Device SDRs\n");
                use_built_in = 1;
            } else {
                c.lprintf(c.LOG_ERR, "Error obtaining SDR info");
                c.free(itr);
                return null;
            }
        } else {
            c.lprintf(c.LOG_DEBUG, "Using SDR from Repository \n");
        }
    }
    itr.use_built_in = if (use_builtin != 0) 1 else use_built_in;

    if (itr.use_built_in == 0) {
        var sdr_info: SdrRepoInfoRs = .{};
        req = std.mem.zeroes(Request);
        req.msg.netfn_lun.netfn = netfn_storage;
        req.msg.cmd = GET_SDR_REPO_INFO;

        rsp = sendrecv(intf, &req) orelse {
            c.lprintf(c.LOG_ERR, "Error obtaining SDR info");
            c.free(itr);
            return null;
        };
        if (rsp.ccode != 0) {
            c.lprintf(c.LOG_ERR, "Error obtaining SDR info: %s", ccString(rsp.ccode));
            c.free(itr);
            return null;
        }

        @memcpy(std.mem.asBytes(&sdr_info), rsp.data[0..@sizeOf(SdrRepoInfoRs)]);
        // IPMIv1.0 == 0x01, IPMIv1.5 == 0x51, IPMIv2.0 == 0x02.
        if (sdr_info.version != 0x51 and
            sdr_info.version != 0x01 and
            sdr_info.version != 0x02)
        {
            c.lprintf(
                c.LOG_WARN,
                "WARNING: Unknown SDR repository version 0x%02x",
                @as(c_uint, sdr_info.version),
            );
        }

        itr.total = sdr_info.count;
        itr.next = 0;

        c.lprintf(c.LOG_DEBUG, "SDR free space: %d", @as(c_int, sdr_info.free));
        c.lprintf(c.LOG_DEBUG, "SDR records   : %d", @as(c_int, sdr_info.count));

        // Build the SDRR if the repository is empty.
        if (sdr_info.count == 0) {
            c.lprintf(c.LOG_DEBUG, "Rebuilding SDRR...");

            if (sdrAddFromSensors(intf, 0) != 0) {
                c.lprintf(c.LOG_ERR, "Could not build SDRR!");
                c.free(itr);
                return null;
            }
        }
    } else {
        var sdr_info: SdrDeviceInfoRs = .{};
        req = std.mem.zeroes(Request);
        req.msg.netfn_lun.netfn = netfn_se;
        req.msg.cmd = GET_DEVICE_SDR_INFO;

        const dev_rsp = sendrecv(intf, &req);
        if (dev_rsp == null or dev_rsp.?.data_len == 0 or dev_rsp.?.ccode != 0) {
            _ = c.printf("Err in cmd get sensor sdr info\n");
            c.free(itr);
            return null;
        }
        @memcpy(std.mem.asBytes(&sdr_info), dev_rsp.?.data[0..@sizeOf(SdrDeviceInfoRs)]);

        itr.total = sdr_info.count;
        itr.next = 0;
        c.lprintf(c.LOG_DEBUG, "SDR records   : %d", @as(c_int, sdr_info.count));
    }

    if (getReservation(intf, itr.use_built_in, &itr.reservation) < 0) {
        c.lprintf(c.LOG_ERR, "Unable to obtain SDR reservation");
        c.free(itr);
        return null;
    }

    return itr;
}

/// `ipmi24toh()`: 24 bits little endian out of three bytes.
fn ipmi24toh(m: *const [3]u8) u32 {
    return @as(u32, m[2]) << 16 | @as(u32, m[1]) << 8 | @as(u32, m[0]);
}

/// `ipmi_sdr_get_record()`: read one record body with partial reads.
fn getRecord(intf: *Intf, header: *SdrGetRs, itr: *SdrIterator) callconv(.c) ?[*]u8 {
    var i: c_int = 0;
    const len: c_int = header.length;

    if (len < 1) return null;

    const data: [*]u8 = @ptrCast(c.malloc(@intCast(len + 1)) orelse {
        c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
        return null;
    });
    @memset(data[0..@intCast(len + 1)], 0);

    var sdr_rq: SdrGetRq = .{};
    sdr_rq.reserve_id = itr.reservation;
    sdr_rq.id = header.id;
    sdr_rq.offset = 0;

    var req: Request = std.mem.zeroes(Request);
    if (itr.use_built_in == 0) {
        req.msg.netfn_lun.netfn = netfn_storage;
        req.msg.cmd = GET_SDR;
    } else {
        req.msg.netfn_lun.netfn = netfn_se;
        req.msg.cmd = GET_DEVICE_SDR;
    }
    req.msg.data = @ptrCast(&sdr_rq);
    req.msg.data_len = @sizeOf(SdrGetRq);

    if (sdr_max_read_len == 0) {
        sdr_max_read_len = c.ipmi_intf_get_max_response_data_size(cIntf(intf)) - 2;

        // Cap the number of bytes to read.
        if (sdr_max_read_len > 0xfe) {
            sdr_max_read_len = 0xfe;
        }
    }

    // Read the record with partial reads: a full read usually exceeds the
    // transport buffer size (completion code 0xca).
    while (i < len) {
        sdr_rq.length = @intCast(if (len - i < sdr_max_read_len) len - i else sdr_max_read_len);
        // Five header bytes.
        sdr_rq.offset = @intCast(i + 5);

        c.lprintf(
            c.LOG_DEBUG,
            "Getting %d bytes from SDR at offset %d",
            @as(c_int, sdr_rq.length),
            @as(c_int, sdr_rq.offset),
        );

        const rsp_opt = sendrecv(intf, &req);

        if (rsp_opt == null or rsp_opt.?.ccode == c.IPMI_CC_CANT_RET_NUM_REQ_BYTES) {
            sdr_max_read_len = @as(c_int, sdr_rq.length) - 1;
            if (sdr_max_read_len > 0) {
                // No response can happen when requests are bridged and too
                // many bytes are asked for.
                continue;
            } else {
                c.free(data);
                return null;
            }
        } else if (rsp_opt.?.ccode == c.IPMI_CC_RES_CANCELED) {
            // Lost reservation.
            c.lprintf(c.LOG_DEBUG, "SDR reservation cancelled. Sleeping a bit and retrying...");

            _ = c.sleep(@bitCast(c.rand() & 3));

            if (getReservation(intf, itr.use_built_in, &itr.reservation) < 0) {
                c.free(data);
                return null;
            }
            sdr_rq.reserve_id = itr.reservation;
            continue;
        }

        const rsp = rsp_opt.?;
        // The special completion codes are handled above.
        if (rsp.ccode != 0 or rsp.data_len == 0) {
            c.free(data);
            return null;
        }

        @memcpy(data[@intCast(i)..][0..sdr_rq.length], rsp.data[2..][0..sdr_rq.length]);
        i += sdr_rq.length;
    }

    return data;
}

/// `ipmi_sdr_end()`.
fn sdrEnd(itr: ?*SdrIterator) callconv(.c) void {
    if (itr) |i| {
        c.free(i);
    }
}

/// `__sdr_list_add()`: append a *copy* of `entry` to the list at `head`.
fn sdrListAdd(head: ?*SdrRecordList, entry: *SdrRecordList) c_int {
    const h = head orelse return -1;

    const new: *SdrRecordList = @ptrCast(@alignCast(
        c.malloc(@sizeOf(SdrRecordList)) orelse {
            c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
            return -1;
        },
    ));
    @memcpy(std.mem.asBytes(new), std.mem.asBytes(entry));

    var e = h;
    while (e.next) |n| e = n;
    e.next = new;
    new.next = null;

    return 0;
}

/// `__sdr_list_empty()`: free the spine only, not the records.
fn sdrListEmptyLow(head: ?*SdrRecordList) void {
    var e = head;
    while (e) |entry| {
        const f = entry.next;
        c.free(entry);
        e = f;
    }
}

/// `ipmi_sdr_list_empty()`: drop the global cache.
fn sdrListEmpty() callconv(.c) void {
    sdrEnd(sdr_list_itr);

    var list = sdr_list_head;
    while (list) |entry| {
        switch (entry.type) {
            SDR_RECORD_TYPE_FULL_SENSOR,
            SDR_RECORD_TYPE_COMPACT_SENSOR,
            SDR_RECORD_TYPE_EVENTONLY_SENSOR,
            SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR,
            SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR,
            SDR_RECORD_TYPE_MC_DEVICE_LOCATOR,
            SDR_RECORD_TYPE_ENTITY_ASSOC,
            => {
                if (entry.record) |rec| {
                    c.free(rec);
                    entry.record = null;
                }
            },
            else => {},
        }
        const next = entry.next;
        c.free(entry);
        list = next;
    }

    sdr_list_head = null;
    sdr_list_tail = null;
    sdr_list_itr = null;
}

/// The record types that the `find_sdr_by*` walkers keep; every other type is
/// freed and skipped.  Shared by the five lookup helpers below.
fn isCachedRecordType(t: u8) bool {
    return switch (t) {
        SDR_RECORD_TYPE_FULL_SENSOR,
        SDR_RECORD_TYPE_COMPACT_SENSOR,
        SDR_RECORD_TYPE_EVENTONLY_SENSOR,
        SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR,
        SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR,
        SDR_RECORD_TYPE_MC_DEVICE_LOCATOR,
        SDR_RECORD_TYPE_ENTITY_ASSOC,
        => true,
        else => false,
    };
}

/// Append `sdrr` to the global cache, as the walkers all do verbatim.
fn cacheAppend(sdrr: *SdrRecordList) void {
    if (sdr_list_head == null) {
        sdr_list_head = sdrr;
    } else {
        sdr_list_tail.?.next = sdrr;
    }
    sdr_list_tail = sdrr;
}

/// Ensure the global iterator exists, as every walker's prologue does.
fn ensureIterator(intf: *Intf) bool {
    if (sdr_list_itr == null) {
        sdr_list_itr = sdrStart(intf, 0);
        if (sdr_list_itr == null) {
            c.lprintf(c.LOG_ERR, "Unable to open SDR for reading");
            return false;
        }
    }
    return true;
}

/// `ipmi_sdr_find_sdr_bynumtype()`.
fn findSdrBynumtype(intf: *Intf, gen_id: u16, num: u8, rtype: u8) callconv(.c) ?*SdrRecordList {
    var found = false;

    if (!ensureIterator(intf)) return null;

    // Check what we have already read.
    var e = sdr_list_head;
    while (e) |entry| : (e = entry.next) {
        switch (entry.type) {
            SDR_RECORD_TYPE_FULL_SENSOR, SDR_RECORD_TYPE_COMPACT_SENSOR => {
                const rec = entry.common();
                if (rec.keys.sensor_num == num and
                    rec.keys.owner_id == (gen_id & 0x00ff) and
                    rec.keys.flags.lun == ((gen_id & 0x0300) >> 8) and
                    rec.sensor.type == rtype) return entry;
            },
            SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
                const rec = entry.eventonly();
                if (rec.keys.sensor_num == num and
                    rec.keys.owner_id == (gen_id & 0x00ff) and
                    rec.keys.flags.lun == ((gen_id & 0x0300) >> 0x8) and
                    rec.sensor_type == rtype) return entry;
            },
            else => {},
        }
    }

    // Now keep looking.
    while (getNextHeader(intf, sdr_list_itr.?)) |header| {
        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                break;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);
        sdrr.id = header.id;
        sdrr.type = header.type;

        const rec = getRecord(intf, header, sdr_list_itr.?) orelse {
            c.free(sdrr);
            continue;
        };

        if (!isCachedRecordType(header.type)) {
            c.free(rec);
            c.free(sdrr);
            continue;
        }
        sdrr.record = rec;

        switch (header.type) {
            SDR_RECORD_TYPE_FULL_SENSOR, SDR_RECORD_TYPE_COMPACT_SENSOR => {
                const r = sdrr.common();
                if (r.keys.sensor_num == num and
                    r.keys.owner_id == (gen_id & 0x00ff) and
                    r.keys.flags.lun == ((gen_id & 0x0300) >> 8) and
                    r.sensor.type == rtype) found = true;
            },
            SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
                const r = sdrr.eventonly();
                if (r.keys.sensor_num == num and
                    r.keys.owner_id == (gen_id & 0x00ff) and
                    r.keys.flags.lun == ((gen_id & 0x0300) >> 8) and
                    r.sensor_type == rtype) found = true;
            },
            else => {},
        }

        cacheAppend(sdrr);

        if (found) return sdrr;
    }

    return null;
}

/// `ipmi_sdr_find_sdr_bysensortype()`.
fn findSdrBysensortype(intf: *Intf, rtype: u8) callconv(.c) ?*SdrRecordList {
    if (!ensureIterator(intf)) return null;

    // Check what we have already read.
    const head: *SdrRecordList = @ptrCast(@alignCast(
        c.malloc(@sizeOf(SdrRecordList)) orelse {
            c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
            return null;
        },
    ));
    @memset(std.mem.asBytes(head), 0);

    var e = sdr_list_head;
    while (e) |entry| : (e = entry.next) {
        switch (entry.type) {
            SDR_RECORD_TYPE_FULL_SENSOR, SDR_RECORD_TYPE_COMPACT_SENSOR => {
                if (entry.common().sensor.type == rtype) _ = sdrListAdd(head, entry);
            },
            SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
                if (entry.eventonly().sensor_type == rtype) _ = sdrListAdd(head, entry);
            },
            else => {},
        }
    }

    // Now keep looking.
    while (getNextHeader(intf, sdr_list_itr.?)) |header| {
        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                break;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);
        sdrr.id = header.id;
        sdrr.type = header.type;

        const rec = getRecord(intf, header, sdr_list_itr.?) orelse {
            c.free(sdrr);
            continue;
        };

        if (!isCachedRecordType(header.type)) {
            c.free(rec);
            c.free(sdrr);
            continue;
        }
        sdrr.record = rec;

        switch (header.type) {
            SDR_RECORD_TYPE_FULL_SENSOR, SDR_RECORD_TYPE_COMPACT_SENSOR => {
                if (sdrr.common().sensor.type == rtype) _ = sdrListAdd(head, sdrr);
            },
            SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
                if (sdrr.eventonly().sensor_type == rtype) _ = sdrListAdd(head, sdrr);
            },
            else => {},
        }

        cacheAppend(sdrr);
    }

    return head;
}

/// The `entity` member for whichever record arm `entry` holds.  The C spells
/// this out per union arm; the offset genuinely differs per record type.
fn entityOfEntry(entry: *const SdrRecordList) ?*EntityId {
    return switch (entry.type) {
        SDR_RECORD_TYPE_FULL_SENSOR,
        SDR_RECORD_TYPE_COMPACT_SENSOR,
        => &entry.common().entity,
        SDR_RECORD_TYPE_EVENTONLY_SENSOR => &entry.eventonly().entity,
        SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR => &entry.genloc().entity,
        SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR => &entry.fruloc().entity,
        SDR_RECORD_TYPE_MC_DEVICE_LOCATOR => &entry.mcloc().entity,
        SDR_RECORD_TYPE_ENTITY_ASSOC => &entry.entassoc().entity,
        else => null,
    };
}

/// `ipmi_sdr_find_sdr_byentity()`.
fn findSdrByentity(intf: *Intf, entity: *EntityId) callconv(.c) ?*SdrRecordList {
    if (!ensureIterator(intf)) return null;

    const head: *SdrRecordList = @ptrCast(@alignCast(
        c.malloc(@sizeOf(SdrRecordList)) orelse {
            c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
            return null;
        },
    ));
    @memset(std.mem.asBytes(head), 0);

    // Check what we have already read.
    var e = sdr_list_head;
    while (e) |entry| : (e = entry.next) {
        const ent = entityOfEntry(entry) orelse continue;
        if (ent.id == entity.id and
            (entity.instance.instance == 0x7f or
                ent.instance.instance == entity.instance.instance))
            _ = sdrListAdd(head, entry);
    }

    // Now keep looking.
    while (getNextHeader(intf, sdr_list_itr.?)) |header| {
        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                break;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);
        sdrr.id = header.id;
        sdrr.type = header.type;

        const rec = getRecord(intf, header, sdr_list_itr.?) orelse {
            c.free(sdrr);
            continue;
        };

        if (!isCachedRecordType(header.type)) {
            c.free(rec);
            c.free(sdrr);
            continue;
        }
        sdrr.record = rec;

        const ent = entityOfEntry(sdrr).?;
        if (ent.id == entity.id and
            (entity.instance.instance == 0x7f or
                ent.instance.instance == entity.instance.instance))
            _ = sdrListAdd(head, sdrr);

        cacheAppend(sdrr);
    }

    return head;
}

/// `ipmi_sdr_find_sdr_bytype()`.
fn findSdrBytype(intf: *Intf, rtype: u8) callconv(.c) ?*SdrRecordList {
    if (!ensureIterator(intf)) return null;

    const head: *SdrRecordList = @ptrCast(@alignCast(
        c.malloc(@sizeOf(SdrRecordList)) orelse {
            c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
            return null;
        },
    ));
    @memset(std.mem.asBytes(head), 0);

    // Check what we have already read.
    var e = sdr_list_head;
    while (e) |entry| : (e = entry.next) {
        if (entry.type == rtype) _ = sdrListAdd(head, entry);
    }

    // Now keep looking.
    while (getNextHeader(intf, sdr_list_itr.?)) |header| {
        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                break;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);
        sdrr.id = header.id;
        sdrr.type = header.type;

        const rec = getRecord(intf, header, sdr_list_itr.?) orelse {
            c.free(sdrr);
            continue;
        };

        if (!isCachedRecordType(header.type)) {
            c.free(rec);
            c.free(sdrr);
            continue;
        }
        sdrr.record = rec;

        if (header.type == rtype) _ = sdrListAdd(head, sdrr);

        cacheAppend(sdrr);
    }

    return head;
}

/// `ipmi_sdr_find_sdr_byid()`.
fn findSdrByid(intf: *Intf, id: [*:0]u8) callconv(.c) ?*SdrRecordList {
    var found = false;

    const idlen: c_int = @intCast(c.strlen(id));

    // Attempt to treat `id` as a number.
    var endptr: [*c]u8 = id;
    var num: c_int = @intCast(c.strtol(id, &endptr, 0));
    if (endptr[0] != 0) {
        // `endptr` is not at the end of `id`, so `id` is not a number.
        num = -1;
    }

    if (!ensureIterator(intf)) return null;

    // Check what we have already read.
    var e = sdr_list_head;
    while (e) |entry| : (e = entry.next) {
        var nameptr: ?[*]const u8 = null;
        var id_code: u8 = 0;
        var sensor_num: c_int = -1; // Assume N/A.
        switch (entry.type) {
            SDR_RECORD_TYPE_FULL_SENSOR => {
                const r = entry.full();
                nameptr = &r.id_string;
                id_code = r.id_code;
                sensor_num = r.cmn.keys.sensor_num;
            },
            SDR_RECORD_TYPE_COMPACT_SENSOR => {
                const r = entry.compact();
                nameptr = &r.id_string;
                id_code = r.id_code;
                sensor_num = r.cmn.keys.sensor_num;
            },
            SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
                const r = entry.eventonly();
                nameptr = &r.id_string;
                id_code = r.id_code;
                sensor_num = r.keys.sensor_num;
            },
            SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR => {
                const r = entry.genloc();
                nameptr = &r.id_string;
                id_code = r.id_code;
            },
            SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR => {
                const r = entry.fruloc();
                nameptr = &r.id_string;
                id_code = r.id_code;
            },
            SDR_RECORD_TYPE_MC_DEVICE_LOCATOR => {
                const r = entry.mcloc();
                nameptr = &r.id_string;
                id_code = r.id_code;
            },
            else => continue,
        }

        // If a numeric ID is requested compare it to the sensor number when
        // available; if the ID is a string compare it to the name.
        if ((num != -1 and num == sensor_num) or
            c.strncmp(@ptrCast(nameptr), id, @intCast(cmax(id_code & 0x1f, idlen))) == 0)
        {
            return entry;
        }
    }

    // Now keep looking.
    while (getNextHeader(intf, sdr_list_itr.?)) |header| {
        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                break;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);
        sdrr.id = header.id;
        sdrr.type = header.type;

        const rec = getRecord(intf, header, sdr_list_itr.?) orelse {
            c.free(sdrr);
            continue;
        };

        var nameptr: ?[*]const u8 = null;
        var id_code: u8 = 0;
        var sensor_num: c_int = -1; // Assume N/A.

        if (!isCachedRecordType(header.type)) {
            c.free(rec);
            c.free(sdrr);
            continue;
        }
        sdrr.record = rec;

        switch (header.type) {
            SDR_RECORD_TYPE_FULL_SENSOR => {
                const r = sdrr.full();
                nameptr = &r.id_string;
                id_code = r.id_code;
                sensor_num = r.cmn.keys.sensor_num;
            },
            SDR_RECORD_TYPE_COMPACT_SENSOR => {
                const r = sdrr.compact();
                nameptr = &r.id_string;
                id_code = r.id_code;
                sensor_num = r.cmn.keys.sensor_num;
            },
            SDR_RECORD_TYPE_EVENTONLY_SENSOR => {
                const r = sdrr.eventonly();
                nameptr = &r.id_string;
                id_code = r.id_code;
                sensor_num = r.keys.sensor_num;
            },
            SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR => {
                const r = sdrr.genloc();
                nameptr = &r.id_string;
                id_code = r.id_code;
            },
            SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR => {
                const r = sdrr.fruloc();
                nameptr = &r.id_string;
                id_code = r.id_code;
            },
            SDR_RECORD_TYPE_MC_DEVICE_LOCATOR => {
                const r = sdrr.mcloc();
                nameptr = &r.id_string;
                id_code = r.id_code;
            },
            // `SDR_RECORD_TYPE_ENTITY_ASSOC` leaves `nameptr` NULL.
            else => {},
        }

        if ((num != -1 and num == sensor_num) or
            (nameptr != null and
                c.strncmp(@ptrCast(nameptr), id, @intCast(cmax(id_code & 0x1f, idlen))) == 0))
        {
            found = true;
        }

        cacheAppend(sdrr);

        if (found) return sdrr;
    }

    return null;
}

/// The `__max()` macro from `helper.h`.
fn cmax(a: c_int, b: c_int) c_int {
    return if (a > b) a else b;
}

/// `struct __sdr_header` local to `ipmi_sdr_list_cache_fromfile()`.  Not
/// packed in the C, so `id` is naturally aligned and the struct is 6 bytes
/// even though only 5 are read.
const SdrFileHeader = extern struct {
    id: u16 = 0,
    version: u8 = 0,
    type: u8 = 0,
    length: u8 = 0,
};

/// `ipmi_sdr_list_cache_fromfile()`.
fn listCacheFromfile(ifile: ?[*:0]const u8) callconv(.c) c_int {
    var header: SdrFileHeader = .{};
    var ret: c_int = 0;
    var count: c_int = 0;
    var bc: c_int = 0;

    const file = ifile orelse {
        c.lprintf(c.LOG_ERR, "No SDR cache filename given");
        return -1;
    };

    const fp = c.ipmi_open_file_read(file) orelse {
        c.lprintf(c.LOG_ERR, "Unable to open SDR cache %s for reading", file);
        return -1;
    };

    while (c.feof(fp) == 0) {
        header = .{};
        bc = @intCast(c.fread(&header, 1, 5, fp));
        if (bc <= 0) break;

        if (bc != 5) {
            c.lprintf(c.LOG_ERR, "header read %d bytes, expected 5", bc);
            ret = -1;
            break;
        }

        if (header.length == 0) continue;

        if (header.version != 0x51 and
            header.version != 0x01 and
            header.version != 0x02)
        {
            c.lprintf(
                c.LOG_WARN,
                "invalid sdr header version %02x",
                @as(c_uint, header.version),
            );
            ret = -1;
            break;
        }

        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                ret = -1;
                break;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);

        sdrr.id = header.id;
        sdrr.type = header.type;

        const rec: [*]u8 = @ptrCast(c.malloc(@as(usize, header.length) + 1) orelse {
            c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
            ret = -1;
            c.free(sdrr);
            break;
        });
        @memset(rec[0 .. @as(usize, header.length) + 1], 0);

        bc = @intCast(c.fread(rec, 1, header.length, fp));
        if (bc != header.length) {
            c.lprintf(
                c.LOG_ERR,
                "record %04x read %d bytes, expected %d",
                @as(c_uint, header.id),
                bc,
                @as(c_int, header.length),
            );
            ret = -1;
            c.free(sdrr);
            c.free(rec);
            break;
        }

        if (!isCachedRecordType(header.type)) {
            c.free(rec);
            c.free(sdrr);
            continue;
        }
        sdrr.record = rec;

        cacheAppend(sdrr);

        count += 1;

        c.lprintf(
            c.LOG_DEBUG,
            "Read record %04x from file into cache",
            @as(c_uint, sdrr.id),
        );
    }

    if (sdr_list_itr == null) {
        sdr_list_itr = @ptrCast(@alignCast(c.malloc(@sizeOf(SdrIterator))));
        if (sdr_list_itr) |itr| {
            itr.reservation = 0;
            itr.total = count;
            itr.next = 0xffff;
        }
    }

    _ = c.fclose(fp);
    return ret;
}

/// `struct get_sdr_repository_info_rsp`.
const GetSdrRepositoryInfoRsp = extern struct {
    sdr_version: u8 = 0,
    record_count_lsb: u8 = 0,
    record_count_msb: u8 = 0,
    free_space: [2]u8 = @splat(0),
    most_recent_addition_timestamp: [4]u8 = @splat(0),
    most_recent_erase_timestamp: [4]u8 = @splat(0),
    flags: switch (endian) {
        .little => packed struct(u8) {
            get_sdr_repository_allow_info_supported: u1 = 0,
            reserve_sdr_repository_supported: u1 = 0,
            partial_add_sdr_supported: u1 = 0,
            delete_sdr_supported: u1 = 0,
            __reserved1: u1 = 0,
            modal_update_support: u2 = 0,
            overflow_flag: u1 = 0,
        },
        .big => packed struct(u8) {
            overflow_flag: u1 = 0,
            modal_update_support: u2 = 0,
            __reserved1: u1 = 0,
            delete_sdr_supported: u1 = 0,
            partial_add_sdr_supported: u1 = 0,
            reserve_sdr_repository_supported: u1 = 0,
            get_sdr_repository_allow_info_supported: u1 = 0,
        },
    } = .{},
};

comptime {
    abi.assertOpaqueLayout(GetSdrRepositoryInfoRsp, .{
        .size = c.ABI_SIZEOF_get_sdr_repository_info_rsp,
        .alignment = 1,
        .fields = &.{
            .{
                .name = "record_count_lsb",
                .offset = c.ABI_OFFSETOF_get_sdr_repository_info_rsp__record_count_lsb,
            },
            .{
                .name = "record_count_msb",
                .offset = c.ABI_OFFSETOF_get_sdr_repository_info_rsp__record_count_msb,
            },
            .{
                .name = "free_space",
                .offset = c.ABI_OFFSETOF_get_sdr_repository_info_rsp__free_space,
            },
            .{
                .name = "most_recent_addition_timestamp",
                .offset = c.ABI_OFFSETOF_get_sdr_repository_info_rsp__most_recent_addition_timestamp,
            },
            .{
                .name = "most_recent_erase_timestamp",
                .offset = c.ABI_OFFSETOF_get_sdr_repository_info_rsp__most_recent_erase_timestamp,
            },
        },
    });
}

/// `ipmi32toh()`: 32 bits little endian out of four bytes.
fn ipmi32toh(m: *const [4]u8) u32 {
    return @as(u32, m[3]) << 24 | @as(u32, m[2]) << 16 |
        @as(u32, m[1]) << 8 | @as(u32, m[0]);
}

/// `ipmi_sdr_get_info()`.
fn getInfo(intf: *Intf, sdr_repository_info: *GetSdrRepositoryInfoRsp) callconv(.c) c_int {
    var req: Request = std.mem.zeroes(Request);

    req.msg.netfn_lun.netfn = netfn_storage; // 0x0A
    req.msg.cmd = @intCast(c.IPMI_GET_SDR_REPOSITORY_INFO); // 0x20
    req.msg.data = null;
    req.msg.data_len = 0;

    const rsp = sendrecv(intf, &req) orelse {
        c.lprintf(c.LOG_ERR, "Get SDR Repository Info command failed");
        return -1;
    };
    if (rsp.ccode != 0) {
        c.lprintf(
            c.LOG_ERR,
            "Get SDR Repository Info command failed: %s",
            ccString(rsp.ccode),
        );
        return -1;
    }

    const n = @min(@sizeOf(GetSdrRepositoryInfoRsp), @as(usize, @intCast(rsp.data_len)));
    @memcpy(std.mem.asBytes(sdr_repository_info)[0..n], rsp.data[0..n]);

    return 0;
}

/// `ipmi_sdr_print_info()`.
fn printInfo(intf: *Intf) callconv(.c) c_int {
    var info: GetSdrRepositoryInfoRsp = .{};

    if (getInfo(intf, &info) != 0) return -1;

    _ = c.printf(
        "SDR Version                         : 0x%x\n",
        @as(c_uint, info.sdr_version),
    );
    _ = c.printf(
        "Record Count                        : %d\n",
        (@as(c_int, info.record_count_msb) << 8) | @as(c_int, info.record_count_lsb),
    );

    const free_space: u16 =
        (@as(u16, info.free_space[1]) << 8) | @as(u16, info.free_space[0]);

    _ = c.printf("Free Space                          : ");
    switch (free_space) {
        0x0000 => _ = c.printf("none (full)\n"),
        0xffff => _ = c.printf("unspecified\n"),
        0xfffe => _ = c.printf("> 64Kb - 2 bytes\n"),
        else => _ = c.printf("%d bytes\n", @as(c_int, free_space)),
    }

    _ = c.printf("Most recent Addition                : ");
    if (info.flags.partial_add_sdr_supported != 0) {
        const timestamp: c.time_t = @intCast(ipmi32toh(&info.most_recent_addition_timestamp));
        _ = c.printf("%s\n", c.ipmi_timestamp_numeric(@truncate(@as(u64, @bitCast(timestamp)))));
    } else {
        _ = c.printf("NA\n");
    }

    _ = c.printf("Most recent Erase                   : ");
    if (info.flags.delete_sdr_supported != 0) {
        const timestamp: c.time_t = @intCast(ipmi32toh(&info.most_recent_erase_timestamp));
        _ = c.printf("%s\n", c.ipmi_timestamp_numeric(@truncate(@as(u64, @bitCast(timestamp)))));
    } else {
        _ = c.printf("NA\n");
    }

    _ = c.printf(
        "SDR overflow                        : %s\n",
        pick(info.flags.overflow_flag != 0, "yes", "no"),
    );

    _ = c.printf("SDR Repository Update Support       : ");
    switch (info.flags.modal_update_support) {
        0 => _ = c.printf("unspecified\n"),
        1 => _ = c.printf("non-modal\n"),
        2 => _ = c.printf("modal\n"),
        3 => _ = c.printf("modal and non-modal\n"),
    }

    _ = c.printf(
        "Delete SDR supported                : %s\n",
        pick(info.flags.delete_sdr_supported != 0, "yes", "no"),
    );
    _ = c.printf(
        "Partial Add SDR supported           : %s\n",
        pick(info.flags.partial_add_sdr_supported != 0, "yes", "no"),
    );
    _ = c.printf(
        "Reserve SDR repository supported    : %s\n",
        pick(info.flags.reserve_sdr_repository_supported != 0, "yes", "no"),
    );
    _ = c.printf(
        "SDR Repository Alloc info supported : %s\n",
        pick(info.flags.get_sdr_repository_allow_info_supported != 0, "yes", "no"),
    );

    return 0;
}

/// `ipmi_sdr_dump_bin()`: write the raw SDR to a binary file.
fn dumpBin(intf: *Intf, ofile: [*:0]const u8) c_int {
    var rc: c_int = 0;

    // Open a connection to the SDR.
    const itr = sdrStart(intf, 0) orelse {
        c.lprintf(c.LOG_ERR, "Unable to open SDR for reading");
        return -1;
    };

    _ = c.printf("Dumping Sensor Data Repository to '%s'\n", ofile);

    // Generate the list of records.
    while (getNextHeader(intf, itr)) |header| {
        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                return -1;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);

        c.lprintf(
            c.LOG_INFO,
            "Record ID %04x (%d bytes)",
            @as(c_uint, header.id),
            @as(c_int, header.length),
        );

        sdrr.id = header.id;
        sdrr.version = header.version;
        sdrr.type = header.type;
        sdrr.length = header.length;
        sdrr.raw = getRecord(intf, header, itr);

        if (sdrr.raw == null) {
            c.lprintf(
                c.LOG_ERR,
                "ipmitool: cannot obtain SDR record %04x",
                @as(c_uint, header.id),
            );
            c.free(sdrr);
            return -1;
        }

        cacheAppend(sdrr);
    }

    sdrEnd(itr);

    // Now write to the file.
    const fp = c.ipmi_open_file_write(ofile) orelse return -1;

    var e = sdr_list_head;
    while (e) |sdrr| : (e = sdrr.next) {
        var h: [5]u8 = undefined;

        // Build and write the SDR header.
        h[0] = @truncate(sdrr.id & 0xff); // LS byte first.
        h[1] = @truncate((sdrr.id >> 8) & 0xff);
        h[2] = sdrr.version;
        h[3] = sdrr.type;
        h[4] = sdrr.length;

        var r: c_int = @intCast(c.fwrite(&h, 1, 5, fp));
        if (r != 5) {
            c.lprintf(c.LOG_ERR, "Error writing header to output file %s", ofile);
            rc = -1;
            break;
        }

        // Write the SDR entry.
        const raw = sdrr.raw orelse {
            c.lprintf(
                c.LOG_ERR,
                "Error: raw data is null (length=%d)",
                @as(c_int, sdrr.length),
            );
            rc = -1;
            break;
        };
        r = @intCast(c.fwrite(raw, 1, sdrr.length, fp));
        if (r != sdrr.length) {
            c.lprintf(
                c.LOG_ERR,
                "Error writing %d record bytes to output file %s",
                @as(c_int, sdrr.length),
                ofile,
            );
            rc = -1;
            break;
        }
    }
    _ = c.fclose(fp);

    return rc;
}

/// `ipmi_sdr_print_type()`: print all sensors of the specified type.
fn printType(intf: *Intf, rtype: [*c]u8) callconv(.c) c_int {
    var rc: c_int = 0;
    var x: c_int = 0;
    var sensor_type: u8 = 0;

    if (rtype == null or
        c.strcasecmp(rtype, "help") == 0 or
        c.strcasecmp(rtype, "list") == 0)
    {
        printSensorTypes();
        return 0;
    }

    if (c.strncmp(rtype, "0x", 2) == 0) {
        // Begins with `0x`, so let it be entered as a raw hex value.
        if (c.str2uchar(rtype, &sensor_type) != 0) {
            c.lprintf(
                c.LOG_ERR,
                "Given type of sensor \"%s\" is either invalid or out of range.",
                rtype,
            );
            return -1;
        }
    } else {
        x = 1;
        while (x < sensor_type_max) : (x += 1) {
            if (c.strcasecmp(sensor_type_desc[@intCast(x)], rtype) == 0) {
                sensor_type = @intCast(x);
                break;
            }
        }
        if (sensor_type != x) {
            c.lprintf(c.LOG_ERR, "Sensor Type \"%s\" not found.", rtype);
            printSensorTypes();
            return 0;
        }
    }

    const list = findSdrBysensortype(intf, sensor_type);

    var entry = list;
    while (entry) |e| : (entry = e.next) {
        rc = printListentry(intf, e);
    }

    sdrListEmptyLow(list);

    return rc;
}

/// The two-column sensor type table `ipmi_sdr_print_type()` prints twice.
fn printSensorTypes() void {
    _ = c.printf("Sensor Types:\n");
    var x: usize = 1;
    while (x < sensor_type_max) : (x += 2) {
        _ = c.printf(
            "\t%-25s (0x%02x)   %-25s (0x%02x)\n",
            sensor_type_desc[x],
            @as(c_uint, @intCast(x)),
            sensor_type_desc[x + 1],
            @as(c_uint, @intCast(x + 1)),
        );
    }
}

/// `ipmi_sdr_print_entity()`.
fn printEntity(intf: *Intf, entitystr: [*c]u8) callconv(.c) c_int {
    var entity: EntityId = undefined;
    var id: c_uint = 0;
    var instance: c_uint = 0;
    var rc: c_int = 0;

    if (entitystr == null or
        c.strcasecmp(entitystr, "help") == 0 or
        c.strcasecmp(entitystr, "list") == 0)
    {
        c.print_valstr_2col(c.entity_id_vals, "Entity IDs", -1);
        return 0;
    }

    if (c.sscanf(entitystr, "%u.%u", &id, &instance) != 2) {
        // Perhaps no instance was passed, in which case we want all instances
        // for this entity, so set `entity.instance` to 0x7f to indicate that.
        if (c.sscanf(entitystr, "%u", &id) != 1) {
            var j: c_int = 0;

            // Now try string input.
            var i: usize = 0;
            while (c.entity_id_vals[i].str != null) : (i += 1) {
                if (c.strcasecmp(entitystr, c.entity_id_vals[i].str) == 0) {
                    entity.id = @truncate(c.entity_id_vals[i].val);
                    entity.instance.instance = 0x7f;
                    j = 1;
                }
            }
            if (j == 0) {
                c.lprintf(c.LOG_ERR, "Invalid entity: %s", entitystr);
                return -1;
            }
        } else {
            entity.id = @truncate(id);
            entity.instance.instance = 0x7f;
        }
    } else {
        entity.id = @truncate(id);
        entity.instance.instance = @truncate(instance);
    }

    const list = findSdrByentity(intf, &entity);

    var entry = list;
    while (entry) |e| : (entry = e.next) {
        rc = printListentry(intf, e);
    }

    sdrListEmptyLow(list);

    return rc;
}

/// `ipmi_sdr_print_entry_byid()`.
fn printEntryByid(intf: *Intf, argc: c_int, argv: [*c][*c]u8) c_int {
    var rc: c_int = 0;

    if (argc < 1) {
        c.lprintf(c.LOG_ERR, "No Sensor ID supplied");
        return -1;
    }

    const v = c.verbose;
    c.verbose = 1;

    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const sdr = findSdrByid(intf, @ptrCast(argv[i]));
        if (sdr == null) {
            c.lprintf(c.LOG_ERR, "Unable to find sensor id '%s'", argv[i]);
        } else {
            if (printListentry(intf, sdr.?) < 0) rc = -1;
        }
    }

    c.verbose = v;

    return rc;
}

/// `ipmi_sdr_main()`: the top-level `sdr` command handler.
fn sdrMain(intf: *Intf, argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    var rc: c_int = 0;

    // Initialize the random numbers used later.
    c.srand(@intCast(c.time(null)));

    if (argc == 0) {
        return printSdr(intf, 0xfe);
    } else if (eql(argv[0], "help")) {
        printfSdrUsage();
    } else if (eql(argv[0], "list") or eql(argv[0], "elist")) {
        sdr_extended = if (eql(argv[0], "elist")) 1 else 0;

        if (argc <= 1) {
            rc = printSdr(intf, 0xfe);
        } else if (eql(argv[1], "all")) {
            rc = printSdr(intf, 0xff);
        } else if (eql(argv[1], "full")) {
            rc = printSdr(intf, SDR_RECORD_TYPE_FULL_SENSOR);
        } else if (eql(argv[1], "compact")) {
            rc = printSdr(intf, SDR_RECORD_TYPE_COMPACT_SENSOR);
        } else if (eql(argv[1], "event")) {
            rc = printSdr(intf, SDR_RECORD_TYPE_EVENTONLY_SENSOR);
        } else if (eql(argv[1], "mcloc")) {
            rc = printSdr(intf, SDR_RECORD_TYPE_MC_DEVICE_LOCATOR);
        } else if (eql(argv[1], "fru")) {
            rc = printSdr(intf, SDR_RECORD_TYPE_FRU_DEVICE_LOCATOR);
        } else if (eql(argv[1], "generic")) {
            rc = printSdr(intf, SDR_RECORD_TYPE_GENERIC_DEVICE_LOCATOR);
        } else if (eql(argv[1], "help")) {
            c.lprintf(
                c.LOG_NOTICE,
                "usage: sdr %s [all|full|compact|event|mcloc|fru|generic]",
                argv[0],
            );
            return 0;
        } else {
            c.lprintf(c.LOG_ERR, "Invalid SDR %s command: %s", argv[0], argv[1]);
            c.lprintf(
                c.LOG_NOTICE,
                "usage: sdr %s [all|full|compact|event|mcloc|fru|generic]",
                argv[0],
            );
            return -1;
        }
    } else if (eql(argv[0], "type")) {
        sdr_extended = 1;
        rc = printType(intf, argv[1]);
    } else if (eql(argv[0], "entity")) {
        sdr_extended = 1;
        rc = printEntity(intf, argv[1]);
    } else if (eql(argv[0], "info")) {
        rc = printInfo(intf);
    } else if (eql(argv[0], "get")) {
        rc = printEntryByid(intf, argc - 1, &argv[1]);
    } else if (eql(argv[0], "dump")) {
        if (argc < 2) {
            c.lprintf(c.LOG_ERR, "Not enough parameters given.");
            c.lprintf(c.LOG_NOTICE, "usage: sdr dump <file>");
            return -1;
        }
        rc = dumpBin(intf, @ptrCast(argv[1]));
    } else if (eql(argv[0], "fill")) {
        if (argc <= 1) {
            c.lprintf(c.LOG_ERR, "Not enough parameters given.");
            c.lprintf(c.LOG_NOTICE, "usage: sdr fill sensors");
            c.lprintf(c.LOG_NOTICE, "usage: sdr fill file <file>");
            c.lprintf(c.LOG_NOTICE, "usage: sdr fill range <range>");
            return -1;
        } else if (eql(argv[1], "sensors")) {
            rc = sdrAddFromSensors(intf, 21);
        } else if (eql(argv[1], "nosat")) {
            rc = sdrAddFromSensors(intf, 0);
        } else if (eql(argv[1], "file")) {
            if (argc < 3) {
                c.lprintf(c.LOG_ERR, "Not enough parameters given.");
                c.lprintf(c.LOG_NOTICE, "usage: sdr fill file <file>");
                return -1;
            }
            rc = sdrAddFromFile(intf, @ptrCast(argv[2]));
        } else if (eql(argv[1], "range")) {
            if (argc < 3) {
                c.lprintf(c.LOG_ERR, "Not enough parameters given.");
                c.lprintf(c.LOG_NOTICE, "usage: sdr fill range <range>");
                return -1;
            }
            rc = sdrAddFromList(intf, @ptrCast(argv[2]));
        } else {
            c.lprintf(c.LOG_ERR, "Invalid SDR %s command: %s", argv[0], argv[1]);
            c.lprintf(
                c.LOG_NOTICE,
                "usage: sdr %s <sensors|nosat|file|range> [options]",
                argv[0],
            );
            return -1;
        }
    } else {
        c.lprintf(c.LOG_ERR, "Invalid SDR command: %s", argv[0]);
        rc = -1;
    }

    return rc;
}

/// `printf_sdr_usage()`.
fn printfSdrUsage() callconv(.c) void {
    c.lprintf(c.LOG_NOTICE, "usage: sdr <command> [options]");
    c.lprintf(c.LOG_NOTICE, "               list | elist [option]");
    c.lprintf(c.LOG_NOTICE, "                     all           All SDR Records");
    c.lprintf(c.LOG_NOTICE, "                     full          Full Sensor Record");
    c.lprintf(c.LOG_NOTICE, "                     compact       Compact Sensor Record");
    c.lprintf(c.LOG_NOTICE, "                     event         Event-Only Sensor Record");
    c.lprintf(c.LOG_NOTICE, "                     mcloc         Management Controller Locator Record");
    c.lprintf(c.LOG_NOTICE, "                     fru           FRU Locator Record");
    c.lprintf(c.LOG_NOTICE, "                     generic       Generic Device Locator Record\n");
    c.lprintf(c.LOG_NOTICE, "               type [option]");
    c.lprintf(c.LOG_NOTICE, "                     <Sensor_Type> Retrieve the state of specified sensor.");
    c.lprintf(c.LOG_NOTICE, "                                   Sensor_Type can be specified either as");
    c.lprintf(c.LOG_NOTICE, "                                   a string or a hex value.");
    c.lprintf(c.LOG_NOTICE, "                     list          Get a list of available sensor types\n");
    c.lprintf(c.LOG_NOTICE, "               get <Sensor_ID>");
    c.lprintf(c.LOG_NOTICE, "                     Retrieve state of the first sensor matched by Sensor_ID\n");
    c.lprintf(c.LOG_NOTICE, "               info");
    c.lprintf(c.LOG_NOTICE, "                     Display information about the repository itself\n");
    c.lprintf(c.LOG_NOTICE, "               entity <Entity_ID>[.<Instance_ID>]");
    c.lprintf(c.LOG_NOTICE, "                     Display all sensors associated with an entity\n");
    c.lprintf(c.LOG_NOTICE, "               dump <file>");
    c.lprintf(c.LOG_NOTICE, "                     Dump raw SDR data to a file\n");
    c.lprintf(c.LOG_NOTICE, "               fill <option>");
    c.lprintf(c.LOG_NOTICE, "                     sensors       Creates the SDR repository for the current");
    c.lprintf(c.LOG_NOTICE, "                                   configuration");
    c.lprintf(c.LOG_NOTICE, "                     nosat         Creates the SDR repository for the current");
    c.lprintf(c.LOG_NOTICE, "                                   configuration, without satellite scan");
    c.lprintf(c.LOG_NOTICE, "                     file <file>   Load SDR repository from a file");
    c.lprintf(c.LOG_NOTICE, "                     range <range> Load SDR repository from a provided list");
    c.lprintf(c.LOG_NOTICE, "                                   or range. Use ',' for list or '-' for");
    c.lprintf(c.LOG_NOTICE, "                                   range, eg. 0x28,0x32,0x40-0x44");
}

/// `ipmi_sdr_list_cache()`.
fn listCache(intf: *Intf) callconv(.c) c_int {
    if (!ensureIterator(intf)) return -1;

    while (getNextHeader(intf, sdr_list_itr.?)) |header| {
        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                break;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);
        sdrr.id = header.id;
        sdrr.type = header.type;

        const rec = getRecord(intf, header, sdr_list_itr.?) orelse {
            c.free(sdrr);
            continue;
        };

        if (!isCachedRecordType(header.type)) {
            c.free(rec);
            c.free(sdrr);
            continue;
        }
        sdrr.record = rec;

        cacheAppend(sdrr);
    }

    return 0;
}

// ---------------------------------------------------------------------------
// lib/ipmi_sdradd.c
//
// Functions to program the SDR repository, from built-in sensors or from
// sensors dumped in a binary file.
// ---------------------------------------------------------------------------

const ADD_PARTIAL_SDR: u8 = 0x25;

/// `struct sdr_add_rq`.  The C declares `data[1]` and over-allocates, so the
/// mirror carries only the fixed header and the payload is addressed through
/// `dataPtr()`.
const SdrAddRq = extern struct {
    reserve_id: u16 align(1) = 0,
    id: u16 align(1) = 0,
    offset: u8 = 0,
    /// 0 == partial, 1 == last.
    in_progress: u8 = 0,
    data: [1]u8 = @splat(0),

    fn dataPtr(self: *SdrAddRq) [*]u8 {
        return @ptrCast(&self.data);
    }
};

const PARTIAL_ADD: u8 = 0;
const LAST_RECORD: u8 = 1;

/// `struct sdrr_queue`.
const SdrrQueue = struct {
    head: ?*SdrRecordList = null,
    tail: ?*SdrRecordList = null,
};

/// This was formerly initialized to 24; reduced to 19 so the overall message
/// fits into the recommended 32 byte limit.
var sdr_max_write_len: c_int = 19;

fn partialSend(intf: *Intf, req: *Request, id: *u16) c_int {
    const rsp = sendrecv(intf, req) orelse return -1;

    if (rsp.ccode != 0 or rsp.data_len < 2) return -1;

    id.* = @as(u16, rsp.data[0]) +% (@as(u16, rsp.data[1]) << 8);
    return 0;
}

/// `ipmi_sdr_add_record()`.
fn sdrAddRecord(intf: *Intf, sdrr: *SdrRecordList) callconv(.c) c_int {
    var reserve_id: u16 = 0;
    var id: u16 = 0;
    const len: c_int = sdrr.length;
    var rc: c_int = 0;

    // Actually no SDR to program.
    if (len < 1 or sdrr.raw == null) {
        c.lprintf(c.LOG_ERR, "ipmitool: bad record , skipped");
        return 0;
    }

    if (getReservation(intf, 0, &reserve_id) != 0) {
        c.lprintf(c.LOG_ERR, "ipmitool: reservation failed");
        return -1;
    }

    const sdr_rq: *SdrAddRq = @ptrCast(@alignCast(
        c.malloc(@sizeOf(SdrAddRq) + @as(usize, @intCast(sdr_max_write_len))) orelse {
            c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
            return -1;
        },
    ));
    sdr_rq.reserve_id = reserve_id;
    sdr_rq.in_progress = PARTIAL_ADD;

    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = ADD_PARTIAL_SDR;
    req.msg.data = @ptrCast(sdr_rq);

    // The header first.
    sdr_rq.id = 0;
    sdr_rq.offset = 0;
    const d = sdr_rq.dataPtr();
    d[0] = @truncate(sdrr.id & 0xff);
    d[1] = @truncate((sdrr.id >> 8) & 0xff);
    d[2] = sdrr.version;
    d[3] = sdrr.type;
    d[4] = sdrr.length;
    req.msg.data_len = 5 + @sizeOf(SdrAddRq) - 1;

    if (partialSend(intf, &req, &id) != 0) {
        c.lprintf(c.LOG_ERR, "ipmitool: partial send error");
        c.free(sdr_rq);
        return -1;
    }

    var i: c_int = 0;

    // The SDR entry.
    while (i < len) {
        var data_len: c_int = 0;
        if ((len - i) <= sdr_max_write_len) {
            // The last crunch.
            data_len = len - i;
            sdr_rq.in_progress = LAST_RECORD;
        } else {
            data_len = sdr_max_write_len;
        }

        sdr_rq.id = id;
        sdr_rq.offset = @truncate(@as(c_uint, @bitCast(i + 5)));
        @memcpy(d[0..@intCast(data_len)], sdrr.raw.?[@intCast(i)..][0..@intCast(data_len)]);
        req.msg.data_len = @intCast(data_len + @sizeOf(SdrAddRq) - 1);

        rc = partialSend(intf, &req, &id);
        if (rc != 0) {
            c.lprintf(c.LOG_ERR, "ipmitool: partial add failed");
            break;
        }

        i += data_len;
    }

    c.free(sdr_rq);
    return rc;
}

/// `ipmi_sdr_repo_clear()`.
fn sdrRepoClear(intf: *Intf) c_int {
    var msg_data: [8]u8 = @splat(0);
    var reserve_id: u16 = 0;

    if (getReservation(intf, 0, &reserve_id) != 0) return -1;

    var req: Request = std.mem.zeroes(Request);
    req.msg.netfn_lun.netfn = netfn_storage;
    req.msg.cmd = 0x27; // FIXME
    req.msg.data = &msg_data;
    req.msg.data_len = 6;

    msg_data[0] = @truncate(reserve_id & 0xff);
    msg_data[1] = @truncate(reserve_id >> 8);
    msg_data[2] = 'C';
    msg_data[3] = 'L';
    msg_data[4] = 'R';
    msg_data[5] = 0xaa;

    var attempt: c_int = 0;
    while (attempt < 5) : (attempt += 1) {
        const rsp = sendrecv(intf, &req) orelse {
            c.lprintf(c.LOG_ERR, "Unable to clear SDRR");
            return -1;
        };
        if (rsp.ccode != 0) {
            c.lprintf(c.LOG_ERR, "Unable to clear SDRR: %s", ccString(rsp.ccode));
            return -1;
        }
        if ((rsp.data[0] & 1) == 1) {
            _ = c.printf("SDRR successfully erased\n");
            return 0;
        }
        _ = c.printf("Wait for SDRR erasure completed...\n");
        msg_data[5] = 0;
        _ = c.sleep(1);
    }

    // If we are here we are fed up trying to erase.
    return -1;
}

/// `sdrr_get_records()`: collect every SDR record into `queue`.
fn sdrrGetRecords(intf: *Intf, itr: *SdrIterator, queue: *SdrrQueue) c_int {
    queue.head = null;
    queue.tail = null;

    while (getNextHeader(intf, itr)) |header| {
        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                return -1;
            },
        ));
        @memset(std.mem.asBytes(sdrr), 0);

        sdrr.id = header.id;
        sdrr.version = header.version;
        sdrr.type = header.type;
        sdrr.length = header.length;
        sdrr.raw = getRecord(intf, header, itr);
        _ = printNameFromRawentry(sdrr.id, sdrr.type, sdrr.raw);

        // Put it in the record queue.
        if (queue.head == null) {
            queue.head = sdrr;
        } else {
            queue.tail.?.next = sdrr;
        }
        queue.tail = sdrr;
    }
    return 0;
}

/// `sdr_copy_to_sdrr()`.
fn sdrCopyToSdrr(intf: *Intf, use_builtin: c_int, from_addr: c_int, to_addr: c_int) c_int {
    var rc: c_int = undefined;
    var sdrr_queue: SdrrQueue = undefined;

    // Generate the list of records for this target.
    intf.target_addr = @bitCast(from_addr);

    // Initialize the iterator.
    const itr = sdrStart(intf, use_builtin) orelse return 0;

    _ = c.printf("Load SDRs from 0x%x\n", from_addr);
    rc = sdrrGetRecords(intf, itr, &sdrr_queue);
    sdrEnd(itr);

    // Write the SDRs to the destination SDR repository.
    intf.target_addr = @bitCast(to_addr);
    var sdrr = sdrr_queue.head;
    while (sdrr) |entry| {
        const sdrr_next = entry.next;
        rc = sdrAddRecord(intf, entry);
        if (rc < 0) {
            c.lprintf(
                c.LOG_ERR,
                "Cannot add SDR ID 0x%04x to repository...",
                @as(c_uint, entry.id),
            );
        }
        c.free(entry);
        sdrr = sdrr_next;
    }
    return rc;
}

/// `ipmi_sdr_add_from_sensors()`.
fn sdrAddFromSensors(intf: *Intf, maxslot: c_int) callconv(.c) c_int {
    var rc: c_int = 0;
    const myaddr: c_int = @bitCast(intf.target_addr);

    if (sdrRepoClear(intf) != 0) {
        c.lprintf(c.LOG_ERR, "Cannot erase SDRR. Give up.");
        return -1;
    }

    // First fill the SDRR from local built-in sensors.
    rc = sdrCopyToSdrr(intf, 1, myaddr, myaddr);

    // Now fill the SDRR with remote sensors.
    if (maxslot != 0) {
        var i: c_int = 0;
        var slave_addr: c_int = 0xb0;
        while (i < maxslot) : ({
            i += 1;
            slave_addr += 2;
        }) {
            // A hole in the PICMG 2.9 mapping.
            if (slave_addr == 0xc2) slave_addr += 2;
            if (sdrCopyToSdrr(intf, 0, slave_addr, myaddr) < 0) {
                rc = -1;
            }
        }
    }
    return rc;
}

/// `ipmi_hex_to_dec()`.
fn hexToDec(strchar: [*c]u8, p_dec_value: *u8) callconv(.c) c_int {
    var rc: c_int = -1;
    var ret_value: u8 = 0;

    if (c.strlen(strchar) == 4 and strchar[0] == '0' and strchar[1] == 'x') {
        rc = 0;

        if (strchar[2] >= '0' and strchar[2] <= '9') {
            ret_value +%= (strchar[2] - '0') *% 16;
        } else if (strchar[2] >= 'a' and strchar[2] <= 'f') {
            ret_value +%= ((strchar[2] - 'a') +% 10) *% 16;
        } else if (strchar[2] >= 'A' and strchar[2] <= 'F') {
            ret_value +%= ((strchar[2] - 'A') +% 10) *% 16;
        } else {
            rc = -1;
        }

        if (strchar[3] >= '0' and strchar[3] <= '9') {
            ret_value +%= strchar[3] - '0';
        } else if (strchar[3] >= 'a' and strchar[3] <= 'f') {
            ret_value +%= (strchar[3] - 'a') +% 10;
        } else if (strchar[3] >= 'A' and strchar[3] <= 'F') {
            ret_value +%= (strchar[3] - 'A') +% 10;
        } else {
            rc = -1;
        }
    }

    if (rc == 0) {
        p_dec_value.* = ret_value;
    } else {
        c.lprintf(c.LOG_ERR, "Must be Hex value of 4 characters (Ex.: 0x24)");
    }

    return rc;
}

const MAX_NUM_SLOT = 128;

/// `ipmi_parse_range_list()`.
fn parseRangeList(range_list: [*c]const u8, p_hex_list: [*c]u8) callconv(.c) c_int {
    var rc: c_int = -1;

    var list_offset: u8 = 0;
    var next_string: [*c]u8 = undefined;
    var range_string: [*c]u8 = undefined;
    var in_process_string: [*c]u8 = @constCast(range_list);

    // Discard the empty string.
    if (c.strlen(range_list) == 0) {
        return rc;
    }

    // First, cut to a comma separated string.
    next_string = c.strstr(@constCast(range_list), ",");

    if (next_string != range_list) {
        var is_last: u8 = undefined;
        // We have a valid string so far.
        rc = 0;

        while (true) {
            if (next_string != null) {
                next_string[0] = 0;
                next_string += 1;
                is_last = 0;
            } else {
                is_last = 1;
            }

            // At this point it is a single entry or a range.
            range_string = c.strstr(in_process_string, "-");
            if (range_string == null) {
                var dec_value: u8 = 0;

                // A single entry.
                rc = hexToDec(in_process_string, &dec_value);

                if (rc == 0) {
                    if ((dec_value % 2) == 0) {
                        p_hex_list[list_offset] = dec_value;
                        list_offset +%= 1;
                    } else {
                        c.lprintf(c.LOG_ERR, "I2C address provided value must be even.");
                    }
                }
            } else {
                var start_value: u8 = 0;
                var end_value: u8 = 0;

                range_string[0] = 0; // Cut the string.
                range_string += 1;

                // A range.
                rc = hexToDec(in_process_string, &start_value);
                if (rc == 0) rc = hexToDec(range_string, &end_value);

                if (rc == 0) {
                    if ((start_value % 2) == 0 and (end_value % 2) == 0) {
                        while (true) {
                            p_hex_list[list_offset] = start_value;
                            list_offset +%= 1;
                            start_value +%= 2;
                            if (start_value == end_value) break;
                        }
                        p_hex_list[list_offset] = end_value;
                        list_offset +%= 1;
                    } else {
                        c.lprintf(c.LOG_ERR, "I2C address provided value must be even.");
                    }
                }
            }

            if (is_last == 0) {
                // Set up for the next string.
                in_process_string = next_string;
                next_string = c.strstr(@constCast(range_list), ",");
            }

            if (!(is_last == 0 and rc == 0)) break;
        }
    }

    return rc;
}

/// `ipmi_sdr_add_from_list()`.
fn sdrAddFromList(intf: *Intf, range_list: [*c]const u8) callconv(.c) c_int {
    var rc: c_int = 0;
    const myaddr: c_int = @bitCast(intf.target_addr);
    var list_value: [MAX_NUM_SLOT]u8 = undefined;

    @memset(&list_value, 0);

    // Build the list from the string.
    if (parseRangeList(range_list, &list_value) != 0) {
        c.lprintf(c.LOG_ERR, "Range - List invalid, cannot be parsed.");
        return -1;
    }

    {
        var counter: u8 = 0;
        _ = c.printf("List to scan: (Built-in) ");
        while (list_value[counter] != 0) {
            _ = c.printf("%02x ", @as(c_uint, list_value[counter]));
            counter +%= 1;
        }
        _ = c.printf("\n");
    }

    _ = c.printf("Clearing SDR Repository\n");
    if (sdrRepoClear(intf) != 0) {
        c.lprintf(c.LOG_ERR, "Cannot erase SDRR. Give up.");
        return -1;
    }

    // First fill the SDRR from local built-in sensors.
    _ = c.printf("Sanning built-in sensors..\n");
    rc = sdrCopyToSdrr(intf, 1, myaddr, myaddr);

    // Now fill the SDRR with the provided sensor list.
    {
        var counter: u8 = 0;
        while (rc == 0 and list_value[counter] != 0) {
            const slave_addr: c_int = list_value[counter];
            _ = c.printf("Scanning %02Xh..\n", slave_addr);
            if (sdrCopyToSdrr(intf, 0, slave_addr, myaddr) < 0) {
                rc = -1;
            }
            counter +%= 1;
        }
    }

    return rc;
}

/// `ipmi_sdr_read_records()`: fill the SDR repository from a binary file.
fn sdrReadRecords(filename: [*c]const u8, queue: *SdrrQueue) c_int {
    var rc: c_int = 0;
    var bin_hdr: [5]u8 = undefined;

    queue.head = null;
    queue.tail = null;

    const fd = c.open(filename, c.O_RDONLY);
    if (fd < 0) return -1;

    while (c.read(fd, &bin_hdr, 5) == 5) {
        c.lprintf(c.LOG_DEBUG, "binHdr[0] (id[MSB]) = 0x%02x", @as(c_uint, bin_hdr[0]));
        c.lprintf(c.LOG_DEBUG, "binHdr[1] (id[LSB]) = 0x%02x", @as(c_uint, bin_hdr[1]));
        c.lprintf(c.LOG_DEBUG, "binHdr[2] (version) = 0x%02x", @as(c_uint, bin_hdr[2]));
        c.lprintf(c.LOG_DEBUG, "binHdr[3] (type) = 0x%02x", @as(c_uint, bin_hdr[3]));
        c.lprintf(c.LOG_DEBUG, "binHdr[4] (length) = 0x%02x", @as(c_uint, bin_hdr[4]));

        // Deliberately *not* zeroed: the C does not `memset()` here, so
        // `next` is left holding whatever `malloc()` returned.
        const sdrr: *SdrRecordList = @ptrCast(@alignCast(
            c.malloc(@sizeOf(SdrRecordList)) orelse {
                c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
                rc = -1;
                break;
            },
        ));
        sdrr.id = (@as(u16, bin_hdr[1]) << 8) | @as(u16, bin_hdr[0]); // LS byte first.
        sdrr.version = bin_hdr[2];
        sdrr.type = bin_hdr[3];
        sdrr.length = bin_hdr[4];

        sdrr.raw = @ptrCast(c.malloc(sdrr.length) orelse {
            c.lprintf(c.LOG_ERR, "ipmitool: malloc failure");
            c.free(sdrr);
            rc = -1;
            break;
        });

        if (c.read(fd, sdrr.raw, sdrr.length) != sdrr.length) {
            c.lprintf(c.LOG_ERR, "SDR from '%s' truncated", filename);
            c.free(sdrr.raw);
            sdrr.raw = null;
            c.free(sdrr);
            rc = -1;
            break;
        }

        // Put it in the record queue.
        if (queue.head == null) {
            queue.head = sdrr;
        } else {
            queue.tail.?.next = sdrr;
        }
        queue.tail = sdrr;
    }
    _ = c.close(fd);
    return rc;
}

/// `ipmi_sdr_add_from_file()`.
fn sdrAddFromFile(intf: *Intf, ifile: [*c]const u8) callconv(.c) c_int {
    var rc: c_int = undefined;
    var sdrr_queue: SdrrQueue = undefined;

    // Read the SDR records from the file.
    rc = sdrReadRecords(ifile, &sdrr_queue);

    if (sdrRepoClear(intf) != 0) {
        c.lprintf(c.LOG_ERR, "Cannot erase SDRR. Giving up.");
        // FIXME: free the SDR list.
        return -1;
    }

    // Write the SDRs to the SDR repository.
    var sdrr = sdrr_queue.head;
    while (sdrr) |entry| {
        const sdrr_next = entry.next;
        rc = sdrAddRecord(intf, entry);
        if (rc < 0) {
            c.lprintf(
                c.LOG_ERR,
                "Cannot add SDR ID 0x%04x to repository...",
                @as(c_uint, entry.id),
            );
        }
        c.free(entry);
        sdrr = sdrr_next;
    }
    return rc;
}

// ---------------------------------------------------------------------------
// C ABI exports
// ---------------------------------------------------------------------------

/// Publish the C entry points this module replaces.  `assertCallSignature()`
/// runs inside the function body on purpose: at file scope it leaves a
/// reference the self hosted x86_64 backend keeps in `.debug_info`, which then
/// fails to link.
pub fn exportSymbols() void {
    comptime {
        @setEvalBranchQuota(200000);

        abi.assertCallSignature(@TypeOf(sdrEnd), @TypeOf(c.ipmi_sdr_end));
        @export(&sdrEnd, .{ .name = "ipmi_sdr_end", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(findSdrByentity), @TypeOf(c.ipmi_sdr_find_sdr_byentity));
        @export(&findSdrByentity, .{ .name = "ipmi_sdr_find_sdr_byentity", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(findSdrByid), @TypeOf(c.ipmi_sdr_find_sdr_byid));
        @export(&findSdrByid, .{ .name = "ipmi_sdr_find_sdr_byid", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(findSdrBynumtype), @TypeOf(c.ipmi_sdr_find_sdr_bynumtype));
        @export(&findSdrBynumtype, .{ .name = "ipmi_sdr_find_sdr_bynumtype", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(findSdrBysensortype), @TypeOf(c.ipmi_sdr_find_sdr_bysensortype));
        @export(&findSdrBysensortype, .{ .name = "ipmi_sdr_find_sdr_bysensortype", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(findSdrBytype), @TypeOf(c.ipmi_sdr_find_sdr_bytype));
        @export(&findSdrBytype, .{ .name = "ipmi_sdr_find_sdr_bytype", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getInfo), @TypeOf(c.ipmi_sdr_get_info));
        @export(&getInfo, .{ .name = "ipmi_sdr_get_info", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getNextHeader), @TypeOf(c.ipmi_sdr_get_next_header));
        @export(&getNextHeader, .{ .name = "ipmi_sdr_get_next_header", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getRecord), @TypeOf(c.ipmi_sdr_get_record));
        @export(&getRecord, .{ .name = "ipmi_sdr_get_record", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getReservation), @TypeOf(c.ipmi_sdr_get_reservation));
        @export(&getReservation, .{ .name = "ipmi_sdr_get_reservation", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getSensorEventEnable), @TypeOf(c.ipmi_sdr_get_sensor_event_enable));
        @export(&getSensorEventEnable, .{ .name = "ipmi_sdr_get_sensor_event_enable", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getSensorEventStatus), @TypeOf(c.ipmi_sdr_get_sensor_event_status));
        @export(&getSensorEventStatus, .{ .name = "ipmi_sdr_get_sensor_event_status", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getSensorHysteresis), @TypeOf(c.ipmi_sdr_get_sensor_hysteresis));
        @export(&getSensorHysteresis, .{ .name = "ipmi_sdr_get_sensor_hysteresis", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getSensorReading), @TypeOf(c.ipmi_sdr_get_sensor_reading));
        @export(&getSensorReading, .{ .name = "ipmi_sdr_get_sensor_reading", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getSensorReadingIpmb), @TypeOf(c.ipmi_sdr_get_sensor_reading_ipmb));
        @export(&getSensorReadingIpmb, .{ .name = "ipmi_sdr_get_sensor_reading_ipmb", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getSensorThresholds), @TypeOf(c.ipmi_sdr_get_sensor_thresholds));
        @export(&getSensorThresholds, .{ .name = "ipmi_sdr_get_sensor_thresholds", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getThreshStatus), @TypeOf(c.ipmi_sdr_get_thresh_status));
        @export(&getThreshStatus, .{ .name = "ipmi_sdr_get_thresh_status", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(getUnitString), @TypeOf(c.ipmi_sdr_get_unit_string));
        @export(&getUnitString, .{ .name = "ipmi_sdr_get_unit_string", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(listCache), @TypeOf(c.ipmi_sdr_list_cache));
        @export(&listCache, .{ .name = "ipmi_sdr_list_cache", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(listCacheFromfile), @TypeOf(c.ipmi_sdr_list_cache_fromfile));
        @export(&listCacheFromfile, .{ .name = "ipmi_sdr_list_cache_fromfile", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(sdrListEmpty), @TypeOf(c.ipmi_sdr_list_empty));
        @export(&sdrListEmpty, .{ .name = "ipmi_sdr_list_empty", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(sdrMain), @TypeOf(c.ipmi_sdr_main));
        @export(&sdrMain, .{ .name = "ipmi_sdr_main", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printDiscreteState), @TypeOf(c.ipmi_sdr_print_discrete_state));
        @export(&printDiscreteState, .{ .name = "ipmi_sdr_print_discrete_state", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printDiscreteStateMini), @TypeOf(c.ipmi_sdr_print_discrete_state_mini));
        @export(&printDiscreteStateMini, .{ .name = "ipmi_sdr_print_discrete_state_mini", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printEntity), @TypeOf(c.ipmi_sdr_print_entity));
        @export(&printEntity, .{ .name = "ipmi_sdr_print_entity", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printInfo), @TypeOf(c.ipmi_sdr_print_info));
        @export(&printInfo, .{ .name = "ipmi_sdr_print_info", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printListentry), @TypeOf(c.ipmi_sdr_print_listentry));
        @export(&printListentry, .{ .name = "ipmi_sdr_print_listentry", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printNameFromRawentry), @TypeOf(c.ipmi_sdr_print_name_from_rawentry));
        @export(&printNameFromRawentry, .{ .name = "ipmi_sdr_print_name_from_rawentry", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printRawentry), @TypeOf(c.ipmi_sdr_print_rawentry));
        @export(&printRawentry, .{ .name = "ipmi_sdr_print_rawentry", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printSdr), @TypeOf(c.ipmi_sdr_print_sdr));
        @export(&printSdr, .{ .name = "ipmi_sdr_print_sdr", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printSensorEventEnable), @TypeOf(c.ipmi_sdr_print_sensor_event_enable));
        @export(&printSensorEventEnable, .{ .name = "ipmi_sdr_print_sensor_event_enable", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printSensorEventStatus), @TypeOf(c.ipmi_sdr_print_sensor_event_status));
        @export(&printSensorEventStatus, .{ .name = "ipmi_sdr_print_sensor_event_status", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printSensorEventonly), @TypeOf(c.ipmi_sdr_print_sensor_eventonly));
        @export(&printSensorEventonly, .{ .name = "ipmi_sdr_print_sensor_eventonly", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printSensorFc), @TypeOf(c.ipmi_sdr_print_sensor_fc));
        @export(&printSensorFc, .{ .name = "ipmi_sdr_print_sensor_fc", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printSensorFruLocator), @TypeOf(c.ipmi_sdr_print_sensor_fru_locator));
        @export(&printSensorFruLocator, .{ .name = "ipmi_sdr_print_sensor_fru_locator", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printSensorGenericLocator), @TypeOf(c.ipmi_sdr_print_sensor_generic_locator));
        @export(&printSensorGenericLocator, .{ .name = "ipmi_sdr_print_sensor_generic_locator", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printSensorHysteresis), @TypeOf(c.ipmi_sdr_print_sensor_hysteresis));
        @export(&printSensorHysteresis, .{ .name = "ipmi_sdr_print_sensor_hysteresis", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printSensorMcLocator), @TypeOf(c.ipmi_sdr_print_sensor_mc_locator));
        @export(&printSensorMcLocator, .{ .name = "ipmi_sdr_print_sensor_mc_locator", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printType), @TypeOf(c.ipmi_sdr_print_type));
        @export(&printType, .{ .name = "ipmi_sdr_print_type", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(readSensorValue), @TypeOf(c.ipmi_sdr_read_sensor_value));
        @export(&readSensorValue, .{ .name = "ipmi_sdr_read_sensor_value", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(sdrStart), @TypeOf(c.ipmi_sdr_start));
        @export(&sdrStart, .{ .name = "ipmi_sdr_start", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(printfSdrUsage), @TypeOf(c.printf_sdr_usage));
        @export(&printfSdrUsage, .{ .name = "printf_sdr_usage", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(convertSensorHysterisis), @TypeOf(c.sdr_convert_sensor_hysterisis));
        @export(&convertSensorHysterisis, .{ .name = "sdr_convert_sensor_hysterisis", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(convertSensorReading), @TypeOf(c.sdr_convert_sensor_reading));
        @export(&convertSensorReading, .{ .name = "sdr_convert_sensor_reading", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(convertSensorTolerance), @TypeOf(c.sdr_convert_sensor_tolerance));
        @export(&convertSensorTolerance, .{ .name = "sdr_convert_sensor_tolerance", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(convertSensorValueToRaw), @TypeOf(c.sdr_convert_sensor_value_to_raw));
        @export(&convertSensorValueToRaw, .{ .name = "sdr_convert_sensor_value_to_raw", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(hexToDec), @TypeOf(c.ipmi_hex_to_dec));
        @export(&hexToDec, .{ .name = "ipmi_hex_to_dec", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(parseRangeList), @TypeOf(c.ipmi_parse_range_list));
        @export(&parseRangeList, .{ .name = "ipmi_parse_range_list", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(sdrAddFromFile), @TypeOf(c.ipmi_sdr_add_from_file));
        @export(&sdrAddFromFile, .{ .name = "ipmi_sdr_add_from_file", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(sdrAddFromList), @TypeOf(c.ipmi_sdr_add_from_list));
        @export(&sdrAddFromList, .{ .name = "ipmi_sdr_add_from_list", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(sdrAddFromSensors), @TypeOf(c.ipmi_sdr_add_from_sensors));
        @export(&sdrAddFromSensors, .{ .name = "ipmi_sdr_add_from_sensors", .linkage = .strong });

        abi.assertCallSignature(@TypeOf(sdrAddRecord), @TypeOf(c.ipmi_sdr_add_record));
        @export(&sdrAddRecord, .{ .name = "ipmi_sdr_add_record", .linkage = .strong });
    }
}
