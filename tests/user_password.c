#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ipmitool/helper.h>
#include <ipmitool/ipmi_intf.h>
#include <ipmitool/ipmi_strings.h>
#include <ipmitool/ipmi_user.h>
#include <ipmitool/log.h>

int verbose;
int csv_output;
const struct valstr completion_code_vals[] = {{0, NULL}};
const struct valstr ipmi_privlvl_vals[] = {{0, NULL}};

static const char *answers[2];
static char prompt_buffer[128];
static int prompts;
static int requests;
static int last_ccode;
static const char *last_log;
static const char *expected_password;
static int return_null_response;
static uint8_t response_code;
static struct ipmi_rs response;

#define CHECK(expr) do { \
	if (!(expr)) { \
		fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #expr); \
		exit(1); \
	} \
} while (0)

static char *
fake_getpass(const char *prompt)
{
	const char *answer;
	CHECK(prompt != NULL);
	CHECK(prompts < 2);
	answer = answers[prompts++];
	if (!answer) {
		return NULL;
	}
	CHECK(strlen(answer) < sizeof(prompt_buffer));
	strcpy(prompt_buffer, answer);
	return prompt_buffer;
}

char *
getpass(const char *prompt)
{
	return fake_getpass(prompt);
}

#ifdef HAVE_GETPASSPHRASE
char *
getpassphrase(const char *prompt)
{
	return fake_getpass(prompt);
}
#endif

void
lprintf(int level, const char *format, ...)
{
	(void)level;
	last_log = format;
}

int
eval_ccode(const int ccode)
{
	last_ccode = ccode;
	return ccode ? -1 : 0;
}

const char *
val2str(uint32_t value, const struct valstr *values)
{
	(void)value;
	(void)values;
	return "completion code";
}

int
is_ipmi_user_id(const char *text, uint8_t *user_id)
{
	if (strcmp(text, "2")) {
		return -1;
	}
	*user_id = 2;
	return 0;
}

int
is_ipmi_channel_num(const char *text, uint8_t *channel)
{
	(void)text;
	(void)channel;
	return -1;
}

int
is_ipmi_user_priv_limit(const char *text, uint8_t *limit)
{
	(void)text;
	(void)limit;
	return -1;
}

int
str2int(const char *text, int32_t *value)
{
	(void)text;
	(void)value;
	return -1;
}

int
str2uchar(const char *text, uint8_t *value)
{
	if (strcmp(text, "16") && strcmp(text, "20")) {
		return -1;
	}
	*value = (uint8_t)atoi(text);
	return 0;
}

static struct ipmi_rs *
mock_sendrecv(struct ipmi_intf *intf, struct ipmi_rq *req)
{
	size_t len;
	size_t i;
	(void)intf;
	++requests;
	CHECK(req->msg.netfn == IPMI_NETFN_APP);
	if (req->msg.cmd == IPMI_SET_USER_PASSWORD) {
		CHECK(req->msg.data_len == 18 || req->msg.data_len == 22);
		CHECK((req->msg.data[0] & 0x3f) == 2);
		if (req->msg.data[1] == IPMI_PASSWORD_SET_PASSWORD) {
			CHECK(expected_password != NULL);
			len = strlen(expected_password);
			CHECK(len <= (size_t)req->msg.data_len - 2);
			CHECK(!memcmp(req->msg.data + 2, expected_password, len));
			for (i = len + 2; i < (size_t)req->msg.data_len; ++i) {
				CHECK(req->msg.data[i] == 0);
			}
			CHECK(req->msg.data_len == (len > 16 ? 22 : 18));
		} else {
			CHECK(req->msg.data[1] == IPMI_PASSWORD_DISABLE_USER
			    || req->msg.data[1] == IPMI_PASSWORD_ENABLE_USER);
		}
	} else {
		CHECK(req->msg.cmd == IPMI_SET_USER_NAME);
		CHECK(req->msg.data_len == 17);
		CHECK(req->msg.data[0] == 2);
		CHECK(expected_password != NULL);
		CHECK(!memcmp(req->msg.data + 1, expected_password, 16));
	}
	if (return_null_response) {
		return NULL;
	}
	response.ccode = response_code;
	return &response;
}

