/* Minimal MD5 (RFC 1321). */
#include <string.h>

#include "md5.h"

#define F(x, y, z) ((z) ^ ((x) & ((y) ^ (z))))
#define G(x, y, z) ((y) ^ ((z) & ((x) ^ (y))))
#define H(x, y, z) ((x) ^ (y) ^ (z))
#define I(x, y, z) ((y) ^ ((x) | ~(z)))

static const uint32_t K[64] = {
	0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
	0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
	0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
	0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
	0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
	0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
	0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
	0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
};

static const uint8_t S[64] = {
	7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
	5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
	4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
	6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
};

static void block(struct md5_ctx *ctx, const uint8_t *p)
{
	uint32_t x[16], a = ctx->a, b = ctx->b, c = ctx->c, d = ctx->d, t;
	int i;

	for (i = 0; i < 16; i++)
		x[i] = p[4 * i] | p[4 * i + 1] << 8 | p[4 * i + 2] << 16 | (uint32_t)p[4 * i + 3] << 24;
	for (i = 0; i < 64; i++) {
		uint32_t f;
		int g;

		if (i < 16) {
			f = F(b, c, d);
			g = i;
		} else if (i < 32) {
			f = G(b, c, d);
			g = (5 * i + 1) & 15;
		} else if (i < 48) {
			f = H(b, c, d);
			g = (3 * i + 5) & 15;
		} else {
			f = I(b, c, d);
			g = (7 * i) & 15;
		}
		t = d;
		d = c;
		c = b;
		f += a + K[i] + x[g];
		b += (f << S[i]) | (f >> (32 - S[i]));
		a = t;
	}
	ctx->a += a;
	ctx->b += b;
	ctx->c += c;
	ctx->d += d;
}

void md5_init(struct md5_ctx *ctx)
{
	ctx->a = 0x67452301;
	ctx->b = 0xefcdab89;
	ctx->c = 0x98badcfe;
	ctx->d = 0x10325476;
	ctx->len = 0;
}

void md5_update(struct md5_ctx *ctx, const void *data, size_t n)
{
	const uint8_t *p = data;
	size_t used = ctx->len & 63;

	ctx->len += n;
	if (used) {
		size_t take = 64 - used < n ? 64 - used : n;

		memcpy(ctx->buf + used, p, take);
		p += take;
		n -= take;
		if (used + take < 64)
			return;
		block(ctx, ctx->buf);
	}
	for (; n >= 64; p += 64, n -= 64)
		block(ctx, p);
	memcpy(ctx->buf, p, n);
}

void md5_final(struct md5_ctx *ctx, uint8_t out[16])
{
	static const uint8_t pad[64] = { 0x80 };
	uint64_t bits = ctx->len * 8;
	uint8_t len[8];
	uint32_t w[4];
	int i;

	for (i = 0; i < 8; i++)
		len[i] = bits >> (8 * i);
	md5_update(ctx, pad, 1 + ((119 - (ctx->len & 63)) & 63));
	md5_update(ctx, len, 8);
	w[0] = ctx->a;
	w[1] = ctx->b;
	w[2] = ctx->c;
	w[3] = ctx->d;
	for (i = 0; i < 16; i++)
		out[i] = w[i / 4] >> (8 * (i % 4));
}
