module wagmint::bonding_curve;

use wagmint::utils;

// Error codes
const E_ZERO_SUPPLY: u64 = 0;

// Calculate the constant product K
public fun calculate_constant_product(initial_virtual_sui: u64, initial_virtual_tokens: u64): u128 {
    utils::mul(
        utils::from_u64(initial_virtual_sui),
        utils::from_u64(initial_virtual_tokens),
    )
}

// Calculate token price at current supply based on virtual reserves
public fun calculate_price(virtual_sui_reserves: u64, virtual_token_reserves: u64): u64 {
    // Calculate price using derivative of constant product formula: price = virtual_sui / virtual_token
    // This is effectively the spot price at the current point on the curve
    if (virtual_token_reserves == 0) {
        return 0
    };

    utils::as_u64(
        utils::div(
            utils::from_u64(virtual_sui_reserves),
            utils::from_u64(virtual_token_reserves),
        ),
    )
}

// Calculate the amount of tokens to mint when given SUI (buying tokens)
public fun calculate_tokens_to_mint(
    virtual_sui_reserves: u64,
    virtual_token_reserves: u64,
    sui_amount: u64,
): u64 {
    let k = utils::mul(
        utils::from_u64(virtual_sui_reserves),
        utils::from_u64(virtual_token_reserves),
    );

    let new_virtual_sui = utils::add(
        utils::from_u64(virtual_sui_reserves),
        utils::from_u64(sui_amount),
    );

    let new_virtual_tokens = utils::div(k, new_virtual_sui);

    utils::as_u64(
        utils::sub(
            utils::from_u64(virtual_token_reserves),
            new_virtual_tokens,
        ),
    )
}

// Calculate SUI to return when selling tokens
public fun calculate_sale_return(
    virtual_sui_reserves: u64,
    virtual_token_reserves: u64,
    token_amount: u64,
): u64 {
    // Make sure we have enough token reserves
    assert!(virtual_token_reserves >= token_amount, E_ZERO_SUPPLY);

    let new_virtual_tokens = utils::add(
        utils::from_u64(virtual_token_reserves),
        utils::from_u64(token_amount),
    );

    let k = utils::mul(
        utils::from_u64(virtual_sui_reserves),
        utils::from_u64(virtual_token_reserves),
    );

    let new_virtual_sui = utils::div(k, new_virtual_tokens);

    utils::as_u64(
        utils::sub(
            utils::from_u64(virtual_sui_reserves),
            new_virtual_sui,
        ),
    )
}

// Check if token has reached graduation threshold
public fun has_reached_graduation_threshold(
    virtual_sui_reserves: u64,
    graduation_threshold: u64,
): bool {
    virtual_sui_reserves >= graduation_threshold
}
