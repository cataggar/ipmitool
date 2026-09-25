/* Same C caller against the original helper and the selected Zig helper.
 * The surrounding printf calls deliberately leave bytes in libc's stdout
 * buffer when either value-table printer begins.
 */
#include <stdint.h>
#include <stdio.h>
#include <ipmitool/helper.h>

int verbose;
const struct valstr completion_code_vals[] = { { 0, NULL } };

int main(void)
{
	const struct valstr values[] = {
		{ 255, "A" },
		{ 256, "B" },
		{ UINT32_MAX, "C" },
		{ 0, NULL }
	};

	printf("C before one");
	print_valstr(values, "Codes", -1);
	printf("C after one\n");

	printf("C before two");
	print_valstr_2col(values, "Codes", -1);
	printf("C after two\n");

	return 0;
}
