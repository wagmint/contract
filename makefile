.PHONY: test
test:
	sui move test
build:
	sui move build
publish:
	sui client publish
create-coin:
	@sui client call \
		--package $(PACKAGE_ID) \
		--module coin_manager \
		--function create_coin \
		--type-args $(COIN_TYPE) \
		--args \
			$(LAUNCHPAD_ID) \
			$(TREASURY_CAP_ID) \
			$(REGISTRY_ID) \
			$(PAYMENT_COIN_ID) \
			"My Token" \
			"MTK" \
			"This is my awesome token description" \
			"https://mytoken.com" \
			"https://example.com/image.png" \
			"null" \
		--gas-budget 100000000
buy-tokens:
	@sui client call \
		--package $(PACKAGE_ID) \
		--module coin_manager \
		--function buy_tokens \
		--type-args $(COIN_TYPE) \
		--args \
			$(LAUNCHPAD_ID) \
			$(COIN_INFO_ID) \
			$(PAYMENT_COIN_ID) \
			$(or $(amount), $(AMOUNT)) \
		--gas-budget 100000000
sell-tokens:
	@sui client call \
		--package $(PACKAGE_ID) \
		--module coin_manager \
		--function sell_tokens \
		--type-args $(COIN_TYPE) \
		--args \
			$(LAUNCHPAD_ID) \
			$(COIN_INFO_ID) \
			$(TOKEN_COIN_ID) \
		--gas-budget 100000000