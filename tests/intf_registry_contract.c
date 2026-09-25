/* Differential contract for the C and Zig implementations of ipmi_intf.c. */
#include <assert.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <config.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi_sdr.h>
#include <ipmitool/log.h>

extern struct ipmi_intf *ipmi_intf_table[];
void ipmi_intf_set_max_request_data_size(struct ipmi_intf *, uint16_t);
void ipmi_intf_set_max_response_data_size(struct ipmi_intf *, uint16_t);

#ifdef IPMI_INTF_OPEN
struct ipmi_intf ipmi_open_intf = { .name = "open", .desc = "open fixture" };
#endif
#ifdef IPMI_INTF_LAN
struct ipmi_intf ipmi_lan_intf = { .name = "lan", .desc = "lan fixture" };
#endif
#ifdef IPMI_INTF_LANPLUS
struct ipmi_intf ipmi_lanplus_intf = { .name = "lanplus", .desc = "lanplus fixture" };
#endif
#ifdef IPMI_INTF_SERIAL
struct ipmi_intf ipmi_serial_term_intf = { .name = "serial-terminal", .desc = "serial terminal fixture" };
struct ipmi_intf ipmi_serial_bm_intf = { .name = "serial-basic", .desc = "serial basic fixture" };
#endif
#ifdef IPMI_INTF_DUMMY
struct ipmi_intf ipmi_dummy_intf = { .name = "dummy", .desc = "dummy fixture" };
#endif
#ifdef IPMI_INTF_USB
struct ipmi_intf ipmi_usb_intf = { .name = "usb", .desc = "usb fixture" };
#endif

static unsigned sdr_clears;
static unsigned setups;
static unsigned request_hooks;
static unsigned response_hooks;

void ipmi_sdr_list_empty(void)
{
	++sdr_clears;
}

void lprintf(int level, const char *format, ...)
{
	va_list ap;
	printf("log(%d): ", level);
	va_start(ap, format);
	vprintf(format, ap);
	va_end(ap);
	putchar('\n');
}

static int setup_ok(struct ipmi_intf *intf)
{
	(void)intf;
	++setups;
	return 0;
}

static int setup_bad(struct ipmi_intf *intf)
{
	(void)intf;
	++setups;
	return -1;
}

static void request_hook(struct ipmi_intf *intf, uint16_t size)
{
	(void)intf;
	assert(size == 27);
	++request_hooks;
}

static void response_hook(struct ipmi_intf *intf, uint16_t size)
{
	(void)intf;
	assert(size == 26);
	++response_hooks;
}

static void check_table(void)
{
	static const char *const expected[] = {
#ifdef IPMI_INTF_OPEN
		"open",
#endif
#ifdef IPMI_INTF_LAN
		"lan",
#endif
#ifdef IPMI_INTF_LANPLUS
		"lanplus",
#endif
#ifdef IPMI_INTF_SERIAL
		"serial-terminal", "serial-basic",
#endif
#ifdef IPMI_INTF_DUMMY
		"dummy",
#endif
#ifdef IPMI_INTF_USB
		"usb",
#endif
	};
	struct ipmi_intf_support filter[3];
	struct ipmi_intf *selected;
	size_t i;
	char unknown[] = "unknown-interface";

	assert(sizeof(expected) / sizeof(expected[0]) > 0);
	for (i = 0; i < sizeof(expected) / sizeof(expected[0]); ++i) {
		assert(ipmi_intf_table[i] != NULL);
		assert(strcmp(ipmi_intf_table[i]->name, expected[i]) == 0);
		printf("table[%zu]=%s\n", i, ipmi_intf_table[i]->name);
	}
	assert(ipmi_intf_table[i] == NULL);
	assert(ipmi_intf_load(unknown) == NULL);

	selected = ipmi_intf_load(NULL);
	assert(selected && strcmp(selected->name, DEFAULT_INTF) == 0);
	printf("default=%s\n", selected->name);
	ipmi_intf_print(NULL);

	filter[0] = (struct ipmi_intf_support) { selected->name, 0 };
	filter[1] = (struct ipmi_intf_support) { selected->name, 1 };
	filter[2] = (struct ipmi_intf_support) { NULL, 0 };
	ipmi_intf_print(filter);

	selected->setup = setup_ok;
	assert(ipmi_intf_load(NULL) == selected);
	assert(ipmi_intf_load(selected->name) == selected);
	selected->setup = setup_bad;
	assert(ipmi_intf_load(selected->name) == NULL);
	assert(ipmi_intf_load(NULL) == NULL);
	assert(setups == 4);
	selected->setup = NULL;
	puts("selection-ok");
}

