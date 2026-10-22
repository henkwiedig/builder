/*
 * openipc-bsel - A/B bank selector for the Caddx Ascent Lite+ (hi3516cv6xx)
 * and the BetaFPV P1 (Artosyn PROXIMA 9311). Two record formats, picked by
 * the partition the board has: "sel" (BSEL record, below) or "gpt0" (GPT
 * active bit, see "GPT backend" further down).
 *
 * The stock bootloader's "fpvboot" u-boot command picks which of two banks
 * (kernel0/rootfs0 vs kernel1/rootfs1, exposed to Linux as fpvbsel=0/1) to
 * boot by reading a small magic record out of the "sel" MTD partition. This
 * tool reimplements that same record format so an OpenIPC image running on
 * either bank can flip which bank boots next, without needing the stock
 * bootloader's own userspace tool (ar_bsel) or its rootfs.
 *
 * Record format (reverse-engineered from the stock ar_bsel binary via
 * Ghidra): 10 bytes, written to the first writesize bytes of every good
 * eraseblock in the "sel" partition (the rest of each eraseblock left
 * erased):
 *
 *   offset 0..3  "BSEL"
 *   offset 4     bank id, 0x00 or 0x01
 *   offset 5     bitwise NOT of the bank id (0xFF or 0xFE) - simple check
 *   offset 6..9  fixed magic trailer: EE 98 0C 53
 *
 * Usage matches the stock tool: openipc-bsel {check_flash|check_cmdline|set 0|set 1}
 *   check_flash    - read the bank recorded in the "sel" partition, print it
 *   check_cmdline  - read fpvbsel=N from /proc/cmdline, print it (P1: the
 *                    bank of the userapp partition ubi.mtd= names)
 *   set 0|1        - erase and rewrite every good eraseblock of "sel" with
 *                    the record for the given bank
 *   switch         - set the other bank
 * All print the result to stdout; check_flash/check_cmdline exit with
 * the bank number (0/1) as the process exit status, or 1 if it could not be
 * determined; set exits 0 on success, 1 on failure. -f <file> (first
 * argument) works on a gpt0 image instead of the partition, e.g. a dump.
 *
 * Built by the "openipc-bsel" Buildroot package (../openipc-bsel.mk) --
 * not device-specific in itself (it looks for an MTD partition named "sel"
 * or "gpt0" and speaks that partition's format); enabled by
 * hi3516cv6xx_artosyn_caddx-ascent-lite's and ar9311_artosyn_artlynk-p1's
 * defconfigs.
 */

#include <ctype.h>
#include <fcntl.h>
#include <mtd/mtd-abi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define SEL_RECORD_LEN 10

static const unsigned char sel_magic_trailer[4] = { 0xEE, 0x98, 0x0C, 0x53 };

static void build_sel_record(unsigned char bank, unsigned char *out)
{
	out[0] = 'B';
	out[1] = 'S';
	out[2] = 'E';
	out[3] = 'L';
	out[4] = bank;
	out[5] = (unsigned char)~bank;
	memcpy(out + 6, sel_magic_trailer, sizeof(sel_magic_trailer));
}

/* Returns the bank encoded in a valid record, or -1 if it doesn't match. */
static int decode_sel_record(const unsigned char *buf)
{
	unsigned char rec[SEL_RECORD_LEN];

	build_sel_record(0, rec);
	if (memcmp(buf, rec, SEL_RECORD_LEN) == 0)
		return 0;
	build_sel_record(1, rec);
	if (memcmp(buf, rec, SEL_RECORD_LEN) == 0)
		return 1;
	return -1;
}

/* Finds the mtd device number whose /proc/mtd name contains "sel". */
static int find_sel_mtd_num(void)
{
	FILE *fp;
	char line[256];
	int mtdnum = -1;

	fp = fopen("/proc/mtd", "r");
	if (!fp)
		return -1;

	while (fgets(line, sizeof(line), fp)) {
		char *nl;
		int num;

		if (!strstr(line, "sel"))
			continue;
		if (sscanf(line, "mtd%d:", &num) == 1) {
			mtdnum = num;
			(void)nl;
			break;
		}
	}
	fclose(fp);
	return mtdnum;
}

