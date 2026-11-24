EMACS ?= emacs
PYTHON ?= python3
CC ?= cc
MODULE_SUFFIX := $(shell $(EMACS) -Q --batch --eval '(princ (or module-file-suffix ".so"))')
EMACS_INCLUDE ?= $(shell $(EMACS) -Q --batch --eval '(princ (file-name-directory (or (locate-file "emacs-module.h" (list (expand-file-name "../include" invocation-directory) (expand-file-name "../../../include" invocation-directory) "/opt/homebrew/include" "/usr/local/include" "/usr/include")) "./emacs-module.h")))')
MODULE := pele-native$(MODULE_SUFFIX)
UNAME_S := $(shell uname -s)
PANGO_CFLAGS := $(shell pkg-config --cflags pangocairo 2>/dev/null)
PANGO_LIBS := $(shell pkg-config --libs pangocairo 2>/dev/null)
CPPFLAGS += -D_GNU_SOURCE -DCONFIG_VERSION='"2026-06-04"' -isystem vendor/quickjs -Ibuild -I$(EMACS_INCLUDE)
CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -fPIC -fvisibility=hidden -pthread
CORE := quickjs dtoa libregexp libunicode cutils
OBJECTS := $(addprefix build/,$(addsuffix .o,$(CORE))) build/pele-module.o
ifneq ($(strip $(PANGO_LIBS)),)
CPPFLAGS += -DPELE_USE_PANGO $(PANGO_CFLAGS)
LDLIBS += $(PANGO_LIBS)
endif
ifeq ($(UNAME_S),Darwin)
SHARED_FLAGS := -dynamiclib
else
SHARED_FLAGS := -shared
endif

.PHONY: all test test-corpus check compile clean
all: $(MODULE)

build:
	mkdir -p build

build/bundles.h: vendor/pele/pele.global.js src/bridge.js scripts/embed.py | build
	$(PYTHON) scripts/embed.py $@ vendor/pele/pele.global.js src/bridge.js

build/%.o: vendor/quickjs/%.c $(wildcard vendor/quickjs/*.h) | build
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

build/pele-module.o: src/pele-module.c build/bundles.h Makefile
	$(CC) $(CPPFLAGS) $(CFLAGS) -Wall -Wextra -Werror -c $< -o $@

$(MODULE): $(OBJECTS)
	$(CC) $(SHARED_FLAGS) $(LDFLAGS) -o $@ $(OBJECTS) $(LDLIBS) -lm -pthread

compile:
	$(EMACS) -Q --batch --eval '(dolist (file (directory-files "test" t "\\.el$$")) (with-temp-buffer (insert-file-contents file) (emacs-lisp-mode) (check-parens)))'
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile pele-font-lock.el pele-mode.el pele.el ob-pele.el

test: all compile
	$(EMACS) -Q --batch -L . -L test -l pele-mode-tests -l pele-highlighting-tests -f ert-run-tests-batch-and-exit
	$(EMACS) -Q --batch --module-assertions -L . -L test -l pele-tests -f ert-run-tests-batch-and-exit

test-corpus: all compile
	$(EMACS) -Q --batch --module-assertions -L . -L test -l pele-corpus-tests -f ert-run-tests-batch-and-exit

check: test test-corpus

clean:
	$(PYTHON) -c 'import pathlib, shutil; shutil.rmtree("build", ignore_errors=True); [p.unlink(missing_ok=True) for pattern in ("pele-native.so", "pele-native.dylib", "*.elc") for p in pathlib.Path(".").glob(pattern)]'