static void check_session(void)
{
	struct ipmi_intf intf = {0};
	char username[] = "0123456789abcdefEXTRA";
	char password[] = "0123456789abcdefghijEXTRA";
	uint8_t kg[IPMI_KG_BUFFER_SIZE];
	unsigned i;

	ipmi_intf_session_set_hostname(&intf, "first.example");
	assert(strcmp(intf.ssn_params.hostname, "first.example") == 0);
	ipmi_intf_session_set_hostname(&intf, "second.example");
	assert(strcmp(intf.ssn_params.hostname, "second.example") == 0);
	ipmi_intf_session_set_username(&intf, username);
	assert(memcmp(intf.ssn_params.username, username, 16) == 0);
	assert(intf.ssn_params.username[16] == 0);
	ipmi_intf_session_set_username(&intf, NULL);
	assert(intf.ssn_params.username[0] == 0);

	intf.ssn_params.authcode_set[IPMI_AUTHCODE_BUFFER_SIZE] = 0x7e;
	ipmi_intf_session_set_password(&intf, password);
	assert(intf.ssn_params.password == 1);
	assert(memcmp(intf.ssn_params.authcode_set, password, IPMI_AUTHCODE_BUFFER_SIZE) == 0);
	ipmi_intf_session_set_authtype(&intf, IPMI_SESSION_AUTHTYPE_NONE);
	assert(intf.ssn_params.password == 0);
	for (i = 0; i < IPMI_AUTHCODE_BUFFER_SIZE; ++i)
		assert(intf.ssn_params.authcode_set[i] == 0);
	assert(intf.ssn_params.authcode_set[IPMI_AUTHCODE_BUFFER_SIZE] == 0x7e);

	ipmi_intf_session_set_password(&intf, password);
	ipmi_intf_session_set_authtype(&intf, IPMI_SESSION_AUTHTYPE_MD5);
	assert(intf.ssn_params.password == 1);
	ipmi_intf_session_set_password(&intf, NULL);
	assert(intf.ssn_params.password == 0);
	ipmi_intf_session_set_privlvl(&intf, 4);
	ipmi_intf_session_set_lookupbit(&intf, 1);
#ifdef IPMI_INTF_LANPLUS
	ipmi_intf_session_set_cipher_suite_id(&intf, IPMI_LANPLUS_CIPHER_SUITE_3);
	assert(intf.ssn_params.cipher_suite_id == IPMI_LANPLUS_CIPHER_SUITE_3);
#endif
	ipmi_intf_session_set_sol_escape_char(&intf, '~');
	ipmi_intf_session_set_port(&intf, 623);
	ipmi_intf_session_set_timeout(&intf, 1234);
	ipmi_intf_session_set_retry(&intf, 5);
	for (i = 0; i < sizeof(kg); ++i) kg[i] = (uint8_t)(i + 1);
	ipmi_intf_session_set_kgkey(&intf, kg);
	assert(memcmp(intf.ssn_params.kg, kg, sizeof(kg)) == 0);
	assert(intf.ssn_params.privlvl == 4 && intf.ssn_params.lookupbit == 1);
	assert(intf.ssn_params.sol_escape_char == '~' && intf.ssn_params.port == 623);
	assert(intf.ssn_params.timeout == 1234 && intf.ssn_params.retry == 5);

	intf.session = malloc(sizeof(*intf.session));
	assert(intf.session);
	ipmi_intf_session_cleanup(&intf);
	assert(!intf.session);
	ipmi_cleanup(&intf);
	assert(!intf.ssn_params.hostname && sdr_clears == 1);
	puts("session-ok");
}

