/*
 * pctoold -- answers CADDX's Windows "PC tool" (CADDX_PCTool) on the USB
 * serial gadget, so it can flash an air unit that runs OpenIPC the same way
 * it flashes one running the stock firmware.
 *
 * The stock firmware does this with /usrdata/fpv/ar_fpvhs_upgrade on a CDC-ACM
 * gadget (1D76:0101). Protocol decoded from a USBPcap capture of the PC tool
 * flashing a stock unit (see ../README.md for the frame table):
 *
 *   36-byte header, 9 x u32 little endian:
 *     magic 0x4152544f ("OTRA"), dir (host 0x00010cdc / device 0x00020cdc),
 *     tag (host 0xabcd0000 / device 0), cmd, fmt (2), payload length, seq,
 *     0, crc
 *   crc = zlib CRC-32 over the header with the crc field zeroed, then the
 *   payload. A reply echoes cmd and seq. Replies end in a 64-byte status
 *   string ("OK").
 *
 *   0x3c device info    0x03 reboot ("clean")   0x72 connect
 *   0x73 upgrade start  0x74 data (<= 1 MiB)    0x75 data complete
 *   0x76 status poll    0x3a switch the USB port to RNDIS
 *
 * The received image (an ASW container) goes to a file, is checked against
 * the md5 the PC tool sent, and is handed to sysupgrade, which flashes the
 * inactive bank and only then switches openipc-bsel. Board policy (what to
 * stop for "clean", how to reboot) lives in the hook script, and the board's
 * identity comes in as options (pctool-mode, /etc/default/pctoold).
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <syslog.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "md5.h"

#define MAGIC		0x4152544fu
#define DIR_DEV		0x00020cdcu
#define FMT		2
#define HDR_LEN		36
#define MAX_CHUNK	0x100000u	/* advertised in the 0x3c reply */
#define STATUS_LEN	64

#define CMD_REBOOT	0x03
#define CMD_RNDIS	0x3a
#define CMD_INFO	0x3c
#define CMD_CONNECT	0x72
#define CMD_START	0x73
#define CMD_DATA	0x74
#define CMD_DONE	0x75
#define CMD_STATUS	0x76

/*
 * 0x76 states. 2 (running) and 3 (done) are what a stock unit reports. The
 * failure value is a guess: the stock binary names STARTING..DONE, FAILED,
 * but which number the PC tool treats as failure is unconfirmed. Worst case
 * it keeps polling until its own limit (~200 polls) and reports a timeout.
 */
#define ST_IDLE		0
#define ST_RUNNING	2
#define ST_DONE		3
#define ST_FAILED	4

/* Mid-frame silence after which a partial frame is dropped. */
#define FRAME_TIMEOUT_MS	3000
/* Reboot on our own if the PC tool never polls the final status. */
#define DONE_REBOOT_S		30

static struct {
	const char *tty;
	const char *image;
	const char *upgrade;
	const char *hook;
	const char *progress;
	const char *name;
	const char *fw;
	const char *hw;
	const char *sn;
	int foreground;
} cfg = {
	.tty = "/dev/ttyGS0",
	.image = "/tmp/pctool.asw",
	.upgrade = "/usr/sbin/sysupgrade",
	.hook = "/usr/sbin/pctool-hook",
	.progress = "/tmp/pctool.progress",
	.name = "OpenIPC",
	.fw = "OpenIPC",
	.hw = "OpenIPC",
	.sn = "OpenIPC",
};

/* One upload + flash. */
static struct {
	int fd;			/* image file while receiving, else -1 */
	uint32_t total;
	uint32_t received;
	char md5[33];
	struct md5_ctx md5ctx;
	pid_t child;		/* sysupgrade, 0 when not running */
	int state;
	int percent;
	char stage[32];
	int stage_polls;
	time_t reboot_at;	/* 0 = no reboot scheduled */
} up = { .fd = -1 };

static uint8_t *payload;	/* MAX_CHUNK + slack */

static void logmsg(int prio, const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	if (cfg.foreground) {
		vfprintf(stderr, fmt, ap);
		fputc('\n', stderr);
	} else {
		vsyslog(prio, fmt, ap);
	}
	va_end(ap);
}

