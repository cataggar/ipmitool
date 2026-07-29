/*
 * Mechanical equivalence harness for the lib/ipmi_strings.c -> Zig port.
 *
 * Walks every lookup table exported by <ipmitool/ipmi_strings.h> and prints one
 * line per entry, up to *and including* the sentinel, so that ordering,
 * duplicate keys, empty-string-vs-NULL and sentinel handling are all visible in
 * the output.  It then replays a fixed set of val2str()/oemval2str() probes so
 * the unknown-code fallback formatting and the static-buffer reuse semantics of
 * unknown_val_str() are compared too.
 *
 * The program is linked twice - once against the all-C build and once against
 * the build produced with -Dzig-modules=strings - and the two dumps are
 * diffed.  It deliberately contains no table data of its own.
 *
 * tools/dump_strings.sh does the building, linking and diffing; this file is
 * only the walker.  The CLI level differential test is the golden suite
 * (`zig build test-golden`), which already runs against a binary with every
 * registered module swapped to Zig.
 */

#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#include <stdio.h>
#include <string.h>

#include <ipmitool/helper.h>
#include <ipmitool/ipmi_strings.h>
#include <ipmitool/log.h>

/* Owned by the ipmitool/ipmievd main objects, which this harness replaces. */
int verbose = 0;

/* IANA numbers used to probe the two-key oemvalstr tables. */
static const uint32_t probe_oems[] = {
	0,          /* unassigned          */
	2,          /* IBM                 */
	343,        /* Intel               */
	674,        /* Dell                */
	5591,       /* Newisys             */
	10297,      /* Supermicro          */
	11129,      /* Google              */
	12634,      /* PICMG (wildcard)    */
	15370,      /* Kontron             */
	16394,      /* VITA                */
	24339,      /* ADLINK              */
	47488,      /* Inventec            */
	0xffffff,   /* sentinel value      */
	0xffffffff, /* out of range        */
};

static void dump_valstr(const char *name, const struct valstr *vs)
{
	size_t i = 0;

	for (;; ++i) {
		printf("%s|%zu|0x%08x|%s\n", name, i, vs[i].val,
		       vs[i].str ? vs[i].str : "<NULL>");
		if (!vs[i].str) {
			break;
		}
	}
}

static void dump_oemvalstr(const char *name, const struct oemvalstr *vs)
{
	size_t i = 0;

	for (;; ++i) {
		printf("%s|%zu|0x%08x|0x%04x|%s\n", name, i, vs[i].oem,
		       vs[i].val, vs[i].str ? vs[i].str : "<NULL>");
		if (vs[i].oem == 0xffffff && !vs[i].str) {
			break;
		}
	}
}

static void dump_strlist(const char *name, const char **list)
{
	size_t i = 0;

	for (;; ++i) {
		printf("%s|%zu|%s\n", name, i, list[i] ? list[i] : "<NULL>");
		if (!list[i]) {
			break;
		}
	}
}

/* Probe val2str() over a range that is guaranteed to straddle both known and
 * unknown codes so the "Unknown (0xNN)" fallback text is compared as well. */
static void probe_valstr(const char *name, const struct valstr *vs)
{
	uint32_t v;

	for (v = 0; v <= 0x120; ++v) {
		printf("probe|%s|0x%08x|%s\n", name, v, val2str(v, vs));
	}
	printf("probe|%s|str2val32(bogus)|0x%08x\n", name,
	       str2val32("no such entry at all", vs));
}

static void probe_oemvalstr(const char *name, const struct oemvalstr *vs)
{
	size_t o;
	uint32_t v;

	for (o = 0; o < sizeof(probe_oems) / sizeof(probe_oems[0]); ++o) {
		for (v = 0; v <= 0x110; ++v) {
			printf("oemprobe|%s|0x%08x|0x%04x|%s\n", name,
			       probe_oems[o], v,
			       oemval2str(probe_oems[o], v, vs));
		}
	}
}

