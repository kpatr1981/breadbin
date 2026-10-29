# Breadbin build
BUILD   := build
KSRC    := $(wildcard src/kernel/*.s)
KOBJ    := $(patsubst src/kernel/%.s,$(BUILD)/k/%.o,$(KSRC))
PROGS   := $(patsubst src/bin/%.s,%,$(wildcard src/bin/*.s))
CX      := $(patsubst %,$(BUILD)/root/bin/%,$(PROGS))
LIBSRC  := $(wildcard src/lib/*.s)
LIBOBJ  := $(BUILD)/lib/breadbin.lib
ROOTSRC := $(shell find rootfs -type f)

.PHONY: all clean test test-host run run-reu
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

test-host:
	python3 -m unittest discover -s tools -p 'test_*.py'

test: all test-host
	python3 -m unittest discover -s tests -p 'test_*.py' -v

run: all
	x64sc -autostart $(BUILD)/breadbin.d64

run-reu: all
	x64sc -reu -reusize 512 -autostart $(BUILD)/breadbin.d64

clean:
	rm -rf $(BUILD)
