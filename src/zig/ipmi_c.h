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
#include <locale.h>
#include <paths.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <config.h>

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
#if defined(__linux__) && (defined(IPMI_INTF_USB) || defined(IPMITOOL_ZIG_USB))
#include <sys/file.h>
#include <scsi/sg.h>
#endif
#include <ipmitool/ipmi_cc.h>
#include <ipmitool/ipmi_chassis.h>
#include <ipmitool/ipmi_channel.h>
#include <ipmitool/ipmi_constants.h>
#include <ipmitool/ipmi_dcmi.h>
#include <ipmitool/ipmi_event.h>
#include <ipmitool/ipmi_ekanalyzer.h>
#include <ipmitool/ipmi_firewall.h>
#include <ipmitool/ipmi_channel.h>
#include <ipmitool/ipmi_cfgp.h>
#include <ipmitool/ipmi_session.h>
#include <ipmitool/ipmi_fru.h>
#include <ipmitool/ipmi_fwum.h>
#include <ipmitool/ipmi_gendev.h>
#include <ipmitool/ipmi_hpmfwupg.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi_isol.h>
#include <ipmitool/ipmi_ime.h>
#include <ipmitool/ipmi_ekanalyzer.h>
#include <ipmitool/ipmi_delloem.h>
#include <ipmitool/ipmi_dcmi.h>
#include <ipmitool/ipmi_firewall.h>
#include <ipmitool/ipmi_kontronoem.h>
#include <ipmitool/ipmi_lanp.h>
#include <ipmitool/ipmi_lanp6.h>
#include <ipmitool/ipmi_main.h>
#include <ipmitool/ipmi_mc.h>
#include <ipmitool/ipmi_oem.h>
#include <ipmitool/ipmi_pef.h>
#include <ipmitool/ipmi_picmg.h>
#include <ipmitool/ipmi_pef.h>
#include <ipmitool/ipmi_quantaoem.h>
#include <ipmitool/ipmi_raw.h>
#include <ipmitool/ipmi_sel.h>
#include <ipmitool/ipmi_sol.h>
#include <ipmitool/ipmi_sel_supermicro.h>
#include <ipmitool/ipmi_sensor.h>
#include <ipmitool/ipmi_session.h>
#include <ipmitool/ipmi_sdr.h>
#include <ipmitool/ipmi_sdradd.h>
#include <ipmitool/ipmi_strings.h>
#include <ipmitool/ipmi_sol.h>
#include <ipmitool/ipmi_sunoem.h>
#include <ipmitool/ipmi_time.h>
#include <ipmitool/ipmi_tsol.h>
#include <ipmitool/ipmi_user.h>
#include <ipmitool/ipmi_vita.h>
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
#include "../plugins/lanplus/lanplus_dump.h"

#include "abi_layout.h"

/* Globals and entry points exported by lib/ipmi_lanp6.c (no public prototypes). */
extern const struct ipmi_lanp generic_lanp6[];
extern const struct valstr lanp_cc_vals[], ip6_enable_vals[],
	ip6_addr_enable_vals[], ip6_addr_sources[], ip6_addr_statuses[],
	ip6_duid_types[], ip6_cfg_sup_vals[], ip6_rtr_configs[],
	ip6_command_vals[];
extern const struct ipmi_lanp *lookup_lanp(int param);
extern int ipmi_get_dynamic_oem_lanp(void *priv, const struct ipmi_lanp *param,
	int oem_base, int set_selector, int block_selector, void *data, int quiet);
extern int ipmi_get_lanp(void *priv, int param_selector, int set_selector,
	int block_selector, void *data, int quiet);
extern int ipmi_set_dynamic_oem_lanp(void *priv, const struct ipmi_lanp *param,
	int base, const void *data);
extern int ipmi_set_lanp(void *priv, int param_selector, const void *data);
extern int ipmi_lan6_main(struct ipmi_intf *intf, int argc, char **argv);

/* src/ipmitool.c declares these locally; use their original signatures for
 * compile-time ABI checking of the optional Zig shell replacement. */
