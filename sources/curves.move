module wagmint::curves;

use wagmint::utils;

/// Calculate the current price based on virtual reserves
/// Uses constant product formula (x * y = k)
public fun calculate_price(sui_reserves: u64, token_reserves: u64): u64 {
    // Handle potential division by zero
    if (token_reserves == 0) return 0;

    // Price is determined by ratio of SUI to tokens
    // Using utils to handle large number calculations
    utils::as_u64(
        utils::div(
            utils::from_u64(sui_reserves),
            utils::from_u64(token_reserves),
        ),
    )
}

/// Calculate cost in SUI to purchase a specific amount of tokens
/// This implements the constant product formula with slippage
public fun calculate_add_liquidity_cost(
    sui_reserves: u64,
    token_reserves: u64,
    token_amount: u64,
): u64 {
    // Handle edge cases
    if (token_amount == 0 || token_reserves == 0) return 0;

    // Calculate new token reserves after the addition
    let new_token_reserves = token_reserves - token_amount;

    // Target constant product (k) to maintain
    let target_k = utils::mul(
        utils::from_u64(sui_reserves),
        utils::from_u64(new_token_reserves),
    );

    // Calculate new SUI reserves needed to maintain k
    let new_sui_reserves = utils::as_u64(
        utils::div(
            target_k,
            utils::from_u64(new_token_reserves),
        ),
    );

    // Cost is the difference in SUI reserves
    if (new_sui_reserves <= sui_reserves) {
        // This shouldn't happen with normal token additions
        // but we handle edge cases defensively
        return 0;
    };
    new_sui_reserves - sui_reserves
}

/// Calculate SUI returned when selling tokens
/// Implements constant product formula with slippage
public fun calculate_remove_liquidity_return(
    token_reserves: u64,
    sui_reserves: u64,
    token_amount: u64,
): u64 {
    // Handle edge cases
    if (token_amount == 0 || token_reserves <= token_amount) return 0;

    // Calculate new token reserves after the sale
    let new_token_reserves = token_reserves + token_amount;

    // Target constant product (k) to maintain
    let k = utils::mul(
        utils::from_u64(sui_reserves),
        utils::from_u64(token_reserves),
    );

    // Calculate new SUI reserves that would maintain k
    let new_sui_reserves = utils::as_u64(
        utils::div(
            k,
            utils::from_u64(new_token_reserves),
        ),
    );

    // Return amount is the difference in SUI reserves
    if (new_sui_reserves >= sui_reserves) {
        // This shouldn't happen with normal sales
        // but we handle edge cases defensively
        return 0;
    };
    sui_reserves - new_sui_reserves
}

/// Calculate amount out based on exact input amount and reserves
/// This is a more general function that can be used for any token pair
public fun calculate_amount_out(amount_in: u64, reserve_in: u64, reserve_out: u64): u64 {
    // Handle edge cases
    if (amount_in == 0 || reserve_in == 0 || reserve_out == 0) return 0;

    // Calculate the amount out with slippage
    // formula: amount_out = (amount_in * reserve_out) / (reserve_in + amount_in)

    let amount_in_with_fee = utils::mul(
        utils::from_u64(amount_in),
        utils::from_u64(997), // 0.3% fee = 997/1000
    );

    let numerator = utils::mul(
        amount_in_with_fee,
        utils::from_u64(reserve_out),
    );

    let denominator = utils::add(
        utils::mul(utils::from_u64(reserve_in), utils::from_u64(1000)),
        amount_in_with_fee,
    );

    utils::as_u64(
        utils::div(
            numerator,
            denominator,
        ),
    )
}

/// Get the price impact percentage (basis points) for a given trade
/// Returns the price impact in basis points (1% = 100)
public fun calculate_price_impact(amount_in: u64, reserve_in: u64, reserve_out: u64): u64 {
    // Handle edge cases
    if (amount_in == 0 || reserve_in == 0) return 0;

    // Calculate what percentage of the reserve the trade represents
    // impact = (amount_in / reserve_in) * 10000 for basis points
    let impact = utils::div(
        utils::mul(
            utils::from_u64(amount_in),
            utils::from_u64(10000),
        ),
        utils::from_u64(reserve_in),
    );

    utils::as_u64(impact)
}

#[test]
public fun test_add_liquidity_cost() {
    // Initial reserves: 1000 SUI, 10000 tokens
    // Buy 1000 tokens
    let cost = calculate_add_liquidity_cost(1000, 10000, 1000);

    // Expected: approximately 111 SUI (with some precision loss)
    assert!(cost > 100 && cost < 120, 0);
}

#[test]
public fun test_remove_liquidity_return() {
    // Initial reserves: 1000 SUI, 10000 tokens
    // Sell 1000 tokens
    let sui_return = calculate_remove_liquidity_return(10000, 1000, 1000);

    // Expected: approximately 90-91 SUI (with some precision loss)
    assert!(sui_return > 80 && sui_return < 100, 0);
}
