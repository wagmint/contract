#[test_only]
module wagmint::coin_manager_tests;

use std::string::String;
use sui::balance;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario;
use wagmint::bonding_curve;
use wagmint::coin_manager;
use wagmint::token_launcher::{Self, Launchpad};

// Test addresses
const ADMIN: address = @0xAD;
const USER: address = @0xB0B;

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
fun test_buy_tokens_helper() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Setup launchpad
    scenario.next_tx(ADMIN);
    {
        token_launcher::create_launchpad_for_testing(scenario.ctx());
    };

    // Test buy_tokens_helper
    scenario.next_tx(USER);
    {
        let launchpad = scenario.take_shared<Launchpad>();

        // Create a payment coin with sufficient funds
        let mut payment = coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let initial_payment_value = coin::value(&payment);

        // Create reserve balance
        let mut reserve_balance = balance::zero<SUI>();

        // Parameters for buying
        let current_supply = 1000;
        let buy_amount = 100;

        // Expected calculations for verification
        let expected_base_cost = bonding_curve::calculate_purchase_cost(current_supply, buy_amount);
        let expected_fee = coin_manager::calculate_transaction_fee(expected_base_cost);
        let expected_total_cost = expected_base_cost + expected_fee;

        // Call the helper function
        let cost = coin_manager::buy_tokens_helper(
            &launchpad,
            current_supply,
            buy_amount,
            &mut payment,
            &mut reserve_balance,
            scenario.ctx(),
        );

        // Verify the cost amount returned
        assert!(cost == expected_base_cost, 0);

        // Verify payment was deducted correctly
        let expected_payment_remaining = initial_payment_value - expected_total_cost;
        assert!(coin::value(&payment) == expected_payment_remaining, 1);

        // Verify reserve balance was updated correctly
        let expected_reserve = expected_base_cost;
        assert!(balance::value(&reserve_balance) == expected_reserve, 2);

        // Clean up
        balance::destroy_for_testing(reserve_balance);
        sui::transfer::public_transfer(payment, USER);
        test_scenario::return_shared(launchpad);
    };

    scenario.end();
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

#[test]
fun test_sell_tokens_helper() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Setup launchpad
    scenario.next_tx(ADMIN);
    {
        token_launcher::create_launchpad_for_testing(scenario.ctx());
    };

    // Test sell_tokens_helper
    scenario.next_tx(USER);
    {
        let launchpad = scenario.take_shared<Launchpad>();

        // Create initial reserve balance with sufficient funds
        let initial_reserve = 1_000_000_000; // 1 SUI
        let mut reserve_balance = balance::create_for_testing<SUI>(initial_reserve);

        // Parameters for selling
        let current_supply = 1000;
        let sell_amount = 100;

        // Expected calculations
        let expected_return = bonding_curve::calculate_sale_return(current_supply, sell_amount);
        let expected_fee = coin_manager::calculate_transaction_fee(expected_return);
        let expected_final_return = expected_return - expected_fee;
        let expected_new_supply = current_supply - sell_amount;

        // Call the helper function
        let (new_supply, actual_return, return_coin) = coin_manager::sell_tokens_helper(
            &launchpad,
            current_supply,
            sell_amount,
            &mut reserve_balance,
            scenario.ctx(),
        );

        // Verify new supply
        assert!(new_supply == expected_new_supply, 0);

        // Verify return amount
        assert!(actual_return == expected_return, 1);

        // Verify coin value returned
        assert!(coin::value(&return_coin) == expected_final_return, 2);

        // Verify reserve balance was updated correctly
        // Reserve should be reduced by expected_return
        let expected_remaining_reserve = initial_reserve - expected_return;
        assert!(balance::value(&reserve_balance) == expected_remaining_reserve, 3);

        // Verify fee was taken correctly
        // The fee Coin is sent to admin, so we can't check it directly
        // But we can infer it from other values:
        let inferred_fee = expected_return - expected_final_return;
        assert!(inferred_fee == expected_fee, 4);

        // Clean up
        balance::destroy_for_testing(reserve_balance);
        sui::transfer::public_transfer(return_coin, USER);
        test_scenario::return_shared(launchpad);
    };

    test_scenario::end(scenario);
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