static uint32_t crc32_update(uint32_t crc, const uint8_t *p, size_t n)
{
	static uint32_t table[256];
	size_t i;

	if (!table[1]) {
		for (uint32_t c, k = 0; k < 256; k++) {
			c = k;
			for (int j = 0; j < 8; j++)
				c = c & 1 ? 0xedb88320u ^ (c >> 1) : c >> 1;
			table[k] = c;
		}
	}
	crc = ~crc;
	for (i = 0; i < n; i++)
		crc = table[(crc ^ p[i]) & 0xff] ^ (crc >> 8);
	return ~crc;
}

static uint32_t get32(const uint8_t *p)
{
	return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static void put32(uint8_t *p, uint32_t v)
{
	p[0] = v;
	p[1] = v >> 8;
	p[2] = v >> 16;
	p[3] = v >> 24;
}

static void put_str(uint8_t *p, size_t field, const char *s)
{
	size_t n = strlen(s);

	memset(p, 0, field);
	memcpy(p, s, n < field ? n : field - 1);
}

/* ---- serial port ---- */

static int open_port(void)
{
	struct termios t;
	int fd;

	fd = open(cfg.tty, O_RDWR | O_NOCTTY);
	if (fd < 0)
		return -1;
	if (tcgetattr(fd, &t) == 0) {
		cfmakeraw(&t);
		t.c_cflag |= CLOCAL | CREAD;
		t.c_cc[VMIN] = 1;
		t.c_cc[VTIME] = 0;
		tcsetattr(fd, TCSANOW, &t);
	}
	tcflush(fd, TCIOFLUSH);
	return fd;
}

/* 1 = readable, 0 = timeout, -1 = error/hangup */
static int wait_readable(int fd, int timeout_ms)
{
	struct pollfd p = { .fd = fd, .events = POLLIN };
	int r;

	do
		r = poll(&p, 1, timeout_ms);
	while (r < 0 && errno == EINTR);
	if (r < 0)
		return -1;
	if (r == 0)
		return 0;
	if (p.revents & POLLIN)
		return 1;
	return -1;
}

/* 0 ok, 1 timeout (partial frame dropped), -1 port gone */
static int read_full(int fd, uint8_t *buf, size_t n)
{
	size_t got = 0;

	while (got < n) {
		int w = wait_readable(fd, FRAME_TIMEOUT_MS);
		ssize_t r;

		if (w == 0)
			return 1;
		if (w < 0)
			return -1;
		r = read(fd, buf + got, n - got);
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		got += r;
	}
	return 0;
}

static int write_full(int fd, const uint8_t *buf, size_t n)
{
	while (n) {
		ssize_t r = write(fd, buf, n);

		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		buf += r;
		n -= r;
	}
	return 0;
}

static int send_reply(int fd, uint32_t cmd, uint32_t seq, const uint8_t *pl, uint32_t len)
{
	uint8_t frame[HDR_LEN + 512];
	uint32_t crc;

	if (len > sizeof(frame) - HDR_LEN)
		return -1;
	memset(frame, 0, HDR_LEN);
	put32(frame + 0, MAGIC);
	put32(frame + 4, DIR_DEV);
	put32(frame + 8, 0);
	put32(frame + 12, cmd);
	put32(frame + 16, FMT);
	put32(frame + 20, len);
	put32(frame + 24, seq);
	memcpy(frame + HDR_LEN, pl, len);
	crc = crc32_update(0, frame, HDR_LEN + len);
	put32(frame + 32, crc);
	return write_full(fd, frame, HDR_LEN + len);
}

/* 68 bytes: u32 result, status[64] */
static int reply_simple(int fd, uint32_t cmd, uint32_t seq, uint32_t result, const char *status)
{
	uint8_t pl[4 + STATUS_LEN];

	put32(pl, result);
	put_str(pl + 4, STATUS_LEN, status);
	return send_reply(fd, cmd, seq, pl, sizeof(pl));
}

/* 80 bytes: u32 result, u32 received, u32 total, u32 0, status[64] */
static int reply_xfer(int fd, uint32_t cmd, uint32_t seq, uint32_t result, const char *status)
{
	uint8_t pl[16 + STATUS_LEN];

	put32(pl, result);
	put32(pl + 4, up.received);
	put32(pl + 8, up.total);
	put32(pl + 12, 0);
	put_str(pl + 16, STATUS_LEN, status);
	return send_reply(fd, cmd, seq, pl, sizeof(pl));
}

/* ---- device info ---- */

/* SoC temperature, same register and conversion as caddx-ascent-lite-temp. */
static int soc_temp(void)
{
	static volatile uint32_t *regs;
	static int tried;
	uint32_t raw;

	if (!tried) {
		int fd = open("/dev/mem", O_RDONLY | O_SYNC);

		tried = 1;
		if (fd >= 0) {
			void *m = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0x1102a000);

			if (m != MAP_FAILED)
				regs = m;
			close(fd);
		}
	}
	if (!regs)
		return 0;
	raw = regs[2] & 0x3ff;
	return ((int)raw - 127) * 165 / 784 - 40;
}

