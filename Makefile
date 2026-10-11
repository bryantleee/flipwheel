APP    = Flipwheel
ID     = com.bryant.flipwheel
# Ad-hoc by default. Pass SIGN="<certificate name>" to sign with a stable identity, which keeps the
# Accessibility grant across rebuilds (an ad-hoc signature changes with every build).
SIGN  ?= -
CFLAGS = -fobjc-arc -O2 -Wall -arch arm64 -arch x86_64 -mmacosx-version-min=13.0
BIN    = $(APP).app/Contents/MacOS/$(APP)

$(BIN): main.m Info.plist
	mkdir -p $(dir $@)
	clang $(CFLAGS) -framework Cocoa -framework ServiceManagement main.m -o $@
	cp Info.plist $(APP).app/Contents/
	codesign --force --sign "$(SIGN)" $(APP).app

# Single-file build: same binary with Info.plist embedded, no bundle. Not re-signed on purpose:
# codesign would treat this directory as a flat bundle (Info.plist beside the executable).
bare: main.m Info.plist
	clang $(CFLAGS) -sectcreate __TEXT __info_plist Info.plist -framework Cocoa -framework ServiceManagement main.m -o $(APP)

run: $(BIN)
	-pkill -x $(APP)
	open $(APP).app

# Copies the app to /Applications and launches it from there, so the login item does not point into this clone.
install: $(BIN)
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app
	cp -R $(APP).app /Applications/
	open /Applications/$(APP).app

# Clears a stale Accessibility grant after a rebuild. Quit the app first. tccutil looks the identifier up through
# LaunchServices, which forgets a bundle that `make clean` deleted, so build and register it first.
reset: $(BIN)
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $(APP).app
	tccutil reset Accessibility $(ID)

# Self-check: posts synthetic scroll events and verifies only the discrete one is reversed.
test: test.c
	clang -Wall -framework CoreGraphics -framework CoreFoundation test.c -o selftest && ./selftest

clean:
	rm -rf $(APP).app $(APP) selftest

.PHONY: bare run install reset test clean
