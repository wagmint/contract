module wagmint::bonding_curve;

use wagmint::utils;

// Error codes
const E_ZERO_SUPPLY: u64 = 0;

// Constants for price calculation
const PRICE_COEFFICIENT: u64 = 2000000; // 2 * 10^6

public fun calculate_price(supply: u64): u64 {
    // Price = supply² / PRICE_COEFFICIENT
    let supply_squared = utils::pow(utils::from_u64(supply), 2);
    utils::as_u64(
        utils::div(
            supply_squared,
            utils::from_u64(PRICE_COEFFICIENT),
        ),
    )
}

public fun calculate_purchase_cost(current_supply: u64, amount: u64): u64 {
    let new_supply = current_supply + amount;

    let new_supply_cubed = utils::pow(utils::from_u64(new_supply), 3);
    let current_supply_cubed = utils::pow(utils::from_u64(current_supply), 3);

    utils::as_u64(
        utils::div(
            utils::sub(new_supply_cubed, current_supply_cubed),
            utils::mul(3, utils::from_u64(PRICE_COEFFICIENT)),
        ),
    )
}

public fun calculate_sale_return(current_supply: u64, amount: u64): u64 {
    assert!(current_supply >= amount, E_ZERO_SUPPLY);
    let new_supply = utils::sub(utils::from_u64(current_supply), utils::from_u64(amount));

    let current_supply_cubed = utils::pow(utils::from_u64(current_supply), 3);
    let new_supply_cubed = utils::pow(new_supply, 3);

    utils::as_u64(
        utils::div(
            utils::sub(current_supply_cubed, new_supply_cubed),
            utils::mul(3, utils::from_u64(PRICE_COEFFICIENT)),
        ),
    )
}
