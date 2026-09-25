/* Translate production headers first, then select this fixture's SHA256 arm. */
#include "../src/zig/ipmi_c.h"
#undef HAVE_CRYPTO_SHA256
#if LANPLUS_DUMP_TEST_SHA256
#define HAVE_CRYPTO_SHA256 1
#endif
