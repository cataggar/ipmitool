/*
 * Transitional FRU shim: all commands not yet ported to Zig still execute
 * their original implementation. The original translation unit is included
 * unchanged, with only its entry point renamed to prevent a duplicate symbol.
 * Remove this shim when the remaining FRU commands have been ported.
 */
#define ipmi_fru_main ipmi_fru_main_legacy
#include "../../../lib/ipmi_fru.c"
#undef ipmi_fru_main

int
ipmi_fru_zig_write(struct ipmi_intf *intf, uint16_t size, uint8_t access,
		   uint8_t id, uint16_t length, uint8_t *data)
{
	struct fru_info fru = {0};
	fru.size = size;
	fru.access = access;
	return write_fru_area(intf, &fru, id, 0, 0, length, data);
}
