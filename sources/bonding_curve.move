module wagmint::bonding_curve;

use std::u64;

// Error codes
const E_ZERO_SUPPLY: u64 = 0;

// Constants for price calculation
const PRICE_COEFFICIENT: u64 = 2000000; // 2 * 10^6

public fun calculate_price(supply: u64): u64 {
    // Price = supply² / PRICE_COEFFICIENT
    let supply_squared = u64::pow(supply, 2);
    supply_squared / PRICE_COEFFICIENT
}

public fun calculate_purchase_cost(current_supply: u64, amount: u64): u64 {
    let new_supply = current_supply + amount;

    let new_supply_cubed = u64::pow(new_supply, 3);
    let current_supply_cubed = u64::pow(current_supply, 3);

    (new_supply_cubed - current_supply_cubed) / (3 * PRICE_COEFFICIENT)
}

public fun calculate_sale_return(current_supply: u64, amount: u64): u64 {
    assert!(current_supply >= amount, E_ZERO_SUPPLY);
    let new_supply = current_supply - amount;

    let current_supply_cubed = u64::pow(current_supply, 3);
    let new_supply_cubed = u64::pow(new_supply, 3);

    (current_supply_cubed - new_supply_cubed) / (3 * PRICE_COEFFICIENT)
}
