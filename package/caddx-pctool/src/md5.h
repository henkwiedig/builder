/* Minimal MD5 (RFC 1321), enough to check what the PC tool uploads. */
#ifndef PCTOOL_MD5_H
#define PCTOOL_MD5_H

#include <stddef.h>
#include <stdint.h>

struct md5_ctx {
	uint32_t a, b, c, d;
	uint64_t len;
	uint8_t buf[64];
};

void md5_init(struct md5_ctx *ctx);
void md5_update(struct md5_ctx *ctx, const void *data, size_t n);
void md5_final(struct md5_ctx *ctx, uint8_t out[16]);

#endif