int ipmi_shell_main(struct ipmi_intf *intf, int argc, char **argv);
int ipmi_exec_main(struct ipmi_intf *intf, int argc, char **argv);
int ipmi_set_main(struct ipmi_intf *intf, int argc, char **argv);
int ipmi_echo_main(struct ipmi_intf *intf, int argc, char **argv);

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
 * `ipmi_spd_print_fru()` is also defined in `lib/dimm_spd.c` but declared
 * only locally in `lib/ipmi_fru.c`. Both SPD entry points are retained for Zig
 * ABI signature assertions and the raw SPD reader's call.
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
void printf_firewall_info_usage(void);
int ipmi_spd_print(uint8_t *spd_data, int len);
/* Exported by lib/ipmi_fru.c; Kontron's FRU editor needs all three helpers. */
int read_fru_area(struct ipmi_intf *intf, struct fru_info *fru, uint8_t id,
		  uint32_t offset, uint32_t length, uint8_t *frubuf);
int write_fru_area(struct ipmi_intf *intf, struct fru_info *fru, uint8_t id,
		   uint16_t soffset, uint16_t doffset, uint16_t length,
		   uint8_t *frubuf);
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

int ipmi_sol_payload_access(struct ipmi_intf *intf, uint8_t channel,
                            uint8_t userid, int enable);
int ipmi_sol_payload_access_status(struct ipmi_intf *intf, uint8_t channel,
                                   uint8_t userid);
void enter_raw_mode(void);
void leave_raw_mode(void);
extern const struct valstr sol_parameter_vals[];

int ipmi_sdr_add_record(struct ipmi_intf *intf, struct sdr_record_list *sdrr);
int ipmi_parse_range_list(const char *rangeList, unsigned char *pHexList);
int ipmi_hex_to_dec(char *rangeList, unsigned char *pDecValue);
/* `lib/ipmi_session.c` defines this without a public prototype. Its
 * file-local enum has C int representation; the four values are 0..3. */
int ipmi_get_session_info(struct ipmi_intf *intf, int request_type,
			  uint32_t id_or_handle);

/* Global helper and wire entry points defined by lib/ipmi_dcmi.c. */
void print_strs(const struct dcmi_cmd *vs, const char *title,
                int loglevel, int verthorz);
uint16_t str2val2(const char *str, const struct dcmi_cmd *vs);
const char *val2str2(uint16_t val, const struct dcmi_cmd *vs);
struct ipmi_rs *ipmi_dcmi_getcapabilities(struct ipmi_intf *intf, uint8_t selector);
struct ipmi_rs *ipmi_dcmi_getassettag(struct ipmi_intf *intf, uint8_t offset, uint8_t length);
struct ipmi_rs *ipmi_dcmi_setassettag(struct ipmi_intf *intf, uint8_t offset, uint8_t length, uint8_t *data);
struct ipmi_rs *ipmi_dcmi_getmngctrlids(struct ipmi_intf *intf, uint8_t offset, uint8_t length);
struct ipmi_rs *ipmi_dcmi_setmngctrlids(struct ipmi_intf *intf, uint8_t offset, uint8_t length, uint8_t *data);
struct ipmi_rs *ipmi_dcmi_discvry_snsr(struct ipmi_intf *intf, uint8_t sensor, uint8_t offset);
struct ipmi_rs *ipmi_dcmi_get_temp_readings(struct ipmi_intf *intf, uint8_t entity, uint8_t instance, uint8_t start);
struct ipmi_rs *ipmi_dcmi_getconfparam(struct ipmi_intf *intf, int selector);
struct ipmi_rs *ipmi_dcmi_setconfparam(struct ipmi_intf *intf, uint8_t selector, uint16_t value);
struct ipmi_rs *ipmi_dcmi_pwr_glimit(struct ipmi_intf *intf);
int ipmi_dcmi_getthermalpolicy(struct ipmi_intf *intf, uint8_t entity, uint8_t instance);
int ipmi_dcmi_setthermalpolicy(struct ipmi_intf *intf, uint8_t entity,
			      uint8_t instance, uint8_t persistence, uint8_t hard,
			      uint8_t sel, uint8_t limit, uint8_t low, uint8_t high);
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

/* Public FRU helpers with external linkage but no prototypes in
 * include/ipmitool/ipmi_fru.h. */
void ipmi_fru_read_help(void);
void ipmi_fru_write_help(void);
void ipmi_fru_edit_help(void);
void ipmi_fru_get_help(void);
void ipmi_fru_upgekey_help(void);
void ipmi_fru_internaluse_help(void);
void ipmi_fru_help(void);
int ipmi_spd_print_fru(struct ipmi_intf *intf, uint8_t id);
int is_valid_filename(const char *filename);
t_ipmi_fru_bloc *build_fru_bloc(struct ipmi_intf *intf,
			       struct fru_info *fru, uint8_t id);
