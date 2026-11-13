# Keystrike - force-sensitive mechanical keyboard sounds for Apple Silicon MacBooks.
#
#   make app        build the .app bundle you can run
#   make run        build + open it
#   make packs      regenerate every sound pack from the upstream recordings
#   make test-audio  smoke-test the C audio engine on the default device
#   make test-offline render a WAV offline and print engine stats
#   make clean

ROOT := $(CURDIR)
CONFIG ?= debug
BUILD := $(ROOT)/.build/$(CONFIG)
APP := $(ROOT)/.build/app/$(CONFIG)/Keystrike.app

.PHONY: all build app dmg run packs test-audio test-offline clean sign

all: build

build:
	swift build -c $(CONFIG)

# All packs ship generated and committed; regenerate only when the recipes change.
packs:
	python3 Tools/generate_packs.py

app: | packs
	bash scripts/build_app.sh $(CONFIG)

run: app
	open "$(APP)"

# A drag-to-install image: the .app plus an Applications symlink.
dmg:
	bash scripts/build_dmg.sh $(CONFIG)

# Engine sources, compiled directly (fewer files than reusing SwiftPM objects,
# and immune to the .o layout).
ENGINE_SRC := Sources/ThockAudio/audio_engine.c Sources/ThockAudio/pack.c Sources/ThockAudio/wav.c
ENGINE_INC := -ISources/ThockAudio/include
ENGINE_LIB := -framework AudioToolbox -framework CoreAudio -framework CoreFoundation

# Headless engine test: plays every tier through the default output device.
test-audio: build
	@mkdir -p /tmp/ktest
	cc -O1 -Wall $(ENGINE_INC) Tools/engine_test.c $(ENGINE_SRC) $(ENGINE_LIB) -o /tmp/ktest/engine_test
	KS_PACKS=$(ROOT)/Resources/Packs /tmp/ktest/engine_test $(ROOT)/Resources/Packs/cream

# Offline render: same engine, zero output device. Use this to verify the
# mixing path when the machine's audio refuses to start.
test-offline: build
	@mkdir -p /tmp/ktest
	cc -O1 -Wall $(ENGINE_INC) Tools/engine_test.c $(ENGINE_SRC) $(ENGINE_LIB) -o /tmp/ktest/engine_test
	KS_PACKS=$(ROOT)/Resources/Packs KS_NO_OUTPUT=1 \
		/tmp/ktest/engine_test --render --out=/tmp/thock_offline.wav $(ROOT)/Resources/Packs/cream

clean:
	rm -rf .build
	@echo "cleaned"
