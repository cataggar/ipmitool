/* Exercise the original OpenIPMI transport and the selected Zig ABI with
 * the same C caller, buffered stderr, and a hardware-free ioctl reply.
 */
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <ipmitool/helper.h>
#include <ipmitool/ipmi.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi_sel.h>
#include <ipmitool/log.h>

#if defined(HAVE_CONFIG_H)
# include <config.h>
#endif
#if defined(HAVE_OPENIPMI_H)
# include <linux/ipmi.h>
#else
# include "../src/plugins/open/open.h"
#endif

extern struct ipmi_intf ipmi_open_intf;
int verbose;
static int sim_fd;
static long sent_id;
static int bridged;

void lprintf(int level, const char *format, ...)
{
	(void)format;
	fprintf(stderr, "[logger:%d]", level);
}

void lperror(int level, const char *format, ...)
{
	(void)format;
	fprintf(stderr, "[error:%d]", level);
}

IPMI_OEM ipmi_get_oem(struct ipmi_intf *intf)
{
	(void)intf;
	return IPMI_OEM_UNKNOWN;
}

uint8_t ipmi_csum(uint8_t *data, int len)
{
	unsigned int sum = 0;
	int i;
	for (i = 0; i < len; ++i)
		sum += data[i];
	return (uint8_t)(-sum);
}

const char *buf2str(const uint8_t *data, int len)
{
	static char text[BUF2STR_MAXIMUM_OUTPUT_SIZE];
	int i;
	for (i = 0; i < len; ++i)
		snprintf(text + 2 * i, sizeof(text) - 2 * i, "%02x", data[i]);
	text[2 * len] = '\0';
	return text;
}

void printbuf(const uint8_t *data, int len, const char *desc)
{
	int i;
	if (len <= 0 || verbose < 1)
		return;
	fprintf(stderr, "%s (%d bytes)\n", desc, len);
	for (i = 0; i < len; ++i) {
		if (i && i % 16 == 0)
			fprintf(stderr, "\n");
		fprintf(stderr, " %2.2x", data[i]);
	}
	fprintf(stderr, "\n");
}

#if defined(__GLIBC__)
# define IOCTL_REQUEST unsigned long
#else
# define IOCTL_REQUEST int
#endif
int ioctl(int fd, IOCTL_REQUEST request, ...)
{
	static const uint8_t direct_reply[] = { 0x00, 0x5b };
	static const uint8_t bridged_reply[] = {
		0x00, 0x11, 0xb3, 0x22, 0x33, 0x44, 0x94,
		0x00, 0x5b, 0x6d, 0xc2, 0x39, 0x77, 0x88, 0x99
	};
	const uint8_t *data = bridged ? bridged_reply : direct_reply;
	size_t len = bridged ? sizeof(bridged_reply) : sizeof(direct_reply);
	uint32_t code = (uint32_t)request;
	va_list args;
	void *arg;

	va_start(args, request);
	arg = va_arg(args, void *);
	va_end(args);
	if (fd != sim_fd) {
		errno = EBADF;
		return -1;
	}
	if (code == (uint32_t)IPMICTL_SEND_COMMAND) {
		sent_id = ((struct ipmi_req *)arg)->msgid;
		return 0;
	}
	if (code == (uint32_t)IPMICTL_RECEIVE_MSG_TRUNC) {
		struct ipmi_recv *recv = arg;
		struct ipmi_addr *addr = (struct ipmi_addr *)recv->addr;
		memset(addr, 0, sizeof(*addr));
		addr->channel = bridged ? -42 : 0x6b;
		recv->recv_type = 1;
		recv->msgid = sent_id;
		recv->msg.netfn = 0x2d;
		recv->msg.cmd = 0x94;
		if (recv->msg.data_len < len) {
			errno = EMSGSIZE;
			return -1;
		}
		memcpy(recv->msg.data, data, len);
		recv->msg.data_len = len;
		return 0;
	}
	errno = ENOTTY;
	return -1;
}

int main(void)
{
	static uint8_t data[] = { 0x17, 0x4e, 0x92, 0xdb };
	const int levels[] = { 2, 3, 4, 5 };
	int fds[2];
	size_t i;

	if (pipe(fds) != 0 || setvbuf(stderr, NULL, _IOFBF, 8192) != 0)
		return 1;
	sim_fd = fds[0];
	for (i = 0; i < sizeof(levels) / sizeof(levels[0]); ++i) {
		for (bridged = 0; bridged <= 1; ++bridged) {
			struct ipmi_intf intf = ipmi_open_intf;
			struct ipmi_rq req = { 0 };
			struct ipmi_rs *rsp;
			char ready = 1;

			intf.fd = sim_fd;
			intf.opened = 1;
			intf.my_addr = 0x91;
			if (bridged) {
				intf.target_addr = 0x3c;
				intf.target_channel = 0xbd;
				intf.transit_addr = 0x7e;
				intf.transit_channel = 0x6b;
			}
			req.msg.netfn = 0x2c;
			req.msg.lun = 3;
			req.msg.cmd = 0x94;
			req.msg.data_len = sizeof(data);
			req.msg.data = data;
			verbose = levels[i];
			if (write(fds[1], &ready, 1) != 1)
				return 2;
			fprintf(stderr, "before[%d,%d]|", verbose, bridged);
			rsp = intf.sendrecv(&intf, &req);
			fprintf(stderr, "|after[%d,%d]\n", verbose, bridged);
			if (!rsp || rsp->ccode || rsp->data_len != (bridged ? 6 : 1))
				return 3;
			if (read(fds[0], &ready, 1) != 1)
				return 4;
		}
	}
	if (fflush(stderr) != 0)
		return 5;
	close(fds[0]);
	close(fds[1]);
	return 0;
}