static void handle_info(int fd, uint32_t seq)
{
	uint8_t pl[300];

	memset(pl, 0, sizeof(pl));
	put32(pl + 0x00, MAX_CHUNK);
	/* 0x04..0x23: SDK version, empty on stock too */
	put_str(pl + 0x24, 64, cfg.name);
	put32(pl + 0x64, soc_temp());
	put_str(pl + 0x68, 64, cfg.fw);
	put_str(pl + 0xa8, 32, cfg.sn);
	put_str(pl + 0xc8, 32, cfg.hw);
	put_str(pl + 0xec, STATUS_LEN, "OK");
	send_reply(fd, CMD_INFO, seq, pl, sizeof(pl));
}

/* ---- hook / upgrade child ---- */

static void run_hook(const char *what)
{
	pid_t pid = fork();
	int st;

	if (pid == 0) {
		execl(cfg.hook, cfg.hook, what, (char *)NULL);
		_exit(127);
	}
	if (pid > 0)
		waitpid(pid, &st, 0);
	logmsg(LOG_INFO, "hook %s done", what);
}

static void session_reset(void)
{
	if (up.fd >= 0) {
		close(up.fd);
		up.fd = -1;
		unlink(cfg.image);
	}
	up.total = up.received = 0;
	up.md5[0] = 0;
}

static void start_upgrade(void)
{
	char arg[256];
	pid_t pid;

	unlink(cfg.progress);
	snprintf(arg, sizeof(arg), "--asw=%s", cfg.image);
	pid = fork();
	if (pid == 0) {
		int log = open("/tmp/pctool-upgrade.log", O_WRONLY | O_CREAT | O_TRUNC, 0644);

		if (log >= 0) {
			dup2(log, 1);
			dup2(log, 2);
			close(log);
		}
		setsid();
		setenv("SYSUPGRADE_PROGRESS", cfg.progress, 1);
		/*
		 * -x: we reboot ourselves once the PC tool has seen "done".
		 * -f: the ASW magic was checked here already; -f only gets past
		 * sysupgrade's platform stamp check on local dev builds.
		 */
		execl(cfg.upgrade, cfg.upgrade, arg, "-x", "-f", (char *)NULL);
		_exit(127);
	}
	if (pid < 0) {
		logmsg(LOG_ERR, "fork: %s", strerror(errno));
		up.state = ST_FAILED;
		return;
	}
	up.child = pid;
	up.state = ST_RUNNING;
	up.percent = 1;
	up.stage[0] = 0;
	up.stage_polls = 0;
	logmsg(LOG_INFO, "sysupgrade started (pid %d)", (int)pid);
}

/* Percent at which each sysupgrade stage starts. */
static int stage_base(const char *s, int *next)
{
	static const struct { const char *name; int base; } map[] = {
		{ "kernel", 3 }, { "rootfs", 10 }, { "verify", 60 },
		{ "usrdata", 75 }, { "bsel", 95 }, { "done", 100 },
	};
	size_t i;

	for (i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
		if (!strcmp(s, map[i].name)) {
			*next = i + 1 < sizeof(map) / sizeof(map[0]) ? map[i + 1].base : 100;
			return map[i].base;
		}
	}
	*next = 3;
	return 1;
}

static void read_stage(char *out, size_t n)
{
	char line[32], last[32] = "";
	FILE *f = fopen(cfg.progress, "r");

	if (f) {
		while (fgets(line, sizeof(line), f)) {
			line[strcspn(line, "\r\n")] = 0;
			if (line[0])
				snprintf(last, sizeof(last), "%s", line);
		}
		fclose(f);
	}
	snprintf(out, n, "%s", last);
}

