# Directories
SRCDIR = src
OBJDIR = obj
BINDIR = bin

# Main program
MAIN = tp-link-decrypt

# Find all source files
SOURCES := $(shell find $(SRCDIR) -name '*.c')
OBJECTS := $(SOURCES:$(SRCDIR)/%.c=$(OBJDIR)/%.o)

# Toolchain: overridable, so cross-compiling or a non-gcc default cc both work.
CC ?= cc
PKG_CONFIG ?= pkg-config

# OpenSSL (libcrypto): prefer pkg-config, then Homebrew's keg-only openssl@3 on
# macOS, then a bare -lcrypto for distros that put it on the default path.
SSL_CFLAGS := $(shell $(PKG_CONFIG) --cflags libcrypto 2>/dev/null)
SSL_LIBS   := $(shell $(PKG_CONFIG) --libs   libcrypto 2>/dev/null)
ifeq ($(strip $(SSL_LIBS)),)
  SSL_PREFIX := $(shell brew --prefix openssl@3 2>/dev/null)
  ifneq ($(strip $(SSL_PREFIX)),)
    SSL_CFLAGS := -I$(SSL_PREFIX)/include
    SSL_LIBS   := -L$(SSL_PREFIX)/lib -lcrypto
  else
    SSL_LIBS   := -lcrypto
  endif
endif

CFLAGS  ?= -O2
CFLAGS  += -Wno-implicit-function-declaration -I$(SRCDIR) -std=c99 $(SSL_CFLAGS)
LDLIBS  += $(SSL_LIBS)

# Main target
$(BINDIR)/$(MAIN): $(OBJECTS)
	@mkdir -p $(BINDIR)
	$(CC) $(OBJECTS) $(CFLAGS) $(LDFLAGS) $(LDLIBS) -o $@

# Rule for object files
$(OBJDIR)/%.o: $(SRCDIR)/%.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -c $< -o $@

# Clean rule
clean:
	rm -rf $(OBJDIR) $(BINDIR)

.PHONY: clean
