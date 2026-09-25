/*
 * Small C ABI contract test for lib/ipmi_cfgp.c, lib/ipmi_session.c and
 * lib/hpm2.c. Run first with the original C objects, then with the Zig
 * replacements; no BMC or network is required.
 */
#define _GNU_SOURCE
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ipmitool/hpm2.h>
#include <ipmitool/helper.h>
#include <ipmitool/ipmi.h>
#include <ipmitool/ipmi_cfgp.h>
#include <ipmitool/ipmi_session.h>
#include <ipmitool/ipmi_strings.h>
#include <ipmitool/log.h>

int csv_output;
const struct valstr ipmi_privlvl_vals[] = {{1, "CALLBACK"}, {0, NULL}};
const struct valstr ipmi_channel_activity_type_vals[] = {{1, "PPP"}, {0, NULL}};
const struct valstr completion_code_vals[] = {{0xc1, "Invalid command"}, {0, NULL}};

void lprintf(int level, const char *fmt, ...)
{
	(void)level;
	(void)fmt;
}

const char *val2str(uint32_t val, const struct valstr *vs)
{
	for (; vs->str; ++vs)
		if (vs->val == val)
			return vs->str;
	return "Unknown";
}

const char *mac2str(const uint8_t *mac)
{
	(void)mac;
	return "00:00:00:00:00:00";
}

int str2int(const char *str, int32_t *value)
{
	char *end;
	long n = strtol(str, &end, 0);
	if (end == str || *end || n < INT32_MIN || n > INT32_MAX)
		return -1;
	*value = (int32_t)n;
	return 0;
}

int str2uint(const char *str, uint32_t *value)
{
	char *end;
	unsigned long n = strtoul(str, &end, 0);
	if (end == str || *end || n > UINT32_MAX)
		return -1;
	*value = (uint32_t)n;
	return 0;
}

static struct ipmi_rs response;
static unsigned char wire[5];
static int wire_len, sends, no_response;
static uint16_t request_size, response_size;
static const unsigned char *second_response;
static int second_len;

static struct ipmi_rs *sendrecv(struct ipmi_intf *intf, struct ipmi_rq *req)
{
	(void)intf;
	assert(req->msg.data_len <= sizeof(wire));
	wire_len = req->msg.data_len;
	memcpy(wire, req->msg.data, wire_len);
	++sends;
	if (no_response)
		return NULL;
	if (sends == 2 && second_response) {
		response.data_len = second_len;
		memcpy(response.data, second_response, second_len);
	}
	return &response;
}

void ipmi_intf_set_max_request_data_size(struct ipmi_intf *intf, uint16_t size)
{
	request_size = size;
	intf->max_request_data_size = size;
}

void ipmi_intf_set_max_response_data_size(struct ipmi_intf *intf, uint16_t size)
{
	response_size = size;
	intf->max_response_data_size = size;
}

static struct ipmi_intf intf = {
	.name = "lan",
	.sendrecv = sendrecv,
};

static void reply(const unsigned char *data, int len, int ccode)
{
	memset(&response, 0, sizeof(response));
	response.ccode = ccode;
	response.data_len = len;
	if (len > 0)
		memcpy(response.data, data, len);
	no_response = 0;
	sends = 0;
	second_response = NULL;
}

struct cfg_state {
	int gets, sets, saves, prints, last_quiet;
};

static int cfg_handler(void *priv, const struct ipmi_cfgp *p,
		       const struct ipmi_cfgp_action *action, unsigned char *data)
{
	struct cfg_state *state = priv;
	(void)p;
	switch (action->type) {
	case CFGP_PARSE:
		if (action->argc != 1 || str2int(action->argv[0], (int32_t *)&state->last_quiet))
			return -1;
		data[0] = (unsigned char)state->last_quiet;
		return 0;
	case CFGP_GET:
		++state->gets;
		state->last_quiet = action->quiet;
		if (action->set > 2 || action->block > 1)
			return -1;
		data[0] = (unsigned char)(action->set * 10 + action->block);
		return 0;
	case CFGP_SET:
		++state->sets;
		return 0;
	case CFGP_SAVE:
		++state->saves;
		fprintf(action->file, "%02x", data[0]);
		return 0;
	case CFGP_PRINT:
		++state->prints;
		fprintf(action->file, "%02x", data[0]);
		return 0;
	default:
		abort();
	}
}

