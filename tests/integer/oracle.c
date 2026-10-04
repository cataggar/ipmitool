/* Independent libc observations and the unmodified original lib/helper.c. */
#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <locale.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <ipmitool/helper.h>

int verbose;
const struct valstr completion_code_vals[] = { { 0, NULL } };

static const char *const cases[] = {
    "", " ", "\t\n\r\v\f", "+", "-", "  +", "  -  ", "x", "+x", " \xff" "1",
    "0", "-0", "+00", "0x", "-0X", "0Xg", "0x1", "-0xff", " +0xFf",
    "0b101", "-0b2", "08", "0129", "  -077", "42 ", "42x", "0x1p",
    "-1", "-2", "2147483647", "2147483648", "-2147483648", "-2147483649",
    "4294967295", "4294967296", "-4294967295", "-4294967296",
    "9223372036854775807", "9223372036854775808", "-9223372036854775808",
    "-9223372036854775809", "18446744073709551615", "18446744073709551616",
    "-18446744073709551615", "-18446744073709551616",
    "99999999999999999999999999999999999999999999",
    "-99999999999999999999999999999999999999999999x",
    "0xffffffffffffffffffffffffffffffffz", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz!",
    "101010", "1 2", "\xa0" "12"
};

size_t integer_case_count(void) { return sizeof(cases) / sizeof(cases[0]); }
const char *integer_case_at(size_t i) { return cases[i]; }
int integer_long_bits(void) { return (int)(sizeof(long) * CHAR_BIT); }
int integer_space(unsigned char byte) { return !!isspace(byte); }
int integer_set_locale(const char *name) { return setlocale(LC_CTYPE, name) != NULL; }
const char *integer_locale(void) { return setlocale(LC_CTYPE, NULL); }

void integer_signed(const char *text, int base, int seed,
                    int64_t *value, size_t *end, int *error)
{
    char *tail = NULL;
    errno = seed;
    *value = strtol(text, &tail, base);
    *error = errno;
    *end = tail ? (size_t)(tail - text) : SIZE_MAX;
}

void integer_unsigned(const char *text, int base, int seed,
                      uint64_t *value, size_t *end, int *error)
{
    char *tail = NULL;
    errno = seed;
    *value = strtoul(text, &tail, base);
    *error = errno;
    *end = tail ? (size_t)(tail - text) : SIZE_MAX;
}

void integer_helper(const char *text, int which, int seed,
                    uint64_t *bits, int *status, int *error)
{
    errno = seed;
    switch (which) {
    case 0: { int64_t v = 42; *status = str2long(text, &v); *bits = (uint64_t)v; break; }
    case 1: { uint64_t v = 42; *status = str2ulong(text, &v); *bits = v; break; }
    case 2: { int32_t v = 42; *status = str2int(text, &v); *bits = (uint64_t)(int64_t)v; break; }
    case 3: { uint32_t v = 42; *status = str2uint(text, &v); *bits = v; break; }
    case 4: { int16_t v = 42; *status = str2short(text, &v); *bits = (uint64_t)(int64_t)v; break; }
    case 5: { uint16_t v = 42; *status = str2ushort(text, &v); *bits = v; break; }
    case 6: { int8_t v = 42; *status = str2char(text, &v); *bits = (uint64_t)(int64_t)v; break; }
    case 7: { uint8_t v = 42; *status = str2uchar(text, &v); *bits = v; break; }
    default: abort();
    }
    *error = errno;
}

#ifdef INTEGER_ORACLE_MAIN
static void hex(const char *s)
{
    while (*s) printf("%02x", (unsigned char)*s++);
}

int main(void)
{
    static const int bases[] = {0, 2, 8, 10, 16, 36};
    size_t i, b;
    int which;
    if (!integer_set_locale("C")) return 1;
#ifdef __GLIBC__
    printf("P|gnu|%d\n", integer_long_bits());
#else
    printf("P|zig_0_16|%d\n", integer_long_bits());
#endif
    for (i = 0; i < integer_case_count(); ++i) {
        for (b = 0; b < sizeof(bases) / sizeof(bases[0]); ++b) {
            int64_t s;
            uint64_t u;
            size_t end;
            int error;
            integer_signed(cases[i], bases[b], 0, &s, &end, &error);
            printf("S|%d|", bases[b]); hex(cases[i]);
            printf("|%016" PRIx64 "|%zu|%d\n", (uint64_t)s, end, error);
            integer_unsigned(cases[i], bases[b], 0, &u, &end, &error);
            printf("U|%d|", bases[b]); hex(cases[i]);
            printf("|%016" PRIx64 "|%zu|%d\n", u, end, error);
        }
        for (which = 0; which < 8; ++which) {
            uint64_t bits;
            int status, error;
            integer_helper(cases[i], which, 0, &bits, &status, &error);
            printf("H|%d|", which); hex(cases[i]);
            printf("|%016" PRIx64 "|%d|%d\n", bits, status, error);
        }
    }
    return ferror(stdout) ? 1 : 0;
}
#endif
