/*
 * openipc-bsel - A/B bank selector for the Caddx Ascent Lite+ (hi3516cv6xx).
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
 *   check_cmdline  - read fpvbsel=N from /proc/cmdline, print it
 *   set 0|1        - erase and rewrite every good eraseblock of "sel" with
 *                    the record for the given bank
 * All three print the result to stdout; check_flash/check_cmdline exit with
 * the bank number (0/1) as the process exit status, or 1 if it could not be
 * determined; set exits 0 on success, 1 on failure.
 *
 * Built by the "openipc-bsel" Buildroot package (../openipc-bsel.mk) --
 * not device-specific in itself (it just looks for an MTD partition named
 * "sel" and speaks the BSEL record format), but currently only enabled by
 * hi3516cv6xx_fpv_caddx-ascent-lite's defconfig.
 */

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

static void usage(void)
{
	fprintf(stderr, "usage: openipc-bsel {check_flash | check_cmdline | set 0 | set 1}\n");
}

int main(int argc, char **argv)
{
	char mtddev[64];
	int mtdnum;

	if (argc < 2) {
		usage();
		return 1;
	}

	if (strcmp(argv[1], "check_flash") == 0) {
		int bank;

		mtdnum = find_sel_mtd_num();
		if (mtdnum < 0) {
			fprintf(stderr, "openipc-bsel: no \"sel\" partition in /proc/mtd\n");
			return 1;
		}
		snprintf(mtddev, sizeof(mtddev), "/dev/mtd%d", mtdnum);
		bank = bsel_check(mtddev);
		if (bank < 0) {
			printf("check_flash: no valid record found\n");
			return 1;
		}
		printf("check_flash: bank=%d\n", bank);
		return bank;
	} else if (strcmp(argv[1], "check_cmdline") == 0) {
		int bank = find_bsel_from_cmdline();

		if (bank < 0) {
			printf("check_cmdline: fpvbsel not found\n");
			return 1;
		}
		printf("check_cmdline: bank=%d\n", bank);
		return bank;
	} else if (strcmp(argv[1], "set") == 0) {
		int bank;

		if (argc < 3) {
			usage();
			return 1;
		}
		if (strcmp(argv[2], "0") == 0)
			bank = 0;
		else if (strcmp(argv[2], "1") == 0)
			bank = 1;
		else {
			usage();
			return 1;
		}

		mtdnum = find_sel_mtd_num();
		if (mtdnum < 0) {
			fprintf(stderr, "openipc-bsel: no \"sel\" partition in /proc/mtd\n");
			return 1;
		}
		snprintf(mtddev, sizeof(mtddev), "/dev/mtd%d", mtdnum);
		return bsel_update(mtddev, bank) == 0 ? 0 : 1;
	}

	usage();
	return 1;
}
