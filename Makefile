.PHONY: build install test run clean

build:
	./scripts/build.sh

install: build
	osascript -e 'quit app "Into"' 2>/dev/null || true
	rm -rf /Applications/Into.app
	ditto build/Into.app /Applications/Into.app

test: build
	build/Into.app/Contents/MacOS/Into --self-test

run: build
	open build/Into.app

clean:
	rm -rf build