static void cfgp_contract(void)
{
	struct ipmi_cfgp_ctx ctx;
	struct cfg_state state = {0};
	struct ipmi_cfgp_sel sel;
	const struct ipmi_cfgp params[] = {
		{"matrix", "<value>", 1, CFGP_RDWR, 1, 1, 1, 1, 0},
		{"readonly", NULL, 1, CFGP_RDONLY, 0, 0, 0, 0, 0},
		{"writeonly", "<value>", 1, CFGP_WRONLY, 0, 0, 0, 0, 0},
	};
	const char *args[] = {"MATRIX", "1", "1", "42"};
	char *text = NULL;
	size_t size = 0;
	FILE *out;

	assert(ipmi_cfgp_init(NULL, params, 3, "lan6", cfg_handler, &state) == -1);
	assert(ipmi_cfgp_init(&ctx, params, 3, "lan6", cfg_handler, &state) == 0);
	assert(ipmi_cfgp_parse_sel(&ctx, 0, args, &sel) == 0 && sel.param == -1);
	assert(ipmi_cfgp_parse_sel(&ctx, 3, args, &sel) == 3);
	assert(sel.param == 0 && sel.set == 1 && sel.block == 1);
	assert(ipmi_cfgp_parse_data(&ctx, &sel, 1, &args[3]) == 0);
	assert(ctx.v && ctx.v->data[0] == 42 && !ctx.v->next);
	out = open_memstream(&text, &size);
	assert(out);
	assert(ipmi_cfgp_save(&ctx, &sel, out) == 0);
	fclose(out);
	assert(strcmp(text, "lan6 matrix 1 1 2a\n") == 0);
	free(text);
	text = NULL;
	out = open_memstream(&text, &size);
	assert(out);
	assert(ipmi_cfgp_print(&ctx, &sel, out) == 0);
	fclose(out);
	assert(strcmp(text, "2a") == 0);
	free(text);
	assert(ipmi_cfgp_set(&ctx, &sel) == 0 && state.sets == 1);
	assert(ipmi_cfgp_parse_data(&ctx, &sel, 1, (const char *[]){"not-a-number"}) == -1);
	assert(ctx.v && !ctx.v->next);
	assert(ipmi_cfgp_uninit(&ctx) == 0 && !ctx.v);
	assert(ipmi_cfgp_uninit(NULL) == -1);

	/* A wildcard GET scans sets/blocks, retaining successful blocks and
	 * treating the end-of-scan error as normal once quiet is enabled. */
	sel = (struct ipmi_cfgp_sel){0, -1, -1};
	state.gets = 0;
	assert(ipmi_cfgp_get(&ctx, &sel) == 0);
	assert(state.gets == 5 && state.last_quiet == 1);
	assert(ctx.v && ctx.v->data[0] == 11);
	assert(ctx.v->next && ctx.v->next->data[0] == 21);
	assert(!ctx.v->next->next);
	assert(ipmi_cfgp_uninit(&ctx) == 0);

	sel = (struct ipmi_cfgp_sel){0, 3, 1};
	assert(ipmi_cfgp_get(&ctx, &sel) == -1 && !ctx.v);
	assert(ipmi_cfgp_parse_sel(&ctx, 2, (const char *[]){"matrix", "0"}, &sel) == -1);
	assert(ipmi_cfgp_parse_sel(&ctx, 3, (const char *[]){"matrix", "1", "0"}, &sel) == -1);
	assert(ipmi_cfgp_parse_sel(&ctx, 1, (const char *[]){"readonly"}, &sel) == 1);
	assert(sel.param == 1 && sel.set == 0 && sel.block == 0);
	assert(ipmi_cfgp_parse_sel(&ctx, 1, (const char *[]){"bogus"}, &sel) == -1);
}

