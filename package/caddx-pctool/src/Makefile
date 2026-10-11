CC ?= gcc
CFLAGS ?= -O2
LDFLAGS ?=

all: pctoold

pctoold: pctoold.c md5.c md5.h
	$(CC) $(CFLAGS) -Wall -o $@ pctoold.c md5.c $(LDFLAGS)

clean:
	rm -f pctoold

.PHONY: all clean