/* Reap sysupgrade and refresh state/percent. Called on every poll and idle tick. */
static void update_upgrade(int polled)
{
	char stage[32];
	int st, base, next;

	if (!up.child)
		return;
	read_stage(stage, sizeof(stage));
	if (strcmp(stage, up.stage)) {
		snprintf(up.stage, sizeof(up.stage), "%s", stage);
		up.stage_polls = 0;
	} else if (polled) {
		up.stage_polls++;
	}
	base = stage_base(up.stage, &next);
	up.percent = base + up.stage_polls;
	if (up.percent >= next)
		up.percent = next > base ? next - 1 : base;

	if (waitpid(up.child, &st, WNOHANG) != up.child)
		return;
	up.child = 0;
	if (WIFEXITED(st) && WEXITSTATUS(st) == 0 && !strcmp(up.stage, "done")) {
		up.state = ST_DONE;
		up.percent = 100;
		up.reboot_at = time(NULL) + DONE_REBOOT_S;
		logmsg(LOG_INFO, "sysupgrade done, new bank selected");
	} else {
		up.state = ST_FAILED;
		logmsg(LOG_ERR, "sysupgrade failed (stage %s, status 0x%x), see /tmp/pctool-upgrade.log",
		       up.stage[0] ? up.stage : "-", st);
		unlink(cfg.image);
		run_hook("restore");
	}
}

/* ---- commands ---- */

static int upgrade_busy(void)
{
	return up.child || up.state == ST_DONE;
}

static void handle_start(int fd, uint32_t seq, const uint8_t *pl, uint32_t len)
{
	struct statvfs vfs;
	char dir[256], *slash;
	uint64_t avail;
	uint32_t size;
	int i;

	if (len < 0x48) {
		reply_simple(fd, CMD_START, seq, 1, "FAIL: short start frame");
		return;
	}
	if (upgrade_busy()) {
		reply_simple(fd, CMD_START, seq, 1, "FAIL: upgrade in progress");
		return;
	}
	session_reset();
	size = get32(pl + 0x40);
	for (i = 0; i < 32 && isxdigit(pl[i]); i++)
		up.md5[i] = tolower(pl[i]);
	up.md5[i] = 0;
	logmsg(LOG_INFO, "upgrade start: %u bytes, md5 %s, host file %.128s",
	       size, up.md5, len >= 0xc8 + 128 ? (const char *)pl + 0xc8 : "?");
	if (i != 32 || !size) {
		reply_simple(fd, CMD_START, seq, 1, "FAIL: bad md5 or size");
		return;
	}

	snprintf(dir, sizeof(dir), "%s", cfg.image);
	slash = strrchr(dir, '/');
	if (slash && slash != dir)
		*slash = 0;
	unlink(cfg.image);
	if (statvfs(dir, &vfs) == 0) {
		avail = (uint64_t)vfs.f_bavail * vfs.f_frsize;
		if (avail < (uint64_t)size + (1u << 20)) {
			logmsg(LOG_ERR, "no room for %u bytes in %s (%llu free)", size, dir,
			       (unsigned long long)avail);
			reply_simple(fd, CMD_START, seq, 1, "FAIL: no space on device");
			return;
		}
	}
	/* RDWR: handle_done reads the magic back */
	up.fd = open(cfg.image, O_RDWR | O_CREAT | O_TRUNC, 0600);
	if (up.fd < 0) {
		logmsg(LOG_ERR, "open %s: %s", cfg.image, strerror(errno));
		reply_simple(fd, CMD_START, seq, 1, "FAIL: cannot create image file");
		return;
	}
	up.total = size;
	up.received = 0;
	up.state = ST_IDLE;
	up.percent = 0;
	md5_init(&up.md5ctx);
	reply_simple(fd, CMD_START, seq, 0, "OK");
}

static void handle_data(int fd, uint32_t seq, const uint8_t *pl, uint32_t len)
{
	if (up.fd < 0) {
		reply_xfer(fd, CMD_DATA, seq, 1, "FAIL: no upgrade started");
		return;
	}
	if ((uint64_t)up.received + len > up.total) {
		logmsg(LOG_ERR, "data overrun: %u + %u > %u", up.received, len, up.total);
		session_reset();
		reply_xfer(fd, CMD_DATA, seq, 1, "FAIL: more data than announced");
		return;
	}
	if (write_full(up.fd, pl, len)) {
		logmsg(LOG_ERR, "write %s: %s", cfg.image, strerror(errno));
		session_reset();
		reply_xfer(fd, CMD_DATA, seq, 1, "FAIL: write error on device");
		return;
	}
	md5_update(&up.md5ctx, pl, len);
	up.received += len;
	reply_xfer(fd, CMD_DATA, seq, 0, "OK");
}

