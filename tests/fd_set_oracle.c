#include <stddef.h>
#include <sys/select.h>

_Static_assert(FD_SETSIZE == 1024, "unsupported fd_set capacity");
_Static_assert(sizeof(fd_set) == 1024 / 8, "unsupported fd_set size");
_Static_assert(_Alignof(fd_set) == _Alignof(unsigned long),
	       "unsupported fd_set alignment");

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