static int find_bsel_from_cmdline(void)
{
	FILE *fp;
	char buf[2048];
	size_t n;
	char *p;
	int bsel;

	fp = fopen("/proc/cmdline", "r");
	if (!fp)
		return -1;
	n = fread(buf, 1, sizeof(buf) - 1, fp);
	fclose(fp);
	if (n == 0)
		return -1;
	buf[n] = '\0';

	p = strstr(buf, "fpvbsel=");
	if (!p)
		return -1;
	p += strlen("fpvbsel=");
	if (sscanf(p, "%d", &bsel) != 1)
		return -1;
	return bsel;
}

/*
 * Reads the first good eraseblock's record from the "sel" partition.
 * Returns the decoded bank (0/1), or -1 on any failure (no "sel" partition,
 * no good eraseblocks, or none of them hold a recognised record).
 */
static int bsel_check(const char *mtddev)
{
	int fd, ret = -1;
	struct mtd_info_user info;
	unsigned char *buf = NULL;
	int eb, eb_count;

	fd = open(mtddev, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "openipc-bsel: cannot open %s\n", mtddev);
		return -1;
	}

	if (ioctl(fd, MEMGETINFO, &info) != 0) {
		fprintf(stderr, "openipc-bsel: MEMGETINFO failed on %s\n", mtddev);
		goto out;
	}

	buf = malloc(info.writesize);
	if (!buf) {
		fprintf(stderr, "openipc-bsel: out of memory\n");
		goto out;
	}

	eb_count = info.size / info.erasesize;
	for (eb = 0; eb < eb_count; eb++) {
		off_t seek = (off_t)eb * info.erasesize;

		if (ioctl(fd, MEMGETBADBLOCK, &seek) != 0)
			continue; /* bad block, skip it like the stock tool does */

		if (lseek(fd, seek, SEEK_SET) != seek)
			continue;
		if (read(fd, buf, info.writesize) != (ssize_t)info.writesize)
			continue;

		ret = decode_sel_record(buf);
		if (ret >= 0)
			break;

		fprintf(stderr, "openipc-bsel: eb=%d has no valid record\n", eb);
		ret = -1;
	}

out:
	free(buf);
	close(fd);
	return ret;
}

/*
 * Erases and rewrites every good eraseblock of the "sel" partition with the
 * record for bank_new. Matches the stock tool's redundancy: every good
 * eraseblock in the whole partition carries the same record, not just the
 * first one, so a handful of failing blocks over the device's life don't
 * lose the setting.
 */
static int bsel_update(const char *mtddev, int bank_new)
{
	int fd, ok_count = 0;
	struct mtd_info_user info;
	unsigned char *buf = NULL;
	unsigned char rec[SEL_RECORD_LEN];
	int eb, eb_count;

	build_sel_record((unsigned char)bank_new, rec);

	fd = open(mtddev, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "openipc-bsel: cannot open %s\n", mtddev);
		return -1;
	}

	if (ioctl(fd, MEMGETINFO, &info) != 0) {
		fprintf(stderr, "openipc-bsel: MEMGETINFO failed on %s\n", mtddev);
		close(fd);
		return -1;
	}

	buf = malloc(info.writesize);
	if (!buf) {
		fprintf(stderr, "openipc-bsel: out of memory\n");
		close(fd);
		return -1;
	}

	eb_count = info.size / info.erasesize;
	for (eb = 0; eb < eb_count; eb++) {
		struct erase_info_user ei;
		off_t seek = (off_t)eb * info.erasesize;

		if (ioctl(fd, MEMGETBADBLOCK, &seek) != 0) {
			fprintf(stderr, "openipc-bsel: eb=%d bad, skipping\n", eb);
			continue;
		}

		ei.start = (uint32_t)seek;
		ei.length = info.erasesize;
		if (ioctl(fd, MEMERASE, &ei) != 0) {
			fprintf(stderr, "openipc-bsel: eb=%d erase failed, marking bad\n", eb);
			ioctl(fd, MEMSETBADBLOCK, &seek);
			continue;
		}

		memset(buf, 0xFF, info.writesize);
		memcpy(buf, rec, SEL_RECORD_LEN);

		if (lseek(fd, seek, SEEK_SET) != seek ||
		    write(fd, buf, info.writesize) != (ssize_t)info.writesize) {
			fprintf(stderr, "openipc-bsel: eb=%d write failed, marking bad\n", eb);
			ioctl(fd, MEMSETBADBLOCK, &seek);
			continue;
		}

		ok_count++;
	}

	free(buf);
	close(fd);

	if (ok_count == 0) {
		fprintf(stderr, "openipc-bsel: failed to write any eraseblock\n");
		return -1;
	}
	printf("openipc-bsel: wrote bank %d to %d/%d eraseblocks\n", bank_new, ok_count, eb_count);
	return 0;
}

