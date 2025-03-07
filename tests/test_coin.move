module wagmint::test_coin;

use sui::coin;

public struct TEST_COIN has drop {}

// This is required for normal module init
fun init(witness: TEST_COIN, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        9, // decimals
        b"MyToken", // name
        b"MTK", // symbol
        b"My awesome test token", // description
        option::none(), // icon url
        ctx,
    );

    // Transfer treasury cap to the transaction sender
    transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    transfer::public_transfer(metadata, tx_context::sender(ctx));
}

// Add a test-only function to create a fresh witness for testing
#[test_only]
public fun get_witness(): TEST_COIN {
    TEST_COIN {}
}

#[test_only]
public(package) fun create_test_token_for_testing(ctx: &mut TxContext) {
    init(get_witness(), ctx);
}
