#include <stdlib.h>

void *sel_test_malloc(size_t size);
void *sel_test_calloc(size_t count, size_t size);

#define malloc sel_test_malloc
#define calloc sel_test_calloc
