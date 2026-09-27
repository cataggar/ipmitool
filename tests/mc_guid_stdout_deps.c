#include <ipmitool/helper.h>

/* The ABI test root already has a mac2str oracle, so it cannot link helper.c.
 * Production uses helper.c; the GUID goldens exercise the real helper. */
uint8_t *
array_byteswap(uint8_t *buffer, size_t length)
{
	for (size_t i = 0; i < length / 2; i++) {
		uint8_t tmp = buffer[i];
		buffer[i] = buffer[length - i - 1];
		buffer[length - i - 1] = tmp;
	}
	return buffer;
}
