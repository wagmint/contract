#[test_only]
module wagmint::coin_manager_tests;

use std::string::{Self, String};
use sui::coin::{Self, CoinMetadata, TreasuryCap};
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario};
use sui::test_utils::assert_eq;
use wagmint::bonding_curve;
use wagmint::coin_manager::{Self, CoinInfo};
use wagmint::test_coin::{TEST_COIN, create_test_token_for_testing};
use wagmint::token_launcher::{Self, Launchpad, LaunchedCoinsRegistry};

// Test addresses
const ADMIN: address = @0xAD;
const USER: address = @0xB0B;

// Constants
const BPS_DENOMINATOR: u64 = 10000;
const PLATFORM_FEE_BPS: u64 = 100; // 1%

// Helper function to check if validation passes
fun check_metadata_validation(name: String, symbol: String): bool {
    coin_manager::validate_inputs(name, symbol)
}

#[test]
fun test_init() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);
    test_scenario::end(scenario);
}

fun test_init_internal(scenario: &mut Scenario) {
    // Call init function
    test_scenario::next_tx(scenario, ADMIN);
    {
        create_test_token_for_testing(test_scenario::ctx(scenario));
    };

    // Verify test token is created with correct metadata
    test_scenario::next_tx(scenario, ADMIN);
    {
        let treasury_cap = test_scenario::take_from_address<TreasuryCap<TEST_COIN>>(
            scenario,
            ADMIN,
        );
        let metadata = test_scenario::take_from_address<CoinMetadata<TEST_COIN>>(scenario, ADMIN);

        test_scenario::return_to_sender(scenario, treasury_cap);
        test_scenario::return_to_sender(scenario, metadata);
    };
}

// Test fee calculation
#[test]
fun test_calculate_transaction_fee() {
    // 1% of 1000 = 10
    assert_eq(
        coin_manager::calculate_transaction_fee(1000, PLATFORM_FEE_BPS),
        10,
    );

    // 1% of 0 = 0
    assert_eq(
        coin_manager::calculate_transaction_fee(0, PLATFORM_FEE_BPS),
        0,
    );

    // 1% of 12345 = 123.45 = 123 (integer division)
    assert_eq(
        coin_manager::calculate_transaction_fee(12345, PLATFORM_FEE_BPS),
        123,
    );
}

// Test name and symbol validation
#[test]
fun test_metadata_validation() {
    // Should pass with valid metadata
    let valid_name = string::utf8(b"Test Coin");
    let valid_symbol = string::utf8(b"TEST");

    // Use validation check
    assert!(check_metadata_validation(valid_name, valid_symbol), 0);

    // Test invalid name (empty)
    let invalid_name = string::utf8(b"");
    let valid_symbol = string::utf8(b"TEST");

    // Should fail with empty name
    assert!(!check_metadata_validation(invalid_name, valid_symbol), 1);
}

// Helper struct to store addresses between transactions
public struct AddressHolder has key, store {
    id: UID,
    addr: address,
}