static void handle_done(int fd, uint32_t seq)
{
	uint8_t digest[16], magic[4];
	char hex[33];
	int i;

	if (up.fd < 0) {
		reply_xfer(fd, CMD_DONE, seq, 1, "FAIL: no upgrade started");
		return;
	}
	if (up.received != up.total) {
		logmsg(LOG_ERR, "short upload: %u of %u bytes", up.received, up.total);
		session_reset();
		reply_xfer(fd, CMD_DONE, seq, 1, "FAIL: incomplete upload");
		return;
	}
	md5_final(&up.md5ctx, digest);
	for (i = 0; i < 16; i++)
		sprintf(hex + 2 * i, "%02x", digest[i]);
	if (strcmp(hex, up.md5)) {
		logmsg(LOG_ERR, "md5 mismatch: got %s, expected %s", hex, up.md5);
		session_reset();
		reply_xfer(fd, CMD_DONE, seq, 1, "FAIL: md5 mismatch");
		return;
	}
	if (pread(up.fd, magic, 4, 0) != 4 || memcmp(magic, "ASW", 4)) {
		logmsg(LOG_ERR, "not an ASW image");
		session_reset();
		reply_xfer(fd, CMD_DONE, seq, 1, "FAIL: not an ASW image");
		return;
	}
	close(up.fd);
	up.fd = -1;
	logmsg(LOG_INFO, "upload complete, md5 %s", hex);
	reply_xfer(fd, CMD_DONE, seq, 0, "OK");
	start_upgrade();
}

static void handle_status(int fd, uint32_t seq)
{
	uint8_t pl[8 + STATUS_LEN];
	const char *msg = "";

	update_upgrade(1);
	if (up.state == ST_FAILED)
		msg = "FAIL: see /tmp/pctool-upgrade.log";
	put32(pl, up.percent);
	put32(pl + 4, up.state);
	put_str(pl + 8, STATUS_LEN, msg);
	send_reply(fd, CMD_STATUS, seq, pl, sizeof(pl));
	if (up.state == ST_DONE) {
		/* Stock reboots right after reporting done; give the reply a moment. */
		tcdrain(fd);
		up.reboot_at = time(NULL) + 1;
	}
}

/* Returns 1 when the port has to be reopened (after "clean"). */
static int dispatch(int fd, uint32_t cmd, uint32_t seq, const uint8_t *pl, uint32_t len)
{
	switch (cmd) {
	case CMD_INFO:
		handle_info(fd, seq);
		return 0;
	case CMD_REBOOT: {
		char mode[33];

		snprintf(mode, sizeof(mode), "%.*s", (int)(len < 32 ? len : 32), (const char *)pl);
		logmsg(LOG_INFO, "reboot request, mode '%s'", mode);
		if (upgrade_busy()) {
			reply_simple(fd, cmd, seq, 1, "FAIL: upgrade in progress");
			return 0;
		}
		reply_simple(fd, cmd, seq, 0, "OK");
		tcdrain(fd);
		session_reset();
		up.state = ST_IDLE;
		up.percent = 0;
		/*
		 * Stock reboots into a stripped-down "clean system". We stop the
		 * video stack instead and drop off the bus for a moment, which
		 * is what the PC tool's reconnect logic waits for.
		 */
		run_hook(strcmp(mode, "clean") ? "reboot" : "clean");
		return 1;
	}
	case CMD_CONNECT:
		reply_simple(fd, cmd, seq, 0, "OK");
		return 0;
	case CMD_RNDIS:
		/* Stock: RNDIS instead of the serial port. The hook stops us. */
		if (upgrade_busy()) {
			reply_simple(fd, cmd, seq, 1, "FAIL: upgrade in progress");
			return 0;
		}
		reply_simple(fd, cmd, seq, 0, "OK");
		tcdrain(fd);
		session_reset();
		run_hook("rndis");
		return 1;
	case CMD_START:
		handle_start(fd, seq, pl, len);
		return 0;
	case CMD_DATA:
		handle_data(fd, seq, pl, len);
		return 0;
	case CMD_DONE:
		handle_done(fd, seq);
		return 0;
	case CMD_STATUS:
		handle_status(fd, seq);
		return 0;
	default:
		logmsg(LOG_WARNING, "unknown cmd 0x%02x (len %u), answering FAIL", cmd, len);
		reply_simple(fd, cmd, seq, 1, "FAIL: unsupported");
		return 0;
	}
}

static void idle_tick(void)
{
	update_upgrade(0);
	if (up.reboot_at && time(NULL) >= up.reboot_at) {
		logmsg(LOG_INFO, "rebooting into the new bank");
		up.reboot_at = 0;
		run_hook("reboot");
	}
}