static void hpm2_contract(void)
{
	static const unsigned char good[] = {0, 2, 1, 3, 0, 1, 0xc0, 1, 0xc1, 1};
	static const unsigned char channel[] = {0x11, 3, 4, 5, 38, 0, 44, 0};
	struct hpm2_lan_attach_capabilities caps;
	struct hpm2_lan_channel_capabilities chan;
	unsigned char bad[sizeof(good)];

	reply(good, sizeof(good), 0);
	assert(hpm2_get_capabilities(&intf, &caps) == 0);
	assert(wire_len == 2 && wire[0] == 0 && wire[1] == 2);
	assert(caps.hpm2_revision_id == 1 && caps.lan_channel_mask == 3);
	assert(caps.hpm2_sol_params_start == 0xc1);
	reply(good, sizeof(good), 0xc1);
	assert(hpm2_get_capabilities(&intf, &caps) == 0xc1);
	assert(caps.lan_channel_mask == 0);
	reply(good, sizeof(good), 0);
	no_response = 1;
	assert(hpm2_get_capabilities(&intf, &caps) == -1);
	no_response = 0;
	reply(good, 1, 0);
	assert(hpm2_get_capabilities(&intf, &caps) == -1);
	reply(good, 3, 0);
	assert(hpm2_get_capabilities(&intf, &caps) == -1);
	memcpy(bad, good, sizeof(bad));
	bad[1] = 3;
	reply(bad, sizeof(bad), 0);
	assert(hpm2_get_capabilities(&intf, &caps) == 0);
	memcpy(bad, good, sizeof(bad));
	bad[2] = 0;
	reply(bad, sizeof(bad), 0);
	assert(hpm2_get_capabilities(&intf, &caps) == -1);
	memcpy(bad, good, sizeof(bad));
	bad[6] = 0xbf;
	reply(bad, sizeof(bad), 0);
	assert(hpm2_get_capabilities(&intf, &caps) == -1);
	reply(good, 8, 0); /* SOL extension requires ten bytes */
	assert(hpm2_get_capabilities(&intf, &caps) == -1);
	reply(channel, sizeof(channel), 0);
	assert(hpm2_get_lan_channel_capabilities(&intf, 0xc0, &chan) == 0);
	assert(wire_len == 4 && wire[0] == 0xe && wire[1] == 0xc0 &&
	       wire[2] == 0 && wire[3] == 0);
	assert(chan.max_inbound_pld_size == 38 && chan.max_outbound_pld_size == 44);
	reply(channel, sizeof(channel), 0x80);
	assert(hpm2_get_lan_channel_capabilities(&intf, 0xc0, &chan) == 0x80);
	reply(channel, 7, 0);
	assert(hpm2_get_lan_channel_capabilities(&intf, 0xc0, &chan) == -1);
	memcpy(bad, channel, sizeof(channel));
	bad[0] = 0x10;
	reply(bad, sizeof(channel), 0);
	assert(hpm2_get_lan_channel_capabilities(&intf, 0xc0, &chan) == -1);
	reply(good, sizeof(good), 0);
	second_response = channel;
	second_len = sizeof(channel);
	request_size = response_size = 0;
	assert(hpm2_detect_max_payload_size(&intf) == 0 && sends == 2);
	assert(request_size == 31 && response_size == 36);
	assert(intf.max_request_data_size == 31 && intf.max_response_data_size == 36);
	reply(good, sizeof(good), 0xc1);
	assert(hpm2_detect_max_payload_size(&intf) == 0xc1 && sends == 1);
}

static void session_contract(void)
{
	static const unsigned char current[] = {1, 4, 1, 1, 1, 4, 1};
	char *active[] = {"info", "active"};
	char *by_id[] = {"info", "id", "0x12345678"};
	char *by_handle[] = {"info", "handle", "0x1234"};
	char *all[] = {"info", "all"};
	char *missing[] = {"info", "handle"};
	char *invalid[] = {"info", "id", "oops"};

	reply(current, sizeof(current), 0);
	assert(ipmi_session_main(&intf, 2, active) == 0);
	assert(wire_len == 1 && wire[0] == 0);
	reply(current, sizeof(current), 0);
	assert(ipmi_session_main(&intf, 3, by_id) == 0);
	assert(wire_len == 5 && memcmp(wire, "\xff\x78\x56\x34\x12", 5) == 0);
	reply(current, sizeof(current), 0);
	assert(ipmi_session_main(&intf, 3, by_handle) == 0);
	assert(wire_len == 2 && wire[0] == 0xfe && wire[1] == 0x34);
	reply((const unsigned char[]){1, 2, 1}, 3, 0);
	assert(ipmi_session_main(&intf, 2, all) == 0 && sends == 2);
	assert(wire_len == 1 && wire[0] == 2);
	assert(ipmi_session_main(&intf, 2, missing) == -1);
	assert(ipmi_session_main(&intf, 3, invalid) == -1);
	reply(current, sizeof(current), 0xc1);
	assert(ipmi_session_main(&intf, 2, active) == -1);
	reply(current, sizeof(current), 0);
	no_response = 1;
	assert(ipmi_session_main(&intf, 2, active) == -1);
	no_response = 0;
}

int main(void)
{
	cfgp_contract();
	hpm2_contract();
	session_contract();
	puts("command support C ABI contracts passed");
	return 0;
}
