/* A fake LAN interface for driving the real TSOL command under a PTY. */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <stdarg.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/poll.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include <ipmitool/helper.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi_strings.h>
#include <ipmitool/ipmi_tsol.h>
#include <ipmitool/log.h>

int verbose;
const struct valstr completion_code_vals[] = { { 0, NULL } };

static int event_fd;
static long fake_time = 100000;

static void event(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vdprintf(event_fd, fmt, ap);
	va_end(ap);
}

void lprintf(int level, const char *fmt, ...)
{
	va_list ap;
	(void)level;
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

void lperror(int level, const char *fmt, ...)
{
	(void)level;
	fprintf(stderr, "%s: %s\n", fmt, strerror(errno));
}

const char *val2str(uint32_t value, const struct valstr *vs)
{
	(void)value;
	(void)vs;
	return "mock completion code";
}

int gettimeofday(struct timeval *tv, void *tz)
{
	if (getenv("TSOL_FAST_CLOCK")) {
		tv->tv_sec = fake_time;
		tv->tv_usec = 0;
		return 0;
	}
	return syscall(SYS_gettimeofday, tv, tz);
}

int poll(struct pollfd *fds, nfds_t count, int timeout)
{
	const char *tick_fd = getenv("TSOL_TICK_FD");
	struct timespec delay;
	if (getenv("TSOL_POLL_FAIL")) {
		errno = EIO;
		return -1;
	}
	if (tick_fd) {
		char tick;
		ssize_t n;
		do {
			n = syscall(SYS_read, atoi(tick_fd), &tick, 1);
		} while (n < 0 && errno == EINTR);
		if (n != 1 || (tick != 't' && tick != 'f')) {
			errno = EIO;
			return -1;
		}
		/* Only explicit ticks move time; input polls leave keepalive frozen. */
		if (tick == 't')
			fake_time += 31;
	}
	delay.tv_sec = 0;
	delay.tv_nsec = (timeout > 100 ? 100 : timeout) * 1000000L;
	return syscall(SYS_ppoll, fds, count, &delay, NULL, 0);
}

ssize_t read(int fd, void *buffer, size_t length)
{
	ssize_t n;
	if (fd == STDIN_FILENO && getenv("TSOL_DELAY_STDIN"))
		usleep(350000);
	n = syscall(SYS_read, fd, buffer, length);
	if (fd == STDIN_FILENO && n > 0)
		/* Reuse the event pipe so snapshots need no extra control channel. */
		event("stdin-read=%zd\n", n);
	return n;
}

int kill(pid_t pid, int signal)
{
	if (pid == getpid() && signal == SIGTSTP) {
		event("suspend\n");
		return 0;
	}
	errno = EINVAL;
	return -1;
}

static int open_lan(struct ipmi_intf *intf)
{
	struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(9) };
	if (getenv("TSOL_OPEN_FAIL")) {
		event("open failed\n");
		return -1;
	}
	if (getenv("TSOL_GETSOCK_FAIL")) {
		event("open no socket\n");
		intf->fd = -1;
		return 0;
	}
	intf->fd = socket(AF_INET, SOCK_DGRAM, 0);
	inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
	if (intf->fd < 0 || connect(intf->fd, (void *)&addr, sizeof(addr)) < 0)
		return -1;
	event("open local\n");
	return intf->fd;
}

int socket(int domain, int type, int protocol)
{
	if (getenv("TSOL_SOCKET_FAIL")) {
		errno = EMFILE;
		return -1;
	}
	return syscall(SYS_socket, domain, type, protocol);
}

static int keepalive(struct ipmi_intf *intf)
{
	(void)intf;
	event("keepalive\n");
	return getenv("TSOL_KEEPALIVE_FAIL") ? -1 : 0;
}

static struct ipmi_rs *sendrecv(struct ipmi_intf *intf, struct ipmi_rq *req)
{
	static struct ipmi_rs rsp;
	struct winsize size = { 0 };
	unsigned i;
	(void)intf;
	event("netfn=%02x cmd=%02x data=", req->msg.netfn, req->msg.cmd);
	for (i = 0; i < req->msg.data_len; i++)
		event("%02x", req->msg.data[i]);
	event("\n");
	if (req->msg.cmd == IPMI_TSOL_CMD_START) {
		ioctl(STDOUT_FILENO, TIOCGWINSZ, &size);
		event("active size=%dx%d\n", size.ws_row, size.ws_col);
	}
	memset(&rsp, 0, sizeof(rsp));
	if (req->msg.cmd == IPMI_TSOL_CMD_START && getenv("TSOL_START_FAIL"))
		return getenv("TSOL_START_NULL") ? NULL : (rsp.ccode = 0x83, &rsp);
	if (req->msg.cmd == IPMI_TSOL_CMD_STOP && getenv("TSOL_STOP_FAIL"))
		rsp.ccode = 0x83;
	if (req->msg.cmd == IPMI_TSOL_CMD_SENDKEY &&
	    (getenv("TSOL_KEY_FAIL") || getenv("TSOL_KEY_NULL"))) {
		usleep(20000);
		if (getenv("TSOL_KEY_FAIL"))
			rsp.ccode = 0x83;
	}
	if (req->msg.cmd == IPMI_TSOL_CMD_SENDKEY && getenv("TSOL_KEY_NULL"))
		return NULL;
	return &rsp;
}

int main(int argc, char **argv)
{
	struct ipmi_intf intf = { 0 };
	struct ipmi_session session = { 0 };
	struct termios before, after;
	struct winsize size = { 0 };
	struct sockaddr_in addr = { .sin_family = AF_INET };
	int result;
	int test_socket, port = -1, reuse = -1, i;
	const char *fd = getenv("TSOL_EVENT_FD");

	if (!fd || argc < 2)
		return 2;
	event_fd = atoi(fd);
	setvbuf(stdout, NULL, _IONBF, 0);
	memcpy(intf.name, getenv("TSOL_BAD_INTF") ? "dummy" : "lan", 4);
	intf.fd = -1;
	intf.session = &session;
	intf.ssn_params.hostname = getenv("TSOL_BAD_HOST") ? "invalid.invalid" : "127.0.0.1";
	intf.ssn_params.sol_escape_char = '~';
	intf.open = open_lan;
	intf.sendrecv = sendrecv;
	intf.keepalive = keepalive;
	verbose = !!getenv("TSOL_VERBOSE");
	tcgetattr(STDIN_FILENO, &before);
	result = ipmi_tsol_main(&intf, argc - 1, argv + 1);
	tcgetattr(STDIN_FILENO, &after);
	ioctl(STDOUT_FILENO, TIOCGWINSZ, &size);
	for (i = 1; i < argc; i++)
		if (sscanf(argv[i], "port=%d", &port) == 1)
			break;
	if (port >= 0) {
		addr.sin_port = htons(port);
		test_socket = socket(AF_INET, SOCK_DGRAM, 0);
		if (test_socket >= 0) {
			reuse = bind(test_socket, (void *)&addr, sizeof(addr)) == 0;
			close(test_socket);
		}
	}
	event("final result=%d raw=%d size=%dx%d reusable=%d\n", result,
		!!(after.c_lflag & ICANON) != !!(before.c_lflag & ICANON),
		size.ws_row, size.ws_col, reuse);
	if (intf.fd >= 0)
		close(intf.fd);
	return result < 0 ? 1 : result;
}