#[test]
fun test_create_coin() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Setup launchpad
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        token_launcher::create_launchpad_for_testing(test_scenario::ctx(&mut scenario));
    };

    // Create a coin
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // First make sure we have the launchpad and registry created from init
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let mut registry = test_scenario::take_shared<LaunchedCoinsRegistry>(&scenario);
        let treasury_cap = test_scenario::take_from_address<TreasuryCap<TEST_COIN>>(
            &scenario,
            ADMIN,
        );

        // Generate 10 SUI for payment
        let payment = coin::mint_for_testing<SUI>(
            10_000_000_000,
            test_scenario::ctx(&mut scenario),
        );

        // Call the create_coin function with the test coin
        let coin_address = coin_manager::create_coin<TEST_COIN>(
            &mut launchpad,
            treasury_cap,
            &mut registry,
            payment,
            string::utf8(b"Test Coin"),
            string::utf8(b"TST"),
            string::utf8(b"A test coin for unit testing"),
            string::utf8(b"https://example.com"),
            string::utf8(b"https://example.com/image.png"),
            test_scenario::ctx(&mut scenario),
        );

        // Return shared objects
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(registry);

        // Save the coin_address for verification in next tx
        // Create a dummy object to store the address
        let address_wrapper = AddressHolder {
            id: object::new(test_scenario::ctx(&mut scenario)),
            addr: coin_address,
        };
        transfer::transfer(address_wrapper, ADMIN);
    };

    // Verify the coin was created correctly
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take the saved address from the holder object
        let address_holder = test_scenario::take_from_sender<AddressHolder>(&scenario);
        let coin_address = address_holder.addr;

        // Take the shared objects
        let launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let registry = test_scenario::take_shared<LaunchedCoinsRegistry>(&scenario);

        // Retrieve the created coin info
        let coin_info = test_scenario::take_shared_by_id<CoinInfo<TEST_COIN>>(
            &scenario,
            object::id_from_address(coin_address),
        );

        // Verify basic properties
        assert_eq(coin_manager::get_name(&coin_info), string::utf8(b"Test Coin"));
        assert_eq(coin_manager::get_symbol(&coin_info), string::utf8(b"TST"));
        assert_eq(coin_manager::get_creator(&coin_info), ADMIN);

        // Check initial state of the coin
        assert_eq(coin_manager::get_supply(&coin_info), 0); // No tokens in circulation yet
        assert_eq(coin_manager::get_real_sui_reserves(&coin_info), 0); // No real SUI reserves yet

        // Check virtual reserves
        let initial_virtual_sui = token_launcher::get_initial_virtual_sui(&launchpad);
        let initial_virtual_tokens = token_launcher::get_initial_virtual_tokens(&launchpad);

        assert_eq(coin_manager::get_virtual_sui_reserves(&coin_info), initial_virtual_sui);
        assert_eq(coin_manager::get_virtual_token_reserves(&coin_info), initial_virtual_tokens);

        // Verify real token reserves (all initially held by bonding curve)
        assert_eq(coin_manager::get_real_token_reserves(&coin_info), initial_virtual_tokens);

        // Verify token decimals
        assert_eq(
            coin_manager::get_token_decimals(&coin_info),
            token_launcher::get_token_decimals(&launchpad),
        );

        // Verify graduation state
        assert_eq(coin_manager::has_graduated(&coin_info), false);

        // Verify launchpad and registry were updated
        assert_eq(token_launcher::get_launched_coins_count(&launchpad), 1);
        assert_eq(vector::length(&token_launcher::get_launched_coins(&registry)), 1);

        // Return shared objects
        test_scenario::return_shared(coin_info);
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(registry);
        test_scenario::return_to_sender(&scenario, address_holder);
    };

    // Test buying tokens
    test_scenario::next_tx(&mut scenario, USER);
    {
        // Create a payment coin with sufficient funds
        let mut payment = coin::mint_for_testing<SUI>(
            10_000_000_000,
            test_scenario::ctx(&mut scenario),
        );

        // Take the saved address from the holder object
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let coin_address = address_holder.addr;

        // Take the shared objects
        let launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let mut coin_info = test_scenario::take_shared_by_id<CoinInfo<TEST_COIN>>(
            &scenario,
            object::id_from_address(coin_address),
        );

        // Record initial state
        let initial_supply = coin_manager::get_supply(&coin_info);
        let initial_sui_reserves = coin_manager::get_real_sui_reserves(&coin_info);
        let initial_virtual_sui = coin_manager::get_virtual_sui_reserves(&coin_info);
        let initial_virtual_tokens = coin_manager::get_virtual_token_reserves(&coin_info);

        // Buy some tokens
        let sui_amount = 1_000_000_000; // 1 SUI

        coin_manager::buy_tokens<TEST_COIN>(
            &launchpad,
            &mut coin_info,
            &mut payment,
            sui_amount,
            test_scenario::ctx(&mut scenario),
        );

        // Verify state changes
        let new_supply = coin_manager::get_supply(&coin_info);
        let new_sui_reserves = coin_manager::get_real_sui_reserves(&coin_info);
        let new_virtual_sui = coin_manager::get_virtual_sui_reserves(&coin_info);
        let new_virtual_tokens = coin_manager::get_virtual_token_reserves(&coin_info);

        // Supply should have increased
        assert!(new_supply > initial_supply, 0);

        // Real SUI reserves should have increased (minus platform fee)
        let platform_fee = token_launcher::get_platform_fee(&launchpad);
        let fee = (sui_amount * platform_fee) / BPS_DENOMINATOR;
        let expected_sui_increase = sui_amount - fee;

        assert_eq(new_sui_reserves, initial_sui_reserves + expected_sui_increase);

        // Virtual SUI should have increased by the full sui_amount
        assert_eq(new_virtual_sui, initial_virtual_sui + sui_amount);

        // Virtual tokens should have decreased
        assert!(new_virtual_tokens < initial_virtual_tokens, 3);

        // Return objects
        test_scenario::return_shared(coin_info);
        test_scenario::return_shared(launchpad);
        test_scenario::return_to_address(ADMIN, address_holder);
        coin::burn_for_testing(payment);
    };

    // Test selling tokens
    test_scenario::next_tx(&mut scenario, USER);
    {
        // Take the saved address from the holder object
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let coin_address = address_holder.addr;

        // Find out how many TEST_COIN tokens the user has
        // We need to get the TEST_COIN balance for the user
        let mut my_tokens = test_scenario::take_from_sender<coin::Coin<TEST_COIN>>(&scenario);
        let token_amount = coin::value(&my_tokens);

        // Take the shared objects
        let launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let mut coin_info = test_scenario::take_shared_by_id<CoinInfo<TEST_COIN>>(
            &scenario,
            object::id_from_address(coin_address),
        );

        // Record initial state
        let initial_supply = coin_manager::get_supply(&coin_info);
        let initial_sui_reserves = coin_manager::get_real_sui_reserves(&coin_info);
        let initial_virtual_sui = coin_manager::get_virtual_sui_reserves(&coin_info);
        let initial_virtual_tokens = coin_manager::get_virtual_token_reserves(&coin_info);

        // Sell some tokens (half of what we have)
        let amount_to_sell = token_amount / 2;
        let tokens_to_sell = coin::split(
            &mut my_tokens,
            amount_to_sell,
            test_scenario::ctx(&mut scenario),
        );

        coin_manager::sell_tokens<TEST_COIN>(
            &launchpad,
            &mut coin_info,
            tokens_to_sell,
            test_scenario::ctx(&mut scenario),
        );

        // Verify state changes
        let new_supply = coin_manager::get_supply(&coin_info);
        let new_sui_reserves = coin_manager::get_real_sui_reserves(&coin_info);
        let new_virtual_sui = coin_manager::get_virtual_sui_reserves(&coin_info);
        let new_virtual_tokens = coin_manager::get_virtual_token_reserves(&coin_info);

        // Supply should have decreased
        assert_eq(new_supply, initial_supply - amount_to_sell);

        // Real SUI reserves should have decreased
        assert!(new_sui_reserves < initial_sui_reserves, 1);

        // Virtual SUI should have decreased
        assert!(new_virtual_sui < initial_virtual_sui, 2);

        // Virtual tokens should have increased
        assert_eq(new_virtual_tokens, initial_virtual_tokens + amount_to_sell);

        // Return objects
        test_scenario::return_shared(coin_info);
        test_scenario::return_shared(launchpad);
        test_scenario::return_to_address(ADMIN, address_holder);
        test_scenario::return_to_sender(&scenario, my_tokens);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let address_holder = test_scenario::take_from_sender<AddressHolder>(&scenario);
        let AddressHolder { id, addr: _ } = address_holder;
        object::delete(id);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_price_calculation() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Setup launchpad
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        token_launcher::create_launchpad_for_testing(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let launchpad = test_scenario::take_shared<Launchpad>(&scenario);

        // Get initial virtual reserves from config
        let initial_virtual_sui = token_launcher::get_initial_virtual_sui(&launchpad);
        let initial_virtual_tokens = token_launcher::get_initial_virtual_tokens(&launchpad);

        // Calculate price with initial virtual reserves
        let initial_price = bonding_curve::calculate_price(
            initial_virtual_sui,
            initial_virtual_tokens,
        );

        // Simulate buying tokens (add to virtual SUI, decrease virtual tokens)
        let sui_amount = 1_000_000_000; // 1 SUI
        let tokens_to_mint = bonding_curve::calculate_tokens_to_mint(
            initial_virtual_sui,
            initial_virtual_tokens,
            sui_amount,
        );

        let new_virtual_sui = initial_virtual_sui + sui_amount;
        let new_virtual_tokens = initial_virtual_tokens - tokens_to_mint;

        // Calculate new price
        let new_price = bonding_curve::calculate_price(new_virtual_sui, new_virtual_tokens);

        // Price should increase after buying
        assert!(new_price > initial_price, 0);

        // Simulate selling tokens (decrease virtual SUI, increase virtual tokens)
        let token_amount = tokens_to_mint / 2; // Sell half of what we bought
        let sui_return = bonding_curve::calculate_sale_return(
            new_virtual_sui,
            new_virtual_tokens,
            token_amount,
        );

        let final_virtual_sui = new_virtual_sui - sui_return;
        let final_virtual_tokens = new_virtual_tokens + token_amount;

        // Calculate final price
        let final_price = bonding_curve::calculate_price(final_virtual_sui, final_virtual_tokens);

        // Price should decrease after selling
        assert!(final_price < new_price, 1);

        test_scenario::return_shared(launchpad);
    };

    test_scenario::end(scenario);
}
