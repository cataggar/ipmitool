#include <stdlib.h>
#include <time.h>

/* Used only by golden cases with a fixed_time: setting. */
time_t time(time_t *result)
{
	const char *value = getenv("IPMI_GOLDEN_TIME");
	time_t instant = (time_t)strtoll(value, NULL, 10);
	if (result)
		*result = instant;
	return instant;
}
