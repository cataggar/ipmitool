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
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <paths.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

/*
 * Sockets.  `src/plugins/ipmi_intf.c` resolves the BMC address with
 * getaddrinfo() and walks the local interface list with getifaddrs() to find a
 * scope id for a link local IPv6 target; `ipmi_intf.h` already pulls in
 * <sys/socket.h>, <netinet/in.h> and <arpa/inet.h>, but not these two.
 */
#include <ifaddrs.h>
#include <netdb.h>

#include <ipmitool/helper.h>
#include <ipmitool/log.h>
#include <ipmitool/bswap.h>
#include <ipmitool/ipmi.h>
#include <ipmitool/ipmi_cc.h>
#include <ipmitool/ipmi_chassis.h>
#include <ipmitool/ipmi_channel.h>
#include <ipmitool/ipmi_constants.h>
#include <ipmitool/ipmi_event.h>
#include <ipmitool/ipmi_channel.h>
#include <ipmitool/ipmi_fru.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi_mc.h>
#include <ipmitool/ipmi_oem.h>
#include <ipmitool/ipmi_quantaoem.h>
#include <ipmitool/ipmi_raw.h>
#include <ipmitool/ipmi_sel.h>
#include <ipmitool/ipmi_sel_supermicro.h>
#include <ipmitool/ipmi_sensor.h>
#include <ipmitool/ipmi_sdr.h>
#include <ipmitool/ipmi_sdradd.h>
#include <ipmitool/ipmi_strings.h>
#include <ipmitool/ipmi_time.h>
#include <ipmitool/ipmi_user.h>
#include <ipmitool/hpm2.h>

/*
 * Plugin-private headers.  These are not under `include/`, so they are reached
 * relative to this file rather than through the include path; adding
 * `src/plugins/*` to the bridge's `-I` list would make the two `asf.h` /
 * `rmcp.h` pairs ambiguous.
 */
#include "../plugins/dummy/dummy.h"
#include "../plugins/lan/rmcp.h"
#include "../plugins/lan/md5.h"
#include "../plugins/lan/auth.h"
/*
 * ipmitool's own copy of the OpenIPMI driver ABI.  `src/plugins/open/open.c`
 * only falls back to it when neither <linux/ipmi.h> nor <sys/ipmi.h> exists, so
 * on Linux the C build does not use it -- but it is ipmitool source rather than
 * a kernel header, which is exactly what `src/zig/intf/open.zig` is allowed to
 * compare its hand-written structs against.  `intf/open.zig` additionally pins
 * every size, offset and ioctl number against the values <linux/ipmi.h>
 * produces, so a drift between the two is a test failure and not a silent one.
 */
#include "../plugins/open/open.h"
#include "../plugins/lanplus/lanplus.h"
#include "../plugins/lanplus/lanplus_crypt.h"
#include "../plugins/lanplus/lanplus_crypt_impl.h"

#include "abi_layout.h"

