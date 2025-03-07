.PHONY: test
test:
	sui move test
build:
	sui move build
publish:
	sui client publish