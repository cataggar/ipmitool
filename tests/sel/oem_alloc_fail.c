/* To run from the repository root:
 * zig cc -ffunction-sections -fdata-sections -Iinclude \
 *   -include tests/sel/oem_alloc_hooks.h -c lib/ipmi_sel.c -o .scratch/sel.o
 * zig cc -Iinclude tests/sel/oem_alloc_fail.c .scratch/sel.o \
 *   -Wl,--gc-sections -o .scratch/oem-alloc-test
 * .scratch/oem-alloc-test tests/fixtures/sel/oemmsg_ok.txt \
 *   tests/fixtures/sel/oemmsg_bad.txt tests/fixtures/sel/oemmsg_empty.txt
 */
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#include <ipmitool/ipmi_sel.h>

struct ipmi_sel_oem_msg_rec;
extern struct ipmi_sel_oem_msg_rec *sel_oem_msg;

static size_t allocations;
static size_t fail_at;

void *sel_test_malloc(size_t size)
{
	allocations++;
	return allocations == fail_at ? NULL : malloc(size);
}

void *sel_test_calloc(size_t count, size_t size)
{
	allocations++;
	return allocations == fail_at ? NULL : calloc(count, size);
}

FILE *ipmi_open_file(const char *file, int rw)
{
	assert(rw == 0);
	return fopen(file, "r");
}

void lprintf(int level, const char *format, ...)
{
	(void)level;
	(void)format;
}

int main(int argc, char **argv)
{
	size_t i, total;

	assert(argc == 4);
	assert(ipmi_sel_oem_init(argv[1]) == 0);
	assert(sel_oem_msg != NULL);
	total = allocations;
	assert(total > 2);

	assert(ipmi_sel_oem_init(argv[2]) == -1);
	assert(sel_oem_msg == NULL);

	for (i = 1; i <= total; i++) {
		allocations = 0;
		fail_at = i;
		assert(ipmi_sel_oem_init(argv[1]) == -1);
		assert(sel_oem_msg == NULL);
	}

	fail_at = 0;
	assert(ipmi_sel_oem_init(argv[1]) == 0);
	assert(ipmi_sel_oem_init(argv[1]) == 0);
	assert(ipmi_sel_oem_init(argv[3]) == 0);
	return 0;
}