static void check_payload(void)
{
	struct ipmi_intf intf = {0};
	assert(ipmi_intf_get_bridging_level(&intf) == 0);
	assert(ipmi_intf_get_max_request_data_size(&intf) == 25);
	assert(ipmi_intf_get_max_response_data_size(&intf) == 25);
	intf.my_addr = 0x20;
	intf.target_addr = 0x82;
	assert(ipmi_intf_get_bridging_level(&intf) == 1);
	assert(ipmi_intf_get_max_request_data_size(&intf) == 25);
	assert(ipmi_intf_get_max_response_data_size(&intf) == 24);
	intf.transit_addr = 0x84;
	assert(ipmi_intf_get_bridging_level(&intf) == 2);
	assert(ipmi_intf_get_max_request_data_size(&intf) == 17);
	assert(ipmi_intf_get_max_response_data_size(&intf) == 16);
	intf.transit_addr = intf.target_addr;
	intf.transit_channel = intf.target_channel;
	assert(ipmi_intf_get_bridging_level(&intf) == 1);
	intf.transit_channel = 2;
	assert(ipmi_intf_get_bridging_level(&intf) == 2);

	intf.target_addr = intf.my_addr;
	intf.max_request_data_size = 0x8000;
	intf.max_response_data_size = 0xffff;
	assert(ipmi_intf_get_max_request_data_size(&intf) == 0);
	assert(ipmi_intf_get_max_response_data_size(&intf) == 0);
	intf.set_max_request_data_size = request_hook;
	intf.set_max_response_data_size = response_hook;
	ipmi_intf_set_max_request_data_size(&intf, 24);
	ipmi_intf_set_max_response_data_size(&intf, 23);
	assert(request_hooks == 0 && response_hooks == 0);
	ipmi_intf_set_max_request_data_size(&intf, 27);
	ipmi_intf_set_max_response_data_size(&intf, 26);
	assert(request_hooks == 1 && response_hooks == 1);
	intf.set_max_request_data_size = NULL;
	intf.set_max_response_data_size = NULL;
	ipmi_intf_set_max_request_data_size(&intf, 27);
	ipmi_intf_set_max_response_data_size(&intf, 26);
	assert(intf.max_request_data_size == 27 && intf.max_response_data_size == 26);
	puts("payload-ok");
}

static void check_socket(void)
{
#if defined(IPMI_INTF_LAN) || defined(IPMI_INTF_LANPLUS)
	struct ipmi_intf intf = {0};
	struct sockaddr_in peer;
	socklen_t size = sizeof(peer);

	assert(ipmi_intf_socket_connect(NULL) == -1);
	assert(ipmi_intf_socket_connect(&intf) == -1);
	ipmi_intf_session_set_hostname(&intf, "127.0.0.1");
	intf.ssn_params.port = 9;
	intf.ai_family = AF_INET;
	intf.fd = -1;
	assert(ipmi_intf_socket_connect(&intf) == 0);
	assert(getpeername(intf.fd, (struct sockaddr *)&peer, &size) == 0);
	assert(peer.sin_family == AF_INET && ntohs(peer.sin_port) == 9);
	assert(peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK));
	close(intf.fd);
	ipmi_intf_session_set_hostname(&intf, NULL);
	puts("socket-ok");
#endif
}

int main(void)
{
	check_table();
	check_session();
	check_payload();
	check_socket();
	return 0;
}
