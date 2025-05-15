.PHONY: test

# Configuration variables
PACKAGE_ID = 0xd1d8b0b97afc9bc472f657693a10c117b1d629c78f02dc689089f01f15e6bf18
COIN_TYPE = 0xc452eb18a8619c380cb6bf22aa58b924e4a1d7278a614744ef277eb28e526b20::my_token::MY_TOKEN
LAUNCHPAD_ID = 0x2416ef708810aa8c5c80628ec87bc3546af0ffb1659f541e0eace7b64bd83c54
REGISTRY_ID = 0x43302ab60cd8571c307d933dde5bde9423453b357f50596230687d6a0dcbe121
PAYMENT_COIN_ID = 0xb3bb8c0e24050863e80faa1a4b97b506abfa4936a3dac5507085d9dcb09fe63d
TREASURY_CAP_ID = <This has to be created every time>
COIN_INFO_ID = <This has to be created every time>
TOKEN_COIN_ID = <This has to be created every time>
AMOUNT = 100000000 # 100 tokens assuming 6 decimals

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
create-coin-br:
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
			"" \
		--gas-budget 100000000
# public entry fun create_default_battle_royale(
#     launchpad: &token_launcher::Launchpad,
#     name: String,
#     description: String,
#     start_time: u64,
#     end_time: u64,
#     initial_prize: Coin<SUI>,
#     ctx: &mut TxContext,
# )

create-br:
	@sui client call \
		--package $(PACKAGE_ID) \
		--module battle_royale \
		--function create_default_battle_royale \
		--type-args $(COIN_TYPE) \
		--args \
			$(LAUNCHPAD_ID) \
			$(PAYMENT_COIN_ID) \
			"name" \
			"desc" \
			"starttime" \
			"endtime" \
			$(AMOUNT) \
			"" \
		--gas-budget 100000000
upgrade:
	@sui client upgrade \
		--upgrade-capability $(UPGRADE_CAP_ID) 
		