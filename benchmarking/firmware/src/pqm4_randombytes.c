#include <stddef.h>
#include <stdint.h>

#include <zephyr/random/random.h>

int PQCLEAN_randombytes(uint8_t *output, size_t n)
{
	return sys_csrand_get(output, n);
}
