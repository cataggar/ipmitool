#include <limits.h>
#include <stddef.h>
#include <stdio.h>

int fwum_progress_oracle(char *, size_t, const char *, unsigned long,
                         unsigned long, unsigned long *);

static int
step(const char *name, unsigned long current, unsigned long total,
     unsigned long *previous)
{
    char line[256];
    int length = fwum_progress_oracle(line, sizeof(line), name, current,
                                      total, previous);
    return length < 0 || fwrite(line, 1, (size_t)length, stdout) != (size_t)length ||
           fflush(stdout) != 0;
}

int
main(void)
{
    unsigned long previous = ULONG_MAX;
    if (fputs("before|", stdout) == EOF ||
        step("Read", 0, 100, &previous) ||
        step("Duplicate", 0, 100, &previous) ||
        step("Zero total", 0, 0, &previous) ||
        step("Partial", 1, 3, &previous) ||
        step("Hi\0ignored", 1, 2, &previous) ||
        step("Done", ULONG_MAX, ULONG_MAX, &previous) ||
        fputs("after\n", stdout) == EOF)
        return 1;
    return fflush(stdout) != 0;
}