/*
 * GPT backend (BetaFPV P1 / Artosyn PROXIMA 9311). The NAND's partition
 * table is a GPT (512-byte sectors, header at sector 1, 128 entries of 128
 * bytes from sector 2) at the start of the "gpt0" partition; "gpt1" is left
 * erased. Five partitions come in pairs -- env, uboot, kernel, dtb, userapp,
 * suffixed 0 and 1 -- and the stock SPL boots the member of each pair whose
 * entry has attribute bit 47 set. The singletons (vendor, factory, usr_data,
 * usr_log) always have it set and are left alone. The SPL also points the
 * kernel at the active userapp by rewriting the command line's ubi.mtd=,
 * which is how check_cmdline tells the running bank.
 *
 * set rewrites gpt0's first eraseblock with the bits moved and both CRCs
 * recomputed, keeping everything else in that block as it was (the stock
 * tool leaves stale buffer bytes after the entry array; they go back
 * unchanged). Between the erase and the write -- a few milliseconds -- the
 * board has no partition table, and a power cut there leaves it to USB
 * recovery.
 */
#define GPT_SECTOR 512
#define GPT_ACTIVE (1ULL << 47)

static const char *const gpt_pairs[] = { "env", "uboot", "kernel", "dtb", "userapp" };
#define GPT_NPAIRS (sizeof(gpt_pairs) / sizeof(gpt_pairs[0]))

static uint32_t crc32_buf(const unsigned char *p, size_t n)
{
	uint32_t crc = 0xFFFFFFFF;
	int k;

	while (n--) {
		crc ^= *p++;
		for (k = 0; k < 8; k++)
			crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
	}
	return ~crc;
}

