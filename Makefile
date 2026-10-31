# Breadbin build
BUILD   := build
KSRC    := $(wildcard src/kernel/*.s)
KOBJ    := $(patsubst src/kernel/%.s,$(BUILD)/k/%.o,$(KSRC))
PROGS   := $(patsubst src/bin/%.s,%,$(wildcard src/bin/*.s))
CX      := $(patsubst %,$(BUILD)/root/bin/%,$(PROGS))
LIBSRC  := $(wildcard src/lib/*.s)
LIBOBJ  := $(BUILD)/lib/breadbin.lib
ROOTSRC := $(shell find rootfs -type f)

.PHONY: all clean test test-host test-ntsc test-openroms webdemo video run run-reu
.SECONDARY:
all: $(BUILD)/breadbin.d64

$(BUILD)/k/%.o: src/kernel/%.s src/kernel/k.inc include/breadbin.inc
	@mkdir -p $(dir $@)
	ca65 -g -I src/kernel $< -o $@

$(BUILD)/breadbin.prg: $(KOBJ) src/kernel.cfg
	ld65 -C src/kernel.cfg -m $(BUILD)/kernel.map -Ln $(BUILD)/kernel.lbl -o $@ $(KOBJ)

$(BUILD)/lib/%.o: src/lib/%.s include/breadbin.inc
	@mkdir -p $(dir $@)
	ca65 -g $< -o $@

$(LIBOBJ): $(patsubst src/lib/%.s,$(BUILD)/lib/%.o,$(LIBSRC))
	rm -f $@
	ar65 a $@ $^

$(BUILD)/p/%.o: src/bin/%.s include/breadbin.inc
	@mkdir -p $(dir $@)
	ca65 -g $< -o $@

# link twice (origin $0000 and $0100) and diff into a relocatable CX file
$(BUILD)/root/bin/%: $(BUILD)/p/%.o $(LIBOBJ) src/prog.cfg tools/cx.py
	@mkdir -p $(dir $@) $(BUILD)/p
	ld65 -C src/prog.cfg -S 0 -Ln $(BUILD)/p/$*.lbl -o $(BUILD)/p/$*.0 $< $(LIBOBJ)
	ld65 -C src/prog.cfg -S 256 -o $(BUILD)/p/$*.1 $< $(LIBOBJ)
	python3 tools/cx.py $(BUILD)/p/$*.0 $(BUILD)/p/$*.1 $(BUILD)/p/$*.lbl $@

$(BUILD)/breadbin.d64: $(BUILD)/breadbin.prg $(CX) $(ROOTSRC) tools/mkimage.py
	@mkdir -p $(BUILD)/root
	cp -R rootfs/. $(BUILD)/root/
	python3 tools/mkimage.py build $@ --boot $(BUILD)/breadbin.prg --root $(BUILD)/root --dev console:1 --dev null:0

# test image: the system plus the helper programs in tests/progs, as /test/*
TPROGS  := $(patsubst tests/progs/%.s,%,$(wildcard tests/progs/*.s))
TCX     := $(patsubst %,$(BUILD)/troot/test/%,$(TPROGS))

$(BUILD)/tp/%.o: tests/progs/%.s include/breadbin.inc
	@mkdir -p $(dir $@)
	ca65 -g $< -o $@

$(BUILD)/troot/test/%: $(BUILD)/tp/%.o $(LIBOBJ) src/prog.cfg tools/cx.py
	@mkdir -p $(dir $@)
	ld65 -C src/prog.cfg -S 0 -Ln $(BUILD)/tp/$*.lbl -o $(BUILD)/tp/$*.0 $< $(LIBOBJ)
	ld65 -C src/prog.cfg -S 256 -o $(BUILD)/tp/$*.1 $< $(LIBOBJ)
	python3 tools/cx.py $(BUILD)/tp/$*.0 $(BUILD)/tp/$*.1 $(BUILD)/tp/$*.lbl $@

$(BUILD)/breadbin-test.d64: $(BUILD)/breadbin.d64 $(TCX)
	rm -rf $(BUILD)/troot.all
	mkdir -p $(BUILD)/troot.all
	cp -R $(BUILD)/root/. $(BUILD)/troot/. $(BUILD)/troot.all/
	python3 tools/mkimage.py build $@ --boot $(BUILD)/breadbin.prg --root $(BUILD)/troot.all --dev console:1 --dev null:0

test-host:
	python3 -m unittest discover -s tools -p 'test_*.py'

# system tests run in parallel, one VICE per test class (tools/ptest.py);
# `python3 tools/ptest.py --failed` reruns only what failed
test: all $(BUILD)/breadbin-test.d64 test-host
	python3 tools/ptest.py

# the same tests on an NTSC machine
test-ntsc: all $(BUILD)/breadbin-test.d64
	VICEFLAGS=-ntsc python3 tools/ptest.py

# the same system tests under the MEGA65 Open ROMs (LGPL-3, fetched once)
OPENROMS     := $(BUILD)/openroms
OPENROMS_REV := ad178dbe4d48cd6a317737a8e0e7e662f7e33d32
OPENROMS_URL := https://raw.githubusercontent.com/MEGA65/open-roms/$(OPENROMS_REV)/bin
$(OPENROMS)/%.rom:
	@mkdir -p $(dir $@)
	curl -sfL -o $@ $(OPENROMS_URL)/$*.rom

test-openroms: all $(BUILD)/breadbin-test.d64 $(OPENROMS)/kernal_generic.rom $(OPENROMS)/basic_generic.rom $(OPENROMS)/chargen_openroms.rom
	OPENROMS=$(OPENROMS) python3 tools/ptest.py

# the browser demo (itch.io HTML5): EmulatorJS + VICE on the Open ROMs, booting from the REU
# WEBDEMO = the webdemo kit (EmulatorJS + VICE core), e.g. make webdemo WEBDEMO=~/webdemo
webdemo: all
	@test -n "$(WEBDEMO)" || { echo "set WEBDEMO to the webdemo kit directory"; exit 1; }
	python3 tools/webdemo.py $(WEBDEMO) $(BUILD)/breadbin.prg $(BUILD)/breadbin.d64 $(BUILD)/webdemo

# the YouTube demo video (a typed session, booted like the browser demo)
video: all $(OPENROMS)/kernal_generic.rom $(OPENROMS)/basic_generic.rom $(OPENROMS)/chargen_openroms.rom
	python3 tools/demovideo.py $(OPENROMS) $(BUILD)/breadbin.prg $(BUILD)/breadbin.d64 $(BUILD)/video

run: all
	x64sc -autostart $(BUILD)/breadbin.d64

run-reu: all
	x64sc -reu -reusize 512 -autostart $(BUILD)/breadbin.d64

clean:
	rm -rf $(BUILD)
