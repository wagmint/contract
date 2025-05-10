module wagmint::token_launcher_tests;

use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario};
use sui::test_utils::assert_eq;
use wagmint::token_launcher::{Self, Launchpad, LaunchedCoinsRegistry};

// Test addresses
const ADMIN: address = @0xAD;
const USER: address = @0xB0B;
const NEW_ADMIN: address = @0xCA1;

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
        token_launcher::create_launchpad_for_testing(test_scenario::ctx(scenario));
    };

    // Verify launchpad is created with correct admin
    test_scenario::next_tx(scenario, ADMIN);
    {
        let launchpad = test_scenario::take_shared<Launchpad>(scenario);
        let registry = test_scenario::take_shared<LaunchedCoinsRegistry>(scenario);

        assert_eq(token_launcher::get_admin(&launchpad), ADMIN);
        assert_eq(token_launcher::get_launched_coins_count(&launchpad), 0);
        assert_eq(token_launcher::get_version(&launchpad), 1);
        assert_eq(token_launcher::get_platform_fee(&launchpad), 100); // 1%
        assert_eq(token_launcher::get_creation_fee(&launchpad), 10_000_000); // 0.01 SUI
        assert_eq(token_launcher::get_graduation_fee(&launchpad), 300_000_000_000); // 300 SUI
        assert_eq(token_launcher::get_initial_virtual_sui(&launchpad), 2_500_000_000_000); // 2500 SUI
        assert_eq(token_launcher::get_initial_virtual_tokens(&launchpad), 1_000_000_000_000_000); // 1B tokens
        assert_eq(token_launcher::get_token_decimals(&launchpad), 6);
        assert_eq(vector::length(&token_launcher::get_launched_coins(&registry)), 0);
        let treasury = token_launcher::get_treasury(&launchpad);
        let treasury_value = treasury.value();
        assert_eq(treasury_value, 0);

        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(registry);
    };
}

#[test]
fun test_update_admin() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Call and verify update_launchpad_admin function
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        token_launcher::update_launchpad_admin(
            &mut launchpad,
            NEW_ADMIN,
            test_scenario::ctx(&mut scenario),
        );
        assert_eq(token_launcher::get_admin(&launchpad), NEW_ADMIN);
        test_scenario::return_shared(launchpad);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_withdraw_treasury() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // add some SUI to the treasury
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let payment = coin::mint_for_testing<sui::sui::SUI>(
            100_000_000_000,
            test_scenario::ctx(&mut scenario),
        );
        let payment_balance = coin::into_balance(payment);
        token_launcher::add_to_treasury(&mut launchpad, payment_balance);
        test_scenario::return_shared(launchpad);
    };

    // Call and verify withdraw_treasury function
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        token_launcher::withdraw_treasury(
            &mut launchpad,
            25_000_000_000, // 25 SUI
            ADMIN,
            test_scenario::ctx(&mut scenario),
        );
        let treasury = token_launcher::get_treasury(&launchpad);
        let treasury_value = treasury.value();
        assert_eq(treasury_value, 75_000_000_000); // 75 SUI
        test_scenario::return_shared(launchpad);
    };

    // Verify ADMIN received the payment
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take the SUI coin from ADMIN's account
        let coin = test_scenario::take_from_address<Coin<SUI>>(&scenario, ADMIN);

        // Verify the amount
        assert_eq(coin::value(&coin), 25_000_000_000);

        // Return the coin
        test_scenario::return_to_address(ADMIN, coin);
    };

    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        token_launcher::withdraw_all_treasury(
            &mut launchpad,
            NEW_ADMIN,
            test_scenario::ctx(&mut scenario),
        );
        let treasury = token_launcher::get_treasury(&launchpad);
        let treasury_value = treasury.value();
        assert_eq(treasury_value, 0);
        test_scenario::return_shared(launchpad);
    };

    // Verify NEW_ADMIN received the payment
    test_scenario::next_tx(&mut scenario, NEW_ADMIN);
    {
        // Take the SUI coin from NEW_ADMIN's account
        let coin = test_scenario::take_from_address<Coin<SUI>>(&scenario, NEW_ADMIN);

        // Verify the amount
        assert_eq(coin::value(&coin), 75_000_000_000);

        // Return the coin
        test_scenario::return_to_address(NEW_ADMIN, coin);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_update_config() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Call and verify update_launchpad_config function
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        token_launcher::update_launchpad_config(
            &mut launchpad,
            2, // version
            200, // platform_fee
            20_000_000, // creation_fee
            400_000_000_000, // graduation_fee
            3_000_000_000_000, // initial_virtual_sui
            2_000_000_000_000_000, // initial_virtual_tokens
            9, // token_decimals
            test_scenario::ctx(&mut scenario),
        );
        assert_eq(token_launcher::get_version(&launchpad), 2);
        assert_eq(token_launcher::get_platform_fee(&launchpad), 200);
        assert_eq(token_launcher::get_creation_fee(&launchpad), 20_000_000);
        assert_eq(token_launcher::get_graduation_fee(&launchpad), 400_000_000_000);
        assert_eq(token_launcher::get_initial_virtual_sui(&launchpad), 3_000_000_000_000);
        assert_eq(token_launcher::get_initial_virtual_tokens(&launchpad), 2_000_000_000_000_000);
        assert_eq(token_launcher::get_token_decimals(&launchpad), 9);
        test_scenario::return_shared(launchpad);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // E_NOT_ADMIN
fun test_update_config_by_non_admin() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        token_launcher::update_launchpad_config(
            &mut launchpad,
            2, // version
            200, // platform_fee
            20_000_000, // creation_fee
            400_000_000_000, // graduation_fee
            3_000_000_000_000, // initial_virtual_sui
            2_000_000_000_000_000, // initial_virtual_tokens
            9, // token_decimals
            test_scenario::ctx(&mut scenario),
        );
        test_scenario::return_shared(launchpad);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = 0)] // E_NOT_ADMIN
fun test_update_admin_by_non_admin() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    test_scenario::next_tx(&mut scenario, USER);
    {
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        token_launcher::update_launchpad_admin(
            &mut launchpad,
            NEW_ADMIN,
            test_scenario::ctx(&mut scenario),
        );
        test_scenario::return_shared(launchpad);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_increment_coins_count() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Initialize first
    test_init_internal(&mut scenario);

    // Increment count
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        token_launcher::increment_coins_count(&mut launchpad);
        assert_eq(token_launcher::get_launched_coins_count(&launchpad), 1);
        test_scenario::return_shared(launchpad);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_add_to_registry() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Initialize first
    test_init_internal(&mut scenario);

    let test_addr = @0xCAFE;

    // Add coin to registry
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = test_scenario::take_shared<LaunchedCoinsRegistry>(&scenario);
        token_launcher::add_to_registry(&mut registry, test_addr);
        let coins = token_launcher::get_launched_coins(&registry);
        assert_eq(vector::length(&coins), 1);
        assert_eq(*vector::borrow(&coins, 0), test_addr);
        test_scenario::return_shared(registry);
    };

    test_scenario::end(scenario);
}