/*
 * Functions the C tree exports but no header declares.
 *
 * A ported Zig module must be able to name the C signature it is replacing so
 * that `abi.assertCallSignature()` can check it, and the project forbids
 * `extern fn` outside this bridge - so the declaration goes here instead.  See
 * doc/zig-migration/interop-seams.md.
 *
 * `lib/ipmi_raw.c` defines `ipmi_raw_help()` and `lib/dimm_spd.c` defines
 * `ipmi_spd_print()`, both with external linkage and neither with a prototype
 * in `include/ipmitool/`; `lib/ipmi_raw.c` reaches the latter through a local
 * declaration of its own.  Restating them here is what lets `cmd/raw.zig` call
 * `ipmi_spd_print()` and assert its own `ipmi_raw_help()` against the C
 * signature.  Each declaration is copied from the definition it describes, so
 * a change to either is a C compile error in the defining translation unit
 * rather than a silent ABI mismatch.
 *
 * The `ipmi_spd_print()` line goes away when `lib/dimm_spd.c` is ported; the
 * `ipmi_raw_help()` one when nothing needs to compare against the C signature
 * any more, since `lib/ipmi_raw.c` was its only caller.
 *
 * `struct wdt_string_s` is defined inside `lib/ipmi_mc.c`; only a pointer to
 * it appears in `find_set_wdt_string()`'s signature, so an incomplete type is
 * enough.
 *
 * `lib/ipmi_chassis.c` defines the next two without a prototype; nothing else
 * in the tree calls them, but they are global symbols and the Zig replacement
 * has to export them under the same names with the same signatures.
 *
 * `lib/ipmi_sensor.c` does the same for its two usage printers: both have
 * external linkage, both are forward declared at the top of the `.c` and
 * nowhere else.  The C declarations use K&R empty parameter lists, which
 * `translate-c` turns into *variadic* function types; the declarations here
 * spell `void` instead so that `assertCallSignature()` compares against the
 * non-variadic type the Zig replacement actually exports.  Neither function
 * takes an argument, so the two agree at the ABI level.
 *
 * `lib/ipmi_sel.c` contributes five more functions and one variable.  The four
 * OEM description decoders and the two sensor-type lookups it defines are all
 * global by omission - nothing declares them, and only `lib/ipmi_sel.c` itself
 * calls them - and so is `sel_oem_msg`, the table `ipmi_sel_oem_init()` fills
 * in, which is missing a `static`.  `struct ipmi_sel_oem_msg_rec` is defined
 * inside the `.c`, so an incomplete type is enough here: only a pointer to it
 * ever crosses the boundary, and `cmd/sel.zig` owns the complete definition.
 *
 * `lib/ipmi_sdradd.c` contributes three more.  `ipmi_sdr_add_record()` is
 * declared nowhere; `ipmi_parse_range_list()` and `ipmi_hex_to_dec()` are
 * forward declared at the top of that `.c` and nowhere else.  All three are
 * global symbols the Zig replacement has to re-export under the same
 * signatures.
 *
 * `lib/ipmi_sdr.c` contributes seven.  `ipmi_sdr_get_info()`,
 * `ipmi_sdr_print_type()`, `ipmi_sdr_print_entity()`,
 * `ipmi_sdr_print_sensor_fc()`, `ipmi_sdr_get_sensor_event_status()` and
 * `ipmi_sdr_get_sensor_event_enable()` are global by omission - no header
 * declares them.  `printf_sdr_usage()` is forward declared inside that `.c`
 * with a K&R empty parameter list, so it gets the same `void` treatment as
 * the `ipmi_sensor.c` usage printers.
 *
 * `strptime()` is declared by glibc's `<time.h>` only under `_XOPEN_SOURCE`;
 * `lib/ipmi_sel.c` reaches it by defining `__USE_XOPEN` by hand before the
 * include.  Restating the prototype here is the same trick without depending
 * on glibc's internal feature macros.
 */
void ipmi_raw_help(void);
int ipmi_spd_print(uint8_t *spd_data, int len);
struct wdt_string_s;
int find_set_wdt_string(const struct wdt_string_s *w[], const char *s);
int ipmi_chassis_status(struct ipmi_intf *intf);
void ipmi_chassis_set_bootflag_help(void);
void print_sensor_get_usage(void);
void print_sensor_thresh_usage(void);
char *get_kontron_evt_desc(struct ipmi_intf *intf, struct sel_event_record *rec);
char *get_supermicro_evt_desc(struct ipmi_intf *intf,
			      struct sel_event_record *rec);
char *get_dell_evt_desc(struct ipmi_intf *intf, struct sel_event_record *rec);
const char *ipmi_get_generic_sensor_type(uint8_t code);
const char *ipmi_get_oem_sensor_type(struct ipmi_intf *intf, uint8_t code);
struct ipmi_sel_oem_msg_rec;
extern struct ipmi_sel_oem_msg_rec *sel_oem_msg;
char *strptime(const char *s, const char *format, struct tm *tm);

