module wagmint::bonding_curve_tests;

use std::debug;
use wagmint::bonding_curve;

// Test error codes
const E_WRONG_PRICE: u64 = 100;
const E_WRONG_PURCHASE_COST: u64 = 101;
const E_WRONG_SALE_RETURN: u64 = 102;

#[test]
fun test_calculate_price() {
    // test with zero supply
    assert!(bonding_curve::calculate_price(0) == 0, E_WRONG_PRICE);
    // test with larger supply
    assert!(bonding_curve::calculate_price(2000) == 2, E_WRONG_PRICE);
}

#[test]
fun test_calculate_purchase_cost() {
    let current_supply = 1000;
    let amount = 100;
    let cost = bonding_curve::calculate_purchase_cost(current_supply, amount);

    assert!(cost == 55, E_WRONG_PURCHASE_COST);
}

#[test]
fun test_calculate_sale_return() {
    let current_supply = 1000;
    let amount = 100;
    let return_amount = bonding_curve::calculate_sale_return(current_supply, amount);

    // Return should be slightly less than purchase cost due to price impact
    assert!(return_amount == 45, E_WRONG_SALE_RETURN);
}

#[test]
#[expected_failure(abort_code = bonding_curve::E_ZERO_SUPPLY)]
fun test_sale_return_amount_exceeds_supply() {
    bonding_curve::calculate_sale_return(100, 200);
}

#[test]
fun test_purchase_and_sale_same_amount() {
    let initial_supply = 1000;
    let amount = 100;

    let purchase_cost = bonding_curve::calculate_purchase_cost(initial_supply, amount);
    let sale_return = bonding_curve::calculate_sale_return(initial_supply + amount, amount);

    debug::print(&purchase_cost);
    debug::print(&sale_return);

    // Both should be 55
    assert!(purchase_cost == 55, E_WRONG_PURCHASE_COST);
    assert!(sale_return == 55, E_WRONG_SALE_RETURN);
    // They should be equal
    assert!(sale_return == purchase_cost, E_WRONG_SALE_RETURN);
}

#[test]
fun test_price_increases_with_supply() {
    let price1 = bonding_curve::calculate_price(1000);
    let price2 = bonding_curve::calculate_price(2000);

    assert!(price2 > price1, E_WRONG_PRICE);
    assert!(price1 == 0, E_WRONG_PRICE);
    assert!(price2 == 2, E_WRONG_PRICE);
}