static void
reset(const char *first, const char *second, const char *expected)
{
	answers[0] = first;
	answers[1] = second;
	expected_password = expected;
	prompts = 0;
	requests = 0;
	last_ccode = INT_MIN;
	last_log = NULL;
	response_code = 0;
	return_null_response = 0;
}

static void
fill(char *buf, size_t len, char ch)
{
	memset(buf, ch, len);
	buf[len] = '\0';
}

int
main(void)
{
	struct ipmi_intf intf = {0};
	char first[32], second[32];
	char *set[] = {"set", "password", "2", NULL, "16"};
	char *disable[] = {"disable", "2"};
	char *enable[] = {"enable", "2"};
	char *name[] = {"set", "name", "2", first};
	intf.sendrecv = mock_sendrecv;

	fill(first, 8, 'x');
	reset(NULL, first, NULL);
	CHECK(ipmi_user_main(&intf, 3, set) == -1);
	CHECK(prompts == 1 && requests == 0);

	reset(first, NULL, NULL);
	CHECK(ipmi_user_main(&intf, 3, set) == -1);
	CHECK(prompts == 2 && requests == 0);

	fill(second, 8, 'y');
	reset(first, second, NULL);
	CHECK(ipmi_user_main(&intf, 3, set) == -1);
	CHECK(prompts == 2 && requests == 0);
	CHECK(last_log && strstr(last_log, "do not match"));

	fill(second, 7, 'x');
	reset(first, second, NULL);
	CHECK(ipmi_user_main(&intf, 3, set) == -1);
	CHECK(requests == 0);

	fill(first, 7, 'x');
	fill(second, 8, 'x');
	reset(first, second, NULL);
	CHECK(ipmi_user_main(&intf, 3, set) == -1);
	CHECK(requests == 0);

	fill(first, 21, 'x');
	reset(first, first, NULL);
	CHECK(ipmi_user_main(&intf, 3, set) == -1);
	CHECK(prompts == 1 && requests == 0);

	fill(first, 20, 'x');
	fill(second, 21, 'x');
	reset(first, second, NULL);
	CHECK(ipmi_user_main(&intf, 3, set) == -1);
	CHECK(prompts == 2 && requests == 0);

	fill(first, 8, 'x');
	fill(second, 8, 'x');
	reset(first, second, first);
	CHECK(ipmi_user_main(&intf, 3, set) == 0);
	CHECK(prompts == 2 && requests == 1 && last_ccode == 0);

	first[0] = '\0';
	second[0] = '\0';
	reset(first, second, first);
	CHECK(ipmi_user_main(&intf, 3, set) == 0);
	CHECK(prompts == 2 && requests == 1);

	fill(first, 20, 'x');
	fill(second, 20, 'x');
	reset(first, second, first);
	CHECK(ipmi_user_main(&intf, 3, set) == 0);
	CHECK(prompts == 2 && requests == 1);

	reset(first, second, first);
	set[3] = first;
	CHECK(ipmi_user_main(&intf, 4, set) == 0);
	CHECK(prompts == 0 && requests == 1);

	reset(NULL, NULL, NULL);
	return_null_response = 1;
	CHECK(ipmi_user_main(&intf, 2, disable) == -1);
	CHECK(requests == 1 && last_ccode == -1);

	reset(NULL, NULL, NULL);
	return_null_response = 1;
	CHECK(ipmi_user_main(&intf, 2, enable) == -1);
	CHECK(requests == 1 && last_ccode == -1);

	reset(NULL, NULL, NULL);
	response_code = 0x80;
	CHECK(ipmi_user_main(&intf, 2, enable) == -1);
	CHECK(requests == 1 && last_ccode == 0x80);

	fill(first, 16, 'x');
	reset(NULL, NULL, first);
	CHECK(ipmi_user_main(&intf, 4, name) == 0);
	CHECK(requests == 1);

	fill(first, 17, 'x');
	reset(NULL, NULL, NULL);
	CHECK(ipmi_user_main(&intf, 4, name) == -1);
	CHECK(requests == 0);
	return 0;
}