int ipmi_sdr_add_record(struct ipmi_intf *intf, struct sdr_record_list *sdrr);
int ipmi_parse_range_list(const char *rangeList, unsigned char *pHexList);
int ipmi_hex_to_dec(char *rangeList, unsigned char *pDecValue);
int ipmi_sdr_get_info(struct ipmi_intf *intf,
		      struct get_sdr_repository_info_rsp *sdr_repository_info);
int ipmi_sdr_print_type(struct ipmi_intf *intf, char *type);
int ipmi_sdr_print_entity(struct ipmi_intf *intf, char *entitystr);
int ipmi_sdr_print_sensor_fc(struct ipmi_intf *intf,
			     struct sdr_record_common_sensor *sensor,
			     uint8_t sdr_record_type);
struct ipmi_rs *ipmi_sdr_get_sensor_event_status(struct ipmi_intf *intf,
						 uint8_t sensor,
						 uint8_t target, uint8_t lun,
						 uint8_t channel);
struct ipmi_rs *ipmi_sdr_get_sensor_event_enable(struct ipmi_intf *intf,
						 uint8_t sensor,
						 uint8_t target, uint8_t lun,
						 uint8_t channel);
void printf_sdr_usage(void);

/*
 * `src/plugins/ipmi_intf.c` defines these two without a prototype in
 * `include/ipmitool/ipmi_intf.h`; `lib/ipmi_main.c` and `lib/hpm2.c` each
 * repeat a local declaration instead.  `src/zig/intf/registry.zig` has to
 * export them, so the signature is restated here to be checked against.
 */
void ipmi_intf_set_max_request_data_size(struct ipmi_intf *intf, uint16_t size);
void ipmi_intf_set_max_response_data_size(struct ipmi_intf *intf, uint16_t size);

/*
 * The transport instances.
 *
 * Each `src/plugins/<name>/<name>.c` defines exactly one `struct ipmi_intf`
 * with external linkage and no header declares it; `src/plugins/ipmi_intf.c`
 * carries its own `extern` block instead, and `src/zig/intf/registry.zig` — the
 * Zig replacement for that translation unit — needs the same declarations to
 * build `ipmi_intf_table`.  The `#ifdef` guards and the order below are copied
 * from `src/plugins/ipmi_intf.c` verbatim, so the Zig table is assembled from
 * exactly the same set under exactly the same conditions.
 *
 * Each entry disappears when its plugin is ported to Zig.
 */
#ifdef IPMI_INTF_OPEN
extern struct ipmi_intf ipmi_open_intf;
#endif
#ifdef IPMI_INTF_LAN
extern struct ipmi_intf ipmi_lan_intf;
#endif
#ifdef IPMI_INTF_LANPLUS
extern struct ipmi_intf ipmi_lanplus_intf;
#endif
#ifdef IPMI_INTF_SERIAL
extern struct ipmi_intf ipmi_serial_term_intf;
extern struct ipmi_intf ipmi_serial_bm_intf;
#endif
#ifdef IPMI_INTF_DUMMY
extern struct ipmi_intf ipmi_dummy_intf;
#endif
#ifdef IPMI_INTF_USB
extern struct ipmi_intf ipmi_usb_intf;
#endif

/*
 * `src/plugins/dummy/dummy.c` defines these two with external linkage and no
 * prototype anywhere; nothing outside that file calls them, but they are
 * global symbols, so the Zig replacement has to export them under the same
 * names with the same signatures.
 */
int data_read(int fd, void *data_ptr, int data_len);
int data_write(int fd, void *data_ptr, int data_len);

/*
 * `src/plugins/open/open.c` defines `ipmi_openipmi_setup()` with external
 * linkage and declares it nowhere; `src/zig/intf/open.zig` needs the C type to
 * compare its replacement against.
 */
int ipmi_openipmi_setup(struct ipmi_intf *intf);
