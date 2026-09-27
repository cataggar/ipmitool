/* Unit-only stand-in for lib/helper.c's buf2str_extended-backed mac2str.
 * The CLI differential test links the real C helper in both binaries.
 */
#include <stdint.h>
#include <stdio.h>

const char *mac2str(const uint8_t *mac)
{
	static char text[18];
	snprintf(text, sizeof(text), "%02x:%02x:%02x:%02x:%02x:%02x",
		 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
	return text;
}
