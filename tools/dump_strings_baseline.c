/*
 * Optional external C oracle for the frozen static-string fixtures.
 * Only tools/gen_strings_baseline.sh compiles this file, against an archived,
 * pinned C revision, never the current product tables or the default tests.
 */
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* Including the historical translation unit exposes the three static tables
 * and complete array bounds. Unused registry functions are discarded at link. */
#include <ipmi_strings.c>

static void text(const char *s)
{
	size_t i, len;
	if (!s) {
		printf("null\n");
		return;
	}
	len = strlen(s);
	printf("%zu|", len);
	for (i = 0; i < len; ++i)
		printf("%02x", (unsigned char)s[i]);
	putchar('\n');
}

static void valstr(const char *name, const struct valstr *rows, size_t count)
{
	size_t i;
	printf("table|%s|valstr|%zu\n", name, count);
	for (i = 0; i < count; ++i) {
		printf("%zu|0x%08" PRIx32 "|", i, rows[i].val);
		text(rows[i].str);
	}
}

static void oemvalstr(const char *name, const struct oemvalstr *rows, size_t count)
{
	size_t i;
	printf("table|%s|oemvalstr|%zu\n", name, count);
	for (i = 0; i < count; ++i) {
		printf("%zu|0x%08" PRIx32 "|0x%04x|", i, rows[i].oem, rows[i].val);
		text(rows[i].str);
	}
}

static void strlist(const char *name, const char *const *rows, size_t count)
{
	size_t i;
	printf("table|%s|strlist|%zu\n", name, count);
	for (i = 0; i < count; ++i) {
		printf("%zu|", i);
		text(rows[i]);
	}
}

static void constant(const char *name, uint32_t value)
{
	printf("constant|");
	while (*name) {
		int ch = *name++;
		putchar(ch >= 'A' && ch <= 'Z' ? ch + ('a' - 'A') : ch);
	}
	printf("|0x%08" PRIx32 "\n", value);
}

#define C(name) constant(#name, name)
#define V(name) valstr(#name, name, sizeof(name) / sizeof(name[0]))
#define O(name) oemvalstr(#name, name, sizeof(name) / sizeof(name[0]))
#define S(name) strlist(#name, name, sizeof(name) / sizeof(name[0]))

