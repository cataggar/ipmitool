/* The same buffered libc caller exercises the original C raw command and its Zig ABI. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ipmitool/helper.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi_raw.h>
#include <ipmitool/ipmi_strings.h>
#include <ipmitool/log.h>

int verbose;

const struct valstr ipmi_netfn_vals[] = {{0, NULL}};
const struct valstr completion_code_vals[] = {{0, NULL}};

void lprintf(int level, const char *format, ...)
{
	(void)level;
	(void)format;
}

void printbuf(const uint8_t *buf, int len, const char *desc)
{
	(void)buf;
	(void)len;
	(void)desc;
}

void print_valstr(const struct valstr *vals, const char *title, int level)
{
	(void)vals;
	(void)title;
	(void)level;
}

const char *val2str(uint32_t val, const struct valstr *vals)
{
	(void)val;
	(void)vals;
	return "unknown";
}

uint32_t str2val32(const char *str, const struct valstr *vals)
{
	(void)str;
	(void)vals;
	return 0xff;
}

int str2uchar(const char *str, uint8_t *out)
{
	char *end;
	unsigned long val = strtoul(str, &end, 0);

	if (*end || val > UINT8_MAX)
		return -1;
	*out = (uint8_t)val;
	return 0;
}

int ipmi_spd_print(uint8_t *data, int len)
{
	(void)data;
	(void)len;
	return 0;
}

static struct ipmi_rs response;

static struct ipmi_rs *sendrecv(struct ipmi_intf *intf, struct ipmi_rq *req)
{
	(void)intf;
	if (req->msg.netfn != 6 || req->msg.cmd != 0x20 || req->msg.data_len != 0)
		return NULL;
	return &response;
}

int main(void)
{
	const int sizes[] = {0, 1, 15, 16, 17, 31, 32, 33, 256, 1024};
	struct ipmi_intf intf = {0};
	char netfn[] = "0x06";
	char cmd[] = "0x20";
	char *args[] = {netfn, cmd};
	size_t n;
	int i;

	intf.sendrecv = sendrecv;
	if (setvbuf(stdout, NULL, _IOFBF, 4096))
		return 1;
	for (n = 0; n < sizeof(sizes) / sizeof(sizes[0]); n++) {
		memset(&response, 0, sizeof(response));
		response.data_len = sizes[n];
		for (i = 0; i < response.data_len; i++)
			response.data[i] = (uint8_t)(i * 41);
		printf("before[%d]|", response.data_len);
		if (ipmi_raw_main(&intf, 2, args))
			return 2;
		printf("|after[%d]\n", response.data_len);
	}
	return 0;
}
