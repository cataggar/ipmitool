/* Same buffered C caller against the original dump and the selected Zig ABI. */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <ipmitool/helper.h>
#include <ipmitool/ipmi.h>
#include <ipmitool/ipmi_constants.h>
#include "../src/plugins/lanplus/lanplus.h"
#include "../src/plugins/lanplus/lanplus_dump.h"

int verbose;

const struct valstr ipmi_rakp_return_codes[] = {
	{ IPMI_RAKP_STATUS_NO_ERRORS, "no errors" },
	{ IPMI_RAKP_STATUS_INVALID_ROLE, "bad role" },
	{ 0, NULL }
};
const struct valstr ipmi_priv_levels[] = {
	{ 4, "admin" },
	{ 0, NULL }
};
const struct valstr ipmi_auth_algorithms[] = {
	{ IPMI_AUTH_RAKP_HMAC_SHA1, "HMAC-SHA1" },
	{ 0, NULL }
};
const struct valstr ipmi_integrity_algorithms[] = {
	{ 1, "HMAC-SHA1-96" },
	{ 0, NULL }
};
const struct valstr ipmi_encryption_algorithms[] = {
	{ 1, "AES-CBC-128" },
	{ 0, NULL }
};

const char *val2str(uint32_t value, const struct valstr *table)
{
	for (; table->str; table++) {
		if (table->val == value)
			return table->str;
	}
	return "unknown";
}

static void dump_one(struct ipmi_rs *rsp, int status, uint8_t auth_alg)
{
	unsigned int i;

	memset(rsp, 0, sizeof(*rsp));
	rsp->payload.open_session_response.message_tag = 0x0a;
	rsp->payload.open_session_response.rakp_return_code = status;
	rsp->payload.open_session_response.max_priv_level = 4;
	rsp->payload.open_session_response.console_id = 0x89abcdef;
	rsp->payload.open_session_response.bmc_id = 0x10203040;
	rsp->payload.open_session_response.auth_alg = IPMI_AUTH_RAKP_HMAC_SHA1;
	rsp->payload.open_session_response.integrity_alg = 1;
	rsp->payload.open_session_response.crypt_alg = 0xff;
	printf("before open[%d,%d]|", verbose, status);
	lanplus_dump_open_session_response(rsp);
	printf("|after open\n");

	memset(rsp, 0, sizeof(*rsp));
	rsp->payload.rakp2_message.message_tag = 0x0b;
	rsp->payload.rakp2_message.rakp_return_code = status;
	rsp->payload.rakp2_message.console_id = 0xfedcba98;
	for (i = 0; i < 16; i++) {
		rsp->payload.rakp2_message.bmc_rand[i] = i * 17;
		rsp->payload.rakp2_message.bmc_guid[i] = 255 - i * 15;
	}
	for (i = 0; i < IPMI_MAX_MD_SIZE; i++)
		rsp->payload.rakp2_message.key_exchange_auth_code[i] = 255 - i * 7;
	printf("before rakp2[%d,%d,%u]|", verbose, status, auth_alg);
	lanplus_dump_rakp2_message(rsp, auth_alg);
	printf("|after rakp2\n");

	memset(rsp, 0, sizeof(*rsp));
	rsp->payload.rakp4_message.message_tag = 0x0c;
	rsp->payload.rakp4_message.rakp_return_code = status;
	rsp->payload.rakp4_message.console_id = 0x80000001;
	for (i = 0; i < IPMI_MAX_MD_SIZE; i++)
		rsp->payload.rakp4_message.integrity_check_value[i] = i * 7;
	printf("before rakp4[%d,%d,%u]|", verbose, status, auth_alg);
	lanplus_dump_rakp4_message(rsp, auth_alg);
	printf("|after rakp4\n");
}

int main(void)
{
	static const uint8_t algs[] = {
		IPMI_AUTH_RAKP_NONE, IPMI_AUTH_RAKP_HMAC_SHA1,
		IPMI_AUTH_RAKP_HMAC_MD5, IPMI_AUTH_RAKP_HMAC_SHA256, 0xff
	};
	struct ipmi_rs rsp;
	unsigned int i;
	int status;

	if (setvbuf(stdout, NULL, _IOFBF, 4096))
		return 1;
	for (verbose = 0; verbose <= 2; verbose += 2) {
		for (status = 0; status <= IPMI_RAKP_STATUS_INVALID_ROLE;
		     status += IPMI_RAKP_STATUS_INVALID_ROLE) {
			for (i = 0; i < sizeof(algs); i++)
				dump_one(&rsp, status, algs[i]);
		}
	}
	return 0;
}