static uint32_t get_le32(const unsigned char *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint64_t get_le64(const unsigned char *p)
{
	return get_le32(p) | (uint64_t)get_le32(p + 4) << 32;
}

static void put_le32(unsigned char *p, uint32_t v)
{
	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
}

static void put_le64(unsigned char *p, uint64_t v)
{
	put_le32(p, (uint32_t)v);
	put_le32(p + 4, (uint32_t)(v >> 32));
}

struct gpt {
	unsigned char *buf;
	size_t hdr, arr;
	uint32_t hdr_size, n, esz;
};

static uint32_t gpt_hdr_crc(const struct gpt *g)
{
	unsigned char h[GPT_SECTOR];

	memcpy(h, g->buf + g->hdr, g->hdr_size);
	memset(h + 16, 0, 4);
	return crc32_buf(h, g->hdr_size);
}

/* Finds and checks the GPT in buf: 0, or -1 if it is missing or its CRCs fail. */
static int gpt_parse(unsigned char *buf, size_t len, struct gpt *g)
{
	g->buf = buf;
	g->hdr = GPT_SECTOR;
	if (len < 2 * GPT_SECTOR || memcmp(buf + g->hdr, "EFI PART", 8) != 0) {
		fprintf(stderr, "openipc-bsel: gpt0: no GPT header\n");
		return -1;
	}
	g->hdr_size = get_le32(buf + g->hdr + 12);
	g->arr = get_le64(buf + g->hdr + 72) * GPT_SECTOR;
	g->n = get_le32(buf + g->hdr + 80);
	g->esz = get_le32(buf + g->hdr + 84);
	if (g->hdr_size < 92 || g->hdr_size > GPT_SECTOR || g->esz < 128 || g->n == 0 ||
	    g->n > 1024 || g->arr < 2 * GPT_SECTOR || g->arr + (size_t)g->n * g->esz > len) {
		fprintf(stderr, "openipc-bsel: gpt0: implausible GPT header\n");
		return -1;
	}
	if (gpt_hdr_crc(g) != get_le32(buf + g->hdr + 16) ||
	    crc32_buf(buf + g->arr, (size_t)g->n * g->esz) != get_le32(buf + g->hdr + 88)) {
		fprintf(stderr, "openipc-bsel: gpt0: GPT CRC mismatch\n");
		return -1;
	}
	return 0;
}

/* The entry of the partition called name (UTF-16LE in the GPT), or NULL. */
static unsigned char *gpt_find(const struct gpt *g, const char *name)
{
	static const unsigned char unused[16];
	uint32_t i;
	size_t j;

	for (i = 0; i < g->n; i++) {
		unsigned char *e = g->buf + g->arr + (size_t)i * g->esz;

		if (memcmp(e, unused, sizeof(unused)) == 0)
			continue;
		for (j = 0; j < 36; j++) {
			unsigned c = e[56 + 2 * j] | e[57 + 2 * j] << 8;

			if (c != (unsigned char)name[j])
				break;
			if (c == 0)
				return e;
		}
	}
	return NULL;
}

/*
 * The bank (0/1) every pair has active, or -1: a pair missing, or the bits
 * not one per pair and the same bank throughout ("mixed", said on stderr).
 */
static int gpt_bank(const struct gpt *g)
{
	int bank = -1;
	size_t i;

	for (i = 0; i < GPT_NPAIRS; i++) {
		char n0[16], n1[16];
		unsigned char *e0, *e1;
		int a0, a1, b;

		snprintf(n0, sizeof(n0), "%s0", gpt_pairs[i]);
		snprintf(n1, sizeof(n1), "%s1", gpt_pairs[i]);
		e0 = gpt_find(g, n0);
		e1 = gpt_find(g, n1);
		if (!e0 || !e1) {
			fprintf(stderr, "openipc-bsel: gpt0: no %s/%s pair\n", n0, n1);
			return -1;
		}
		a0 = !!(get_le64(e0 + 48) & GPT_ACTIVE);
		a1 = !!(get_le64(e1 + 48) & GPT_ACTIVE);
		b = a0 && !a1 ? 0 : a1 && !a0 ? 1 : -1;
		if (b < 0 || (bank >= 0 && b != bank)) {
			fprintf(stderr, "openipc-bsel: gpt0: mixed banks (%s active=%d, %s active=%d)\n",
				n0, a0, n1, a1);
			return -1;
		}
		bank = b;
	}
	return bank;
}

/* Moves the active bit of every pair to bank; returns the entries changed, or -1. */
static int gpt_set(struct gpt *g, int bank)
{
	int changed = 0;
	size_t i;
	int m;

	for (i = 0; i < GPT_NPAIRS; i++) {
		for (m = 0; m < 2; m++) {
			char name[16];
			unsigned char *e;
			uint64_t attr, want;

			snprintf(name, sizeof(name), "%s%d", gpt_pairs[i], m);
			e = gpt_find(g, name);
			if (!e) {
				fprintf(stderr, "openipc-bsel: gpt0: no %s\n", name);
				return -1;
			}
			attr = get_le64(e + 48);
			want = m == bank ? attr | GPT_ACTIVE : attr & ~GPT_ACTIVE;
			if (want != attr) {
				put_le64(e + 48, want);
				changed++;
			}
		}
	}
	put_le32(g->buf + g->hdr + 88, crc32_buf(g->buf + g->arr, (size_t)g->n * g->esz));
	put_le32(g->buf + g->hdr + 16, gpt_hdr_crc(g));
	return changed;
}

/* Finds the mtd device number whose /proc/mtd name is exactly name. */
static int find_mtd_by_name(const char *name)
{
	FILE *fp;
	char line[256], quoted[64];
	int mtdnum = -1;

	snprintf(quoted, sizeof(quoted), "\"%s\"", name);
	fp = fopen("/proc/mtd", "r");
	if (!fp)
		return -1;
	while (fgets(line, sizeof(line), fp)) {
		int num;

		if (strstr(line, quoted) && sscanf(line, "mtd%d:", &num) == 1) {
			mtdnum = num;
			break;
		}
	}
	fclose(fp);
	return mtdnum;
}

/*
 * gpt0's first eraseblock (or a whole gpt0 image file), read into *buf.
 * Returns the length, or -1.
 */
static ssize_t gpt_load(const char *path, int is_file, unsigned char **buf, struct mtd_info_user *info)
{
	ssize_t len = -1;
	int fd;

	*buf = NULL;
	fd = open(path, O_RDONLY);
	if (fd < 0) {
		fprintf(stderr, "openipc-bsel: cannot open %s\n", path);
		return -1;
	}
	if (is_file) {
		off_t size = lseek(fd, 0, SEEK_END);

		if (size > 0 && size <= 16 << 20 && (*buf = malloc(size)) &&
		    pread(fd, *buf, size, 0) == size)
			len = size;
	} else {
		long long start = 0;

		if (ioctl(fd, MEMGETINFO, info) != 0) {
			fprintf(stderr, "openipc-bsel: MEMGETINFO failed on %s\n", path);
		} else if (ioctl(fd, MEMGETBADBLOCK, &start) != 0) {
			fprintf(stderr, "openipc-bsel: %s: first eraseblock is bad\n", path);
		} else if ((*buf = malloc(info->erasesize)) &&
			   pread(fd, *buf, info->erasesize, 0) == (ssize_t)info->erasesize) {
			len = info->erasesize;
		} else {
			fprintf(stderr, "openipc-bsel: cannot read %s\n", path);
		}
	}
	close(fd);
	if (len < 0) {
		if (is_file)
			fprintf(stderr, "openipc-bsel: cannot read %s\n", path);
		free(*buf);
		*buf = NULL;
	}
	return len;
}

/* Erases gpt0's first eraseblock, writes buf back page by page, reads it back. */
static int gpt_store_mtd(const char *path, const struct mtd_info_user *info, const unsigned char *buf)
{
	struct erase_info_user ei = { .start = 0, .length = info->erasesize };
	unsigned char *check;
	uint32_t off, i;
	int fd, ret = -1;

	check = malloc(info->erasesize);
	fd = open(path, O_RDWR);
	if (!check || fd < 0) {
		fprintf(stderr, "openipc-bsel: cannot open %s\n", path);
		goto out;
	}
	if (ioctl(fd, MEMERASE, &ei) != 0) {
		fprintf(stderr, "openipc-bsel: %s: erase failed\n", path);
		goto out;
	}
	for (off = 0; off < info->erasesize; off += info->writesize) {
		for (i = 0; i < info->writesize && buf[off + i] == 0xFF; i++)
			;
		if (i == info->writesize)
			continue; /* erased already; programming 0xFF would only spend a write */
		if (pwrite(fd, buf + off, info->writesize, off) != (ssize_t)info->writesize) {
			fprintf(stderr, "openipc-bsel: %s: write failed at 0x%x\n", path, off);
			goto out;
		}
	}
	if (pread(fd, check, info->erasesize, 0) != (ssize_t)info->erasesize ||
	    memcmp(check, buf, info->erasesize) != 0) {
		fprintf(stderr, "openipc-bsel: %s: readback differs\n", path);
		goto out;
	}
	ret = 0;
out:
	if (ret)
		fprintf(stderr, "openipc-bsel: the partition table may be damaged: restore gpt0 before rebooting\n");
	if (fd >= 0)
		close(fd);
	free(check);
	return ret;
}

static int gpt_store_file(const char *path, const unsigned char *buf, size_t len)
{
	int fd = open(path, O_WRONLY);

	if (fd < 0 || pwrite(fd, buf, len, 0) != (ssize_t)len) {
		fprintf(stderr, "openipc-bsel: cannot write %s\n", path);
		if (fd >= 0)
			close(fd);
		return -1;
	}
	return close(fd);
}

/* gpt0's partition device, or the image file given with -f. */
static const char *gpt_image;

static int gpt_path(char *path, size_t size)
{
	int mtdnum;

	if (gpt_image) {
		snprintf(path, size, "%s", gpt_image);
		return 0;
	}
	mtdnum = find_mtd_by_name("gpt0");
	if (mtdnum < 0)
		return -1;
	snprintf(path, size, "/dev/mtd%d", mtdnum);
	return 0;
}

/* The active bank in gpt0, or -1. */
static int gpt_check(void)
{
	struct mtd_info_user info;
	unsigned char *buf;
	struct gpt g;
	char path[256];
	ssize_t len;
	int bank = -1;

	if (gpt_path(path, sizeof(path)) < 0)
		return -1;
	len = gpt_load(path, gpt_image != NULL, &buf, &info);
	if (len < 0)
		return -1;
	if (gpt_parse(buf, len, &g) == 0)
		bank = gpt_bank(&g);
	free(buf);
	return bank;
}

static int gpt_update(int bank)
{
	struct mtd_info_user info;
	unsigned char *buf;
	struct gpt g;
	char path[256];
	ssize_t len;
	int changed, ret = -1;

	if (gpt_path(path, sizeof(path)) < 0)
		return -1;
	len = gpt_load(path, gpt_image != NULL, &buf, &info);
	if (len < 0)
		return -1;
	if (gpt_parse(buf, len, &g) < 0)
		goto out;
	changed = gpt_set(&g, bank);
	if (changed < 0)
		goto out;
	if (changed == 0) {
		printf("openipc-bsel: gpt0: bank %d already active\n", bank);
		ret = 0;
		goto out;
	}
	ret = gpt_image ? gpt_store_file(path, buf, len) : gpt_store_mtd(path, &info, buf);
	if (ret == 0)
		printf("openipc-bsel: gpt0: bank %d active (%d entries changed)\n", bank, changed);
out:
	free(buf);
	return ret;
}

/*
 * The bank the running kernel's root came from, by the userapp partition the
 * SPL named in ubi.mtd= (a number, or a name). -1 if there is none, e.g. on a
 * RAM boot.
 */
static int find_bank_from_ubi_mtd(void)
{
	FILE *fp;
	char buf[2048], arg[64], line[256], name[64];
	size_t n;
	char *p;
	int num = -1, len;

	fp = fopen("/proc/cmdline", "r");
	if (!fp)
		return -1;
	n = fread(buf, 1, sizeof(buf) - 1, fp);
	fclose(fp);
	buf[n] = '\0';
	p = strstr(buf, "ubi.mtd=");
	if (!p || sscanf(p + strlen("ubi.mtd="), "%63[^, \n]", arg) != 1)
		return -1;
	if (isdigit((unsigned char)arg[0])) {
		num = atoi(arg);
		arg[0] = '\0';
		fp = fopen("/proc/mtd", "r");
		if (!fp)
			return -1;
		while (fgets(line, sizeof(line), fp)) {
			int m;

			if (sscanf(line, "mtd%d: %*x %*x \"%63[^\"]\"", &m, name) == 2 && m == num) {
				snprintf(arg, sizeof(arg), "%s", name);
				break;
			}
		}
		fclose(fp);
	}
	len = strlen(arg);
	if (strncmp(arg, "userapp", 7) != 0 || len != 8 || (arg[7] != '0' && arg[7] != '1'))
		return -1;
	return arg[7] - '0';
}

static void usage(void)
{
	fprintf(stderr, "usage: openipc-bsel [-f gpt0-image] {check_flash | check_cmdline | set 0 | set 1 | switch}\n");
}

static int parse_bank_arg(const char *arg)
{
	if (strcmp(arg, "0") == 0)
		return 0;
	if (strcmp(arg, "1") == 0)
		return 1;
	return -1;
}

/* The board keeps its bank in gpt0 (or -f named a gpt0 image), not in "sel". */
static int uses_gpt(void)
{
	return gpt_image || (find_sel_mtd_num() < 0 && find_mtd_by_name("gpt0") >= 0);
}

/* The running bank: fpvbsel= (Ascent), or the userapp ubi.mtd= names (P1). */
static int find_running_bank(void)
{
	int bank = find_bsel_from_cmdline();

	return bank >= 0 ? bank : find_bank_from_ubi_mtd();
}

static int read_current_bank(void)
{
	char mtddev[64];
	int mtdnum;
	int bank;

	if (uses_gpt()) {
		bank = gpt_check();
		if (bank >= 0)
			return bank;
		return find_running_bank();
	}

	mtdnum = find_sel_mtd_num();
	if (mtdnum >= 0) {
		snprintf(mtddev, sizeof(mtddev), "/dev/mtd%d", mtdnum);
		bank = bsel_check(mtddev);
		if (bank >= 0)
			return bank;
	}

	return find_bsel_from_cmdline();
}

static int do_set_bank(const char *bank_arg)
{
	char mtddev[64];
	int bank;
	int mtdnum;

	bank = parse_bank_arg(bank_arg);
	if (bank < 0) {
		usage();
		return 1;
	}

	if (uses_gpt())
		return gpt_update(bank) == 0 ? 0 : 1;

	mtdnum = find_sel_mtd_num();
	if (mtdnum < 0) {
		fprintf(stderr, "openipc-bsel: no \"sel\" or \"gpt0\" partition in /proc/mtd\n");
		return 1;
	}
	snprintf(mtddev, sizeof(mtddev), "/dev/mtd%d", mtdnum);
	return bsel_update(mtddev, bank) == 0 ? 0 : 1;
}

static int do_switch_bank(void)
{
	int bank = read_current_bank();
	int target;
	char arg[2];

	if (bank < 0) {
		fprintf(stderr, "openipc-bsel: cannot determine current bank to toggle\n");
		return 1;
	}

	target = bank == 0 ? 1 : 0;
	snprintf(arg, sizeof(arg), "%d", target);
	return do_set_bank(arg);
}

int main(int argc, char **argv)
{
	char mtddev[64];
	int mtdnum;

	if (argc >= 3 && strcmp(argv[1], "-f") == 0) {
		gpt_image = argv[2];
		argv += 2;
		argc -= 2;
	}

	if (argc < 2) {
		usage();
		return 1;
	}

	if (strcmp(argv[1], "check_flash") == 0) {
		int bank;

		if (uses_gpt()) {
			bank = gpt_check();
		} else {
			mtdnum = find_sel_mtd_num();
			if (mtdnum < 0) {
				fprintf(stderr, "openipc-bsel: no \"sel\" or \"gpt0\" partition in /proc/mtd\n");
				return 1;
			}
			snprintf(mtddev, sizeof(mtddev), "/dev/mtd%d", mtdnum);
			bank = bsel_check(mtddev);
		}
		if (bank < 0) {
			printf("check_flash: no valid record found\n");
			return 1;
		}
		printf("check_flash: bank=%d\n", bank);
		return bank;
	} else if (strcmp(argv[1], "check_cmdline") == 0) {
		int bank = find_running_bank();

		if (bank < 0) {
			printf("check_cmdline: no bank on the command line\n");
			return 1;
		}
		printf("check_cmdline: bank=%d\n", bank);
		return bank;
	} else if (strcmp(argv[1], "set") == 0) {
		if (argc < 3) {
			usage();
			return 1;
		}
		return do_set_bank(argv[2]);
	} else if (strcmp(argv[1], "switch") == 0) {
		if (argc != 2) {
			usage();
			return 1;
		}
		return do_switch_bank();
	}

	usage();
	return 1;
}
