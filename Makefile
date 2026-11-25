EMACS ?= emacs
PYTHON ?= python3
CC ?= cc
MARKDOWN_MODE_DIR ?= $(firstword $(wildcard /usr/share/emacs/site-lisp/elpa/markdown-mode-*))
MODULE_SUFFIX := $(shell $(EMACS) -Q --batch --eval '(princ (or module-file-suffix ".so"))')
EMACS_INCLUDE ?= $(shell $(EMACS) -Q --batch --eval '(princ (file-name-directory (or (locate-file "emacs-module.h" (list (expand-file-name "../include" invocation-directory) (expand-file-name "../../../include" invocation-directory) "/opt/homebrew/include" "/usr/local/include" "/usr/include")) "./emacs-module.h")))')
MODULE := pele-native$(MODULE_SUFFIX)
UNAME_S := $(shell uname -s)
PANGO_PACKAGES := pangocairo
ifeq ($(UNAME_S),Linux)
PANGO_PACKAGES += pangofc fontconfig
endif
PANGO_CFLAGS := $(shell pkg-config --cflags $(PANGO_PACKAGES) 2>/dev/null)
PANGO_LIBS := $(shell pkg-config --libs $(PANGO_PACKAGES) 2>/dev/null)
TEXT_BACKEND ?= auto
FONT_BACKEND := $(TEXT_BACKEND)
ifeq ($(FONT_BACKEND),auto)
ifeq ($(UNAME_S),Darwin)
FONT_BACKEND := coretext
else ifneq ($(strip $(PANGO_LIBS)),)
FONT_BACKEND := pango
else
FONT_BACKEND := estimate
endif
endif
CPPFLAGS += -D_GNU_SOURCE -DCONFIG_VERSION='"2026-06-04"' -isystem vendor/quickjs -Ibuild -I$(EMACS_INCLUDE)
CFLAGS ?= -O2 -g
CFLAGS += -std=gnu11 -fPIC -fvisibility=hidden -pthread
CORE := quickjs dtoa libregexp libunicode cutils
OBJECTS := $(addprefix build/,$(addsuffix .o,$(CORE))) build/pele-module.o
ifeq ($(FONT_BACKEND),pango)
ifeq ($(strip $(PANGO_LIBS)),)
$(error Pango not found: install the pangocairo development package)
endif
CPPFLAGS += -DPELE_USE_PANGO $(PANGO_CFLAGS)
LDLIBS += $(PANGO_LIBS)
ifeq ($(UNAME_S),Linux)
CPPFLAGS += -DPELE_USE_FONTCONFIG
endif
else ifeq ($(FONT_BACKEND),coretext)
ifneq ($(UNAME_S),Darwin)
$(error Core Text is only available on macOS)
endif
CPPFLAGS += -DPELE_USE_CORETEXT
LDLIBS += -framework CoreText -framework CoreFoundation
else ifneq ($(FONT_BACKEND),estimate)
$(error Unknown TEXT_BACKEND: $(TEXT_BACKEND))
endif
ifeq ($(UNAME_S),Darwin)
SHARED_FLAGS := -dynamiclib
else
SHARED_FLAGS := -shared
endif

.PHONY: all test test-lisp test-renderer test-corpus check compile clean package
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
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile pele-font-lock.el pele-mode.el pele-module.el pele.el pele-markdown.el ob-pele.el

test-lisp: compile
	$(EMACS) -Q --batch -L . -L test -l pele-mode-tests -l pele-highlighting-tests -l pele-module-tests -l pele-package-tests -f ert-run-tests-batch-and-exit

test-renderer: all compile
	$(EMACS) -Q --batch --module-assertions -L . -L test $(if $(MARKDOWN_MODE_DIR),-L "$(MARKDOWN_MODE_DIR)") -l pele-tests -l pele-markdown-tests -f ert-run-tests-batch-and-exit

test: test-lisp test-renderer

test-corpus: all compile
	$(EMACS) -Q --batch --module-assertions -L . -L test -l pele-corpus-tests -f ert-run-tests-batch-and-exit

check: test test-corpus

package: all
	$(PYTHON) scripts/package.py $(MODULE)

clean:
	$(PYTHON) -c 'import pathlib, shutil; shutil.rmtree("build", ignore_errors=True); [p.unlink(missing_ok=True) for pattern in ("pele-native.so", "pele-native.dylib", "*.elc") for p in pathlib.Path(".").glob(pattern)]'