int main(void)
{
#ifdef HAVE_CRYPTO_SHA256
	const int sha256 = 1;
#else
	const int sha256 = 0;
#endif
	printf("strings-c-baseline-v1|%s|sha256=%d\n", STRINGS_BASELINE_REVISION, sha256);
	C(IPMI_1_5_AUTH_TYPE_BIT_MD2);
	C(IPMI_1_5_AUTH_TYPE_BIT_MD5);
	C(IPMI_1_5_AUTH_TYPE_BIT_NONE);
	C(IPMI_1_5_AUTH_TYPE_BIT_OEM);
	C(IPMI_1_5_AUTH_TYPE_BIT_PASSWORD);
	C(IPMI_AUTH_RAKP_HMAC_MD5);
	C(IPMI_AUTH_RAKP_HMAC_SHA1);
	C(IPMI_AUTH_RAKP_HMAC_SHA256);
	C(IPMI_AUTH_RAKP_NONE);
	C(IPMI_CHANNEL_MEDIUM_ICMB_09);
	C(IPMI_CHANNEL_MEDIUM_ICMB_1);
	C(IPMI_CHANNEL_MEDIUM_IPMB_I2C);
	C(IPMI_CHANNEL_MEDIUM_LAN);
	C(IPMI_CHANNEL_MEDIUM_LAN_OTHER);
	C(IPMI_CHANNEL_MEDIUM_RESERVED);
	C(IPMI_CHANNEL_MEDIUM_SERIAL);
	C(IPMI_CHANNEL_MEDIUM_SMBUS_1);
	C(IPMI_CHANNEL_MEDIUM_SMBUS_2);
	C(IPMI_CHANNEL_MEDIUM_SMBUS_PCI);
	C(IPMI_CHANNEL_MEDIUM_SYSTEM);
	C(IPMI_CHANNEL_MEDIUM_USB_1);
	C(IPMI_CHANNEL_MEDIUM_USB_2);
	C(IPMI_CHASSIS_CTL_ACPI_SOFT);
	C(IPMI_CHASSIS_CTL_HARD_RESET);
	C(IPMI_CHASSIS_CTL_POWER_CYCLE);
	C(IPMI_CHASSIS_CTL_POWER_DOWN);
	C(IPMI_CHASSIS_CTL_POWER_UP);
	C(IPMI_CHASSIS_CTL_PULSE_DIAG);
	C(IPMI_CRYPT_AES_CBC_128);
	C(IPMI_CRYPT_NONE);
	C(IPMI_CRYPT_XRC4_128);
	C(IPMI_CRYPT_XRC4_40);
	C(IPMI_INTEGRITY_HMAC_MD5_128);
	C(IPMI_INTEGRITY_HMAC_SHA1_96);
	C(IPMI_INTEGRITY_HMAC_SHA256_128);
	C(IPMI_INTEGRITY_MD5_128);
	C(IPMI_INTEGRITY_NONE);
	C(IPMI_NETFN_APP);
	C(IPMI_NETFN_BRIDGE);
	C(IPMI_NETFN_CHASSIS);
	C(IPMI_NETFN_FIRMWARE);
	C(IPMI_NETFN_SE);
	C(IPMI_NETFN_STORAGE);
	C(IPMI_NETFN_TRANSPORT);
	C(IPMI_OEM_ADLINK_24339);
	C(IPMI_OEM_ADVANTECH);
	C(IPMI_OEM_BROADCOM);
	C(IPMI_OEM_DEBUG);
	C(IPMI_OEM_ERICSSON);
	C(IPMI_OEM_INTEL);
	C(IPMI_OEM_KONTRON);
	C(IPMI_OEM_PICMG);
	C(IPMI_OEM_RESERVED);
	C(IPMI_OEM_SUPERMICRO);
	C(IPMI_OEM_UNKNOWN);
	C(IPMI_OEM_VITA);
	C(IPMI_OEM_YADRO);
	C(IPMI_SESSION_AUTHTYPE_MD2);
	C(IPMI_SESSION_AUTHTYPE_MD5);
	C(IPMI_SESSION_AUTHTYPE_NONE);
	C(IPMI_SESSION_AUTHTYPE_OEM);
	C(IPMI_SESSION_AUTHTYPE_PASSWORD);
	C(IPMI_SESSION_AUTHTYPE_RMCP_PLUS);
	C(IPMI_SESSION_PRIV_ADMIN);
	C(IPMI_SESSION_PRIV_CALLBACK);
	C(IPMI_SESSION_PRIV_NOACCESS);
	C(IPMI_SESSION_PRIV_OEM);
	C(IPMI_SESSION_PRIV_OPERATOR);
	C(IPMI_SESSION_PRIV_USER);
	C(IPMI_SET_IN_PROGRESS_COMMIT_WRITE);
	C(IPMI_SET_IN_PROGRESS_IN_PROGRESS);
	C(IPMI_SET_IN_PROGRESS_SET_COMPLETE);
	V(ipmi_oem_info_head);
	V(ipmi_oem_info_tail);
	V(ipmi_oem_info_dummy);
	O(ipmi_oem_product_info);
	S(ipmi_generic_sensor_type_vals);
	O(ipmi_oem_sensor_type_vals);
	V(ipmi_netfn_vals);
	V(ipmi_bit_rate_vals);
	V(ipmi_channel_activity_type_vals);
	V(ipmi_privlvl_vals);
	V(ipmi_set_in_progress_vals);
	V(ipmi_authtype_session_vals);
	V(ipmi_authtype_vals);
	V(entity_id_vals);
	V(entity_device_type_vals);
	V(ipmi_channel_protocol_vals);
	V(ipmi_channel_medium_vals);
	V(completion_code_vals);
	V(ipmi_chassis_power_control_vals);
	V(ipmi_chassis_restart_cause_vals);
	V(ipmi_auth_algorithms);
	V(ipmi_integrity_algorithms);
	V(ipmi_encryption_algorithms);
	V(ipmi_user_enable_status_vals);
	V(picmg_frucontrol_vals);
	V(picmg_clk_family_vals);
	O(picmg_clk_accuracy_vals);
	O(picmg_clk_resource_vals);
	O(picmg_clk_id_vals);
	V(picmg_busres_id_vals);
	V(picmg_busres_board_cmd_vals);
	V(picmg_busres_shmc_cmd_vals);
	O(picmg_busres_board_status_vals);
	O(picmg_busres_shmc_status_vals);
	return ferror(stdout) ? 1 : 0;
}
