/*
 * Transitional FRU shim: all commands not yet ported to Zig still execute
 * their original implementation. The original translation unit is included
 * unchanged, with only its entry point renamed to prevent a duplicate symbol.
 * Remove this shim when the remaining FRU commands have been ported.
 */
#define ipmi_fru_main ipmi_fru_main_legacy
#include "../../../lib/ipmi_fru.c"
#undef ipmi_fru_main

void
ipmi_fru_zig_picmg_print(uint8_t *data, int offset, int length)
{
	ipmi_fru_picmg_ext_print(data, offset, length);
}
