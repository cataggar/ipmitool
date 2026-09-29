#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* The defined-range formatting of lib/ipmi_fwum.c:KfwumShowProgress.
 * Keep this fixture in C so float promotions and printf widths are measured
 * against libc, not inferred from Zig's formatting rules. */
int
fwum_progress_oracle(char *out, size_t capacity, const char *task,
                     unsigned long current, unsigned long total,
                     unsigned long *previous)
{
    unsigned char spaces[43];
    unsigned short hash;
    float percent;
    unsigned long progress;
    int n, part;

    if (!total)
        return 0; /* The production Zig port guards C's undefined 0/0. */
    percent = (float)current / total;
    if (percent < 0 || percent > 1)
        return -1; /* C overruns spaces if hash > 42. */
    progress = 100 * percent;
    if (*previous == progress)
        return 0;
    *previous = progress;
    n = snprintf(out, capacity, "%-25s : ", task);
    if (n < 0 || (size_t)n >= capacity)
        return -1;
    hash = percent * 42;
    memset(spaces, '#', hash);
    spaces[hash] = '\0';
    part = snprintf(out + n, capacity - n, "%s", spaces);
    if (part < 0 || (size_t)part >= capacity - n)
        return -1;
    n += part;
    memset(spaces, ' ', 42 - hash);
    spaces[42 - hash] = '\0';
    part = snprintf(out + n, capacity - n, "%s %3ld %%\r%s",
                    spaces, (long)progress, progress == 100 ? "\n" : "");
    if (part < 0 || (size_t)part >= capacity - n)
        return -1;
    return n + part;
}