/* Serve one open port until it goes away. */
static void serve(int fd)
{
	uint8_t hdr[HDR_LEN];

	for (;;) {
		uint32_t len, cmd, seq, crc;
		size_t have = 0;
		int r;

		/* Sync on the magic; anything else (a modem probe, a cut-off frame) is skipped. */
		while (have < 4) {
			r = wait_readable(fd, 1000);
			if (r < 0)
				return;
			if (r == 0) {
				idle_tick();
				continue;
			}
			if (read(fd, hdr + have, 1) != 1)
				return;
			have++;
			if (have == 4 && get32(hdr) != MAGIC) {
				memmove(hdr, hdr + 1, 3);
				have = 3;
			}
		}
		r = read_full(fd, hdr + 4, HDR_LEN - 4);
		if (r < 0)
			return;
		if (r > 0)
			continue;
		cmd = get32(hdr + 12);
		len = get32(hdr + 20);
		seq = get32(hdr + 24);
		crc = get32(hdr + 32);
		if (len > MAX_CHUNK) {
			logmsg(LOG_WARNING, "cmd 0x%02x: length %u too big, dropped", cmd, len);
			continue;
		}
		r = read_full(fd, payload, len);
		if (r < 0)
			return;
		if (r > 0) {
			logmsg(LOG_WARNING, "cmd 0x%02x: payload timed out, dropped", cmd);
			continue;
		}
		memset(hdr + 32, 0, 4);
		/* ascent/sky_trigger_rndis.py sends 0x3a with crc 0, and stock takes it. */
		if (crc32_update(crc32_update(0, hdr, HDR_LEN), payload, len) != crc &&
		    !(cmd == CMD_RNDIS && crc == 0)) {
			logmsg(LOG_WARNING, "cmd 0x%02x seq %u: bad crc, dropped", cmd, seq);
			continue;
		}
		if (cmd != CMD_DATA && cmd != CMD_STATUS)
			logmsg(LOG_INFO, "cmd 0x%02x seq %u len %u", cmd, seq, len);
		if (dispatch(fd, cmd, seq, payload, len))
			return;
	}
}

static void usage(const char *argv0)
{
	fprintf(stderr,
		"Usage: %s [options]\n"
		"  -d TTY      serial port (default %s)\n"
		"  -o FILE     where the uploaded image goes (default %s)\n"
		"  -u CMD      upgrade command, run as CMD --asw=FILE -x -f (default %s)\n"
		"  -k HOOK     hook script: HOOK clean|restore|reboot|rndis (default %s)\n"
		"  -N NAME     device name for the info reply (default %s)\n"
		"  -F FW       firmware version string (default %s)\n"
		"  -H HW       hardware version string (default %s)\n"
		"  -S SN       serial number (default %s)\n"
		"  -f          foreground, log to stderr\n",
		argv0, cfg.tty, cfg.image, cfg.upgrade, cfg.hook, cfg.name, cfg.fw, cfg.hw, cfg.sn);
}

int main(int argc, char **argv)
{
	int c;

	while ((c = getopt(argc, argv, "d:o:u:k:N:F:H:S:fh")) != -1) {
		switch (c) {
		case 'd': cfg.tty = optarg; break;
		case 'o': cfg.image = optarg; break;
		case 'u': cfg.upgrade = optarg; break;
		case 'k': cfg.hook = optarg; break;
		case 'N': cfg.name = optarg; break;
		case 'F': cfg.fw = optarg; break;
		case 'H': cfg.hw = optarg; break;
		case 'S': cfg.sn = optarg; break;
		case 'f': cfg.foreground = 1; break;
		default:
			usage(argv[0]);
			return c == 'h' ? 0 : 1;
		}
	}
	if (!cfg.foreground)
		openlog("pctoold", LOG_PID, LOG_DAEMON);
	signal(SIGPIPE, SIG_IGN);
	payload = malloc(MAX_CHUNK + 16);
	if (!payload)
		return 1;
	logmsg(LOG_INFO, "listening on %s", cfg.tty);

	for (;;) {
		int fd = open_port();

		if (fd < 0) {
			idle_tick();
			usleep(500000);
			continue;
		}
		serve(fd);
		close(fd);
		/* A hung-up port reads as EOF until the host is back; don't spin. */
		idle_tick();
		usleep(300000);
	}
}