void free_fru_bloc(t_ipmi_fru_bloc *bloc);
int read_fru_area(struct ipmi_intf *intf, struct fru_info *fru,
		  uint8_t id, uint32_t offset, uint32_t length, uint8_t *data);
int read_fru_area_section(struct ipmi_intf *intf, struct fru_info *fru,
			  uint8_t id, uint32_t offset, uint32_t length,
			  uint8_t *data);
int write_fru_area(struct ipmi_intf *intf, struct fru_info *fru, uint8_t id,
		   uint16_t source_offset, uint16_t destination_offset,
		   uint16_t length, uint8_t *data);
int ipmi_fru_get_adjust_size_from_buffer(uint8_t *data, uint32_t *size);

/* Global symbols defined by lib/ipmi_picmg.c but absent from its header. */
struct sAmcAddrMap {
	unsigned char ipmbLAddr;
	char *amcBayId;
	unsigned char siteNum;
};
extern struct sAmcAddrMap amcAddrMap[13];
void ipmi_picmg_help(void);
int is_amc_channel(const char *, uint8_t *);
int is_amc_dev(const char *, int32_t *);
int is_amc_intf(const char *, int32_t *);
int is_amc_port(const char *, int32_t *);
int is_clk_acc(const char *, uint8_t *);
int is_clk_family(const char *, uint8_t *);
int is_clk_freq(const char *, uint32_t *);
int is_clk_id(const char *, uint8_t *);
int is_clk_index(const char *, uint8_t *);
int is_clk_resid(const char *, int8_t *);
int is_clk_setting(const char *, uint8_t *);
int is_enable(const char *, uint8_t *);
int is_led_color(const char *, uint8_t *);
int is_led_function(const char *, uint8_t *);
int is_led_id(const char *, uint8_t *);
int is_link_group(const char *, uint8_t *);
int is_link_type(const char *, uint8_t *);
int is_link_type_ext(const char *, uint8_t *);
int ipmi_picmg_getaddr(struct ipmi_intf *, int, char **);
int ipmi_picmg_properties(struct ipmi_intf *, int);
int ipmi_picmg_fru_activation(struct ipmi_intf *, char **, unsigned char);
int ipmi_picmg_fru_activation_policy_get(struct ipmi_intf *, char **);
int ipmi_picmg_fru_activation_policy_set(struct ipmi_intf *, char **);
int ipmi_picmg_portstate_get(struct ipmi_intf *, int32_t, uint8_t, int);
int ipmi_picmg_portstate_set(struct ipmi_intf *, int32_t, uint8_t, int32_t,
			    uint8_t, uint8_t, uint8_t, uint8_t);
int ipmi_picmg_amc_portstate_get(struct ipmi_intf *, int32_t, uint8_t, int);
int ipmi_picmg_amc_portstate_set(struct ipmi_intf *, uint8_t, int32_t,
				uint8_t, uint8_t, uint8_t, uint8_t, int32_t);
int ipmi_picmg_get_led_properties(struct ipmi_intf *, char **);
int ipmi_picmg_get_led_capabilities(struct ipmi_intf *, char **);
int ipmi_picmg_get_led_state(struct ipmi_intf *, char **);
int ipmi_picmg_set_led_state(struct ipmi_intf *, char **);
int ipmi_picmg_get_power_level(struct ipmi_intf *, char **);
int ipmi_picmg_set_power_level(struct ipmi_intf *, char **);
enum picmg_bused_resource_mode { PICMG_BUSED_RESOURCE_SUMMARY };
int ipmi_picmg_bused_resource(struct ipmi_intf *, enum picmg_bused_resource_mode);
int ipmi_picmg_fru_control(struct ipmi_intf *, char **);
int ipmi_picmg_clk_get(struct ipmi_intf *, uint8_t, int8_t, int);
int ipmi_picmg_clk_set(struct ipmi_intf *, int, char **);

/* External symbols defined in lib/ipmi_pef.c without header declarations. */
void ipmi_pef_print_int(const char *text, uint32_t val);
int _ipmi_get_pef_capabilities(struct ipmi_intf *intf,
			      struct pef_capabilities *cap);
