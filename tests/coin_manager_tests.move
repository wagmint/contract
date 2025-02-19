#[test_only]
module wagmint::coin_manager_tests;

use std::string::String;
use sui::balance;
use sui::sui::SUI;
use wagmint::bonding_curve;
use wagmint::coin_manager;

public struct TEST_DUMMY has drop {}

// Test error codes
const E_WRONG_FEE_CALCULATION: u64 = 100;
const E_WRONG_METADATA_VALIDATION: u64 = 101;

// Helper function to check if validation passes
fun check_metadata_validation(name: String, symbol: String): bool {
    // We'll wrap this call in a try-catch equivalent
    if (coin_manager::validate_inputs(name, symbol)) {
        return true
    } else {
        return false
    }
}

// Test fee calculation
#[test]
fun test_calculate_transaction_fee() {
    // 1% of 1000 = 10
    assert!(coin_manager::calculate_transaction_fee(1000) == 10, E_WRONG_FEE_CALCULATION);

    // 1% of 0 = 0
    assert!(coin_manager::calculate_transaction_fee(0) == 0, E_WRONG_FEE_CALCULATION);

    // 1% of 12345 = 123.45 = 123 (integer division)
    assert!(coin_manager::calculate_transaction_fee(12345) == 123, E_WRONG_FEE_CALCULATION);
}

// Test name and symbol validation
#[test]
fun test_metadata_validation() {
    // Should NOT abort with valid metadata
    let valid_name = b"Test Coin".to_string();
    let valid_symbol = b"TEST".to_string();

    // Use try-catch equivalent to test validation
    if (!check_metadata_validation(valid_name, valid_symbol)) {
        assert!(false, E_WRONG_METADATA_VALIDATION);
    };

    // Test invalid name (empty)
    let invalid_name = b"".to_string();
    let valid_symbol = b"TEST".to_string();

    // Should abort with empty name
    assert!(!check_metadata_validation(invalid_name, valid_symbol), E_WRONG_METADATA_VALIDATION);
}

#[test]
fun test_buy_token_calculations() {
    // Test scenario: Buy 100 tokens with current supply of 10000
    let current_supply = 10000;
    let buy_amount = 100;

    // Calculate base cost using bonding curve
    let base_cost = bonding_curve::calculate_purchase_cost(current_supply, buy_amount);
    // Calculate fee (1%)
    let fee = coin_manager::calculate_transaction_fee(base_cost);
    let total_cost = base_cost + fee;

    // Verify calculations
    assert!(base_cost > 0, 0);
    assert!(fee == base_cost / 100, 1); // 1% fee
    assert!(total_cost == base_cost + fee, 2);

    // Verify new price after purchase
    let new_supply = current_supply + buy_amount;
    let new_price = bonding_curve::calculate_price(new_supply);
    let old_price = bonding_curve::calculate_price(current_supply);

    assert!(new_price > old_price, 3); // Price should increase
}

// Test sell token logic
#[test]
fun test_sell_token_calculations() {
    // Test scenario: Sell 100 tokens with current supply of 11000
    let current_supply = 11000;
    let sell_amount = 100;

    // Calculate return amount using bonding curve
    let return_amount = bonding_curve::calculate_sale_return(current_supply, sell_amount);
    // Calculate fee
    let fee = coin_manager::calculate_transaction_fee(return_amount);
    let final_return = return_amount - fee;

    // Verify calculations
    assert!(return_amount > 0, 0);
    assert!(fee == return_amount / 100, 1); // 1% fee
    assert!(final_return == return_amount - fee, 2);
    assert!(final_return < return_amount, 3);

    // Verify new price after sale
    let new_supply = current_supply - sell_amount;
    let new_price = bonding_curve::calculate_price(new_supply);
    let old_price = bonding_curve::calculate_price(current_supply);
    assert!(new_price < old_price, 4); // Price should decrease
}

// Test reserve balance updates
#[test]
fun test_reserve_balance_operations() {
    // Create initial balance
    let mut reserve = balance::zero<SUI>();
    assert!(balance::value(&reserve) == 0, 0);

    // Simulate adding payment to reserve (buy operation)
    let payment = balance::create_for_testing<SUI>(1000);
    balance::join(&mut reserve, payment);
    assert!(balance::value(&reserve) == 1000, 1);

    // Simulate taking fee from reserve
    let fee = balance::split(&mut reserve, 10); // 1% fee
    assert!(balance::value(&fee) == 10, 2);
    assert!(balance::value(&reserve) == 990, 3);

    // Simulate paying seller (sell operation)
    let seller_payment = balance::split(&mut reserve, 500);
    assert!(balance::value(&seller_payment) == 500, 4);
    assert!(balance::value(&reserve) == 490, 5);

    // Clean up
    balance::destroy_for_testing(reserve);
    balance::destroy_for_testing(fee);
    balance::destroy_for_testing(seller_payment);
}

// Test buy/sell roundtrip
#[test]
fun test_buy_sell_roundtrip() {
    // Initial state
    let initial_supply = 10000;
    let amount = 100;

    // Buy calculation
    let buy_cost = bonding_curve::calculate_purchase_cost(initial_supply, amount);
    let buy_fee = coin_manager::calculate_transaction_fee(buy_cost);
    let total_buy_cost = buy_cost + buy_fee;

    // New state after buy
    let new_supply = initial_supply + amount;

    // Sell calculation (selling same amount)
    let sell_return = bonding_curve::calculate_sale_return(new_supply, amount);
    let sell_fee = coin_manager::calculate_transaction_fee(sell_return);
    let final_sell_return = sell_return - sell_fee;

    // In efficient markets, buy cost should be similar to sell return
    // But due to fees, seller receives less than buyer paid
    assert!(sell_return == buy_cost, 0); // Should be equal without fees
    assert!(final_sell_return < total_buy_cost, 1); // With fees, seller gets less

    // Calculate fees kept by platform
    let platform_revenue = total_buy_cost - final_sell_return;
    assert!(platform_revenue == buy_fee + sell_fee, 2);
}
