#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <ipmitool/ipmi_intf.h>

uint8_t ipmitool_test_header_bitfield(uint8_t netfn, uint8_t lun)
{
	struct ipmi_rq request = {0};
	request.msg.netfn = netfn;
	request.msg.lun = lun;
	return *(const uint8_t *)&request;
}

size_t ipmitool_test_header_session_size(void)
{
	return sizeof(struct ipmi_session);
}

size_t ipmitool_test_header_session_align(void)
{
	return _Alignof(struct ipmi_session);
}

int ipmitool_test_header_socket(struct ipmi_session *session, int family)
{
	int fd = socket(family, SOCK_DGRAM, 0);
	int result = -1;

	if (fd < 0)
		return family == AF_INET6 && errno == EAFNOSUPPORT ? -2 : -1;
	if (family == AF_INET) {
		struct sockaddr_in address = {0};
		address.sin_family = AF_INET;
		address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0)
			goto out;
	} else {
		struct sockaddr_in6 address = {0};
		address.sin6_family = AF_INET6;
		address.sin6_addr = in6addr_loopback;
		if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0)
			goto out;
	}
	session->addrlen = sizeof(session->addr);
	if (getsockname(fd, (struct sockaddr *)&session->addr, &session->addrlen) != 0)
		goto out;
	if (session->addr.ss_family != family)
		goto out;
	result = 0;
out:
	close(fd);
	return result;
}

int ipmitool_test_header_ipv4_cast(struct ipmi_session *session)
{
	struct sockaddr_in *address = (struct sockaddr_in *)&session->addr;
	return inet_pton(AF_INET, "192.0.2.42", &address->sin_addr) == 1 ? 0 : -1;
}