int _ipmi_get_pef_filter_entry_cfg(struct ipmi_intf *intf, uint8_t filter_id,
				   struct pef_cfgparm_filter_table_data_1 *cfg);
int _ipmi_get_pef_system_guid(struct ipmi_intf *intf,
			      struct pef_cfgparm_system_guid *guid);
void ipmi_pef_print_event_info(struct pef_cfgparm_filter_table_entry *entry,
			       char *buf);
void ipmi_pef2_help(void);
void ipmi_pef2_filter_help(void);
void ipmi_pef2_policy_help(void);
int ipmi_pef2_filter(struct ipmi_intf *intf, int argc, char **argv);
int ipmi_pef2_policy(struct ipmi_intf *intf, int argc, char **argv);

/*
 * `src/plugins/ipmi_intf.c` defines these two without a prototype in
 * `include/ipmitool/ipmi_intf.h`; `lib/ipmi_main.c` and `lib/hpm2.c` each
 * repeat a local declaration instead.  `src/zig/intf/registry.zig` has to
 * export them, so the signature is restated here to be checked against.
 */
void ipmi_intf_set_max_request_data_size(struct ipmi_intf *intf, uint16_t size);
void ipmi_intf_set_max_response_data_size(struct ipmi_intf *intf, uint16_t size);

/* src/ipmitool.c declares these command functions locally. */
#ifdef HAVE_READLINE
int ipmi_shell_main(struct ipmi_intf *intf, int argc, char **argv);
#endif
int ipmi_echo_main(struct ipmi_intf *intf, int argc, char **argv);
int ipmi_set_main(struct ipmi_intf *intf, int argc, char **argv);
int ipmi_exec_main(struct ipmi_intf *intf, int argc, char **argv);
int ipmi_lan6_main(struct ipmi_intf *intf, int argc, char **argv);
void ipmi_catch_sigint(void);

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
 * The USB plugin's non-static entry points and its command header.  They
 * have no public header in the C tree; these declarations let the Zig port
 * check and preserve their ABI when usb.c is replaced.
 */
typedef struct {
    uint8_t BeginSig[16];
    uint16_t Command;
    uint16_t Status;
    uint32_t DataInLen;
    uint32_t DataOutLen;
    uint32_t InternalUseDataIn;
    uint32_t InternalUseDataOut;
} CONFIG_CMD;
int scsiProbeNew(int *num_ami_devices, int *sg_nos);
int OpenCD(struct ipmi_intf *intf, char *CDName);
int sendscsicmd_SGIO(int cd_desc, unsigned char *cdb_buf, unsigned char cdb_len,
                      void *data_buf, unsigned int *data_len, int direction,
                      void *sense_buf, unsigned char slen, unsigned int timeout);
int AMI_SPT_CMD_Identify(int cd_desc, char *szSignature);
int IsG2Drive(int cd_desc);
int FindG2CDROM(struct ipmi_intf *intf);
void InitCmdHeader(CONFIG_CMD *header);
int AMI_SPT_CMD_SendCmd(int cd_desc, char *buffer, char type, uint16_t buflen,
                        unsigned int timeout);
int AMI_SPT_CMD_RecvCmd(int cd_desc, char *buffer, char type, uint16_t buflen);
int ReadCD(int cd_desc, char cmd_data, char *buffer, uint32_t data_len);
int WriteCD(int cd_desc, char cmd_data, char *buffer, unsigned int timeout,
            uint32_t data_len);
int WriteSplitData(struct ipmi_intf *intf, char *buffer, char sector,
                   uint32_t num_bytes, uint32_t timeout);
int ReadSplitData(struct ipmi_intf *intf, char *buffer, char sector,
                  uint32_t num_bytes);
int WaitForCommandCompletion(struct ipmi_intf *intf, CONFIG_CMD *header,
                             uint32_t timeout, uint32_t data_len);
int SendDataToUSBDriver(struct ipmi_intf *intf, char *request,
                         unsigned int request_len, unsigned char *response,
                         int *response_len, unsigned int timeout);

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

/*
 * `src/plugins/lanplus/lanplus_strings.c` defines these two lookup tables with
 * external linkage and no header declares them; `lanplus.c` and
 * `lanplus_dump.c` each restate them locally.  The bridge does the same so
 * `intf/lanplus.zig` can name them without an `extern` of its own.
 */
extern const struct valstr ipmi_rakp_return_codes[];
extern const struct valstr ipmi_priv_levels[];
