/* Retain the original C oracle; vary only the test's SHA256 feature flag. */
#include <ipmitool/ipmi.h>
#undef HAVE_CRYPTO_SHA256
#if LANPLUS_DUMP_TEST_SHA256
#define HAVE_CRYPTO_SHA256 1
#endif
#include "../src/plugins/lanplus/lanplus_dump.c"