int main(int argc, char **argv)
{
	int with_registry = (argc > 1 && !strcmp(argv[1], "--registry"));

	/* verbose >= 6 makes lprintf(LOG_DEBUG + 4, ...) visible, so the IANA
	 * registry loader's debug transcript is compared as well. */
	log_init("dump_strings", 0, with_registry ? 8 : 0);

	dump_oemvalstr("ipmi_oem_product_info", ipmi_oem_product_info);
	dump_strlist("ipmi_generic_sensor_type_vals",
		     ipmi_generic_sensor_type_vals);
	dump_oemvalstr("ipmi_oem_sensor_type_vals", ipmi_oem_sensor_type_vals);
	dump_valstr("ipmi_netfn_vals", ipmi_netfn_vals);
	dump_valstr("ipmi_bit_rate_vals", ipmi_bit_rate_vals);
	dump_valstr("ipmi_channel_activity_type_vals",
		    ipmi_channel_activity_type_vals);
	dump_valstr("ipmi_privlvl_vals", ipmi_privlvl_vals);
	dump_valstr("ipmi_set_in_progress_vals", ipmi_set_in_progress_vals);
	dump_valstr("ipmi_authtype_session_vals", ipmi_authtype_session_vals);
	dump_valstr("ipmi_authtype_vals", ipmi_authtype_vals);
	dump_valstr("entity_id_vals", entity_id_vals);
	dump_valstr("entity_device_type_vals", entity_device_type_vals);
	dump_valstr("ipmi_channel_protocol_vals", ipmi_channel_protocol_vals);
	dump_valstr("ipmi_channel_medium_vals", ipmi_channel_medium_vals);
	dump_valstr("completion_code_vals", completion_code_vals);
	dump_valstr("ipmi_chassis_power_control_vals",
		    ipmi_chassis_power_control_vals);
	dump_valstr("ipmi_chassis_restart_cause_vals",
		    ipmi_chassis_restart_cause_vals);
	dump_valstr("ipmi_auth_algorithms", ipmi_auth_algorithms);
	dump_valstr("ipmi_integrity_algorithms", ipmi_integrity_algorithms);
	dump_valstr("ipmi_encryption_algorithms", ipmi_encryption_algorithms);
	dump_valstr("ipmi_user_enable_status_vals",
		    ipmi_user_enable_status_vals);
	dump_valstr("picmg_frucontrol_vals", picmg_frucontrol_vals);
	dump_valstr("picmg_clk_family_vals", picmg_clk_family_vals);
	dump_oemvalstr("picmg_clk_accuracy_vals", picmg_clk_accuracy_vals);
	dump_oemvalstr("picmg_clk_resource_vals", picmg_clk_resource_vals);
	dump_oemvalstr("picmg_clk_id_vals", picmg_clk_id_vals);
	dump_valstr("picmg_busres_id_vals", picmg_busres_id_vals);
	dump_valstr("picmg_busres_board_cmd_vals", picmg_busres_board_cmd_vals);
	dump_valstr("picmg_busres_shmc_cmd_vals", picmg_busres_shmc_cmd_vals);
	dump_oemvalstr("picmg_busres_board_status_vals",
		       picmg_busres_board_status_vals);
	dump_oemvalstr("picmg_busres_shmc_status_vals",
		       picmg_busres_shmc_status_vals);

	probe_valstr("completion_code_vals", completion_code_vals);
	probe_valstr("entity_id_vals", entity_id_vals);
	probe_valstr("ipmi_netfn_vals", ipmi_netfn_vals);
	probe_valstr("ipmi_privlvl_vals", ipmi_privlvl_vals);
	probe_valstr("ipmi_chassis_restart_cause_vals",
		     ipmi_chassis_restart_cause_vals);
	probe_oemvalstr("ipmi_oem_sensor_type_vals", ipmi_oem_sensor_type_vals);
	probe_oemvalstr("ipmi_oem_product_info", ipmi_oem_product_info);
	probe_oemvalstr("picmg_clk_id_vals", picmg_clk_id_vals);

	/* The registry table is heap allocated at run time; dumping it needs a
	 * dictionary in a fixed location, so it is opt-in. */
	if (with_registry) {
		ipmi_oem_info_init();
		dump_valstr("ipmi_oem_info", ipmi_oem_info);
		ipmi_oem_info_free();
		printf("ipmi_oem_info|freed|%p\n", (void *)ipmi_oem_info);
	}

	return 0;
}
