# Builds the SANE backend as libsane-plustek_scanapi.1.so; SANE's dll backend finds it through LD_LIBRARY_PATH.
SANE_PREFIX ?= /opt/homebrew
CFLAGS += -O2 -Wall -Wextra -Wno-unused-parameter -I$(SANE_PREFIX)/include
LDFLAGS += -dynamiclib -framework CoreFoundation -framework IOKit

libsane-plustek_scanapi.1.so: plustek_scanapi.c ../scanapi/scanapi.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ plustek_scanapi.c

clean:
	rm -f libsane-plustek_scanapi.1.so
