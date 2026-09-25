#include <stddef.h>
#include <sys/select.h>

size_t ipmitool_test_fd_size(void)
{
	return sizeof(fd_set);
}

size_t ipmitool_test_fd_align(void)
{
	return _Alignof(fd_set);
}

void ipmitool_test_fd_zero(fd_set *fds)
{
	FD_ZERO(fds);
}

void ipmitool_test_fd_set(int fd, fd_set *fds)
{
	FD_SET(fd, fds);
}

int ipmitool_test_fd_isset(int fd, const fd_set *fds)
{
	return FD_ISSET(fd, fds);
}
