module wagmint::token_launcher_tests;

use sui::test_scenario::{Self, Scenario};
use wagmint::token_launcher::{Self, Launchpad, LaunchedCoinsRegistry};

// Test addresses
const ADMIN: address = @0xAD;
const USER: address = @0xB0B;
const NEW_ADMIN: address = @0xCA1;

#[test]
fun test_init() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);
    scenario.end();
}

fun test_init_internal(scenario: &mut Scenario) {
    // Call init function
    scenario.next_tx(ADMIN);
    {
        token_launcher::create_launchpad_for_testing(scenario.ctx());
    };

    // Verify launchpad is created with correct admin
    scenario.next_tx(ADMIN);
    {
        let launchpad = scenario.take_shared<Launchpad>();
        let registry = scenario.take_shared<LaunchedCoinsRegistry>();

        assert!(token_launcher::get_admin(&launchpad) == ADMIN, 0);
        assert!(token_launcher::launched_coins_count(&launchpad) == 0, 1);
        assert!(token_launcher::get_version(&launchpad) == 1, 2);
        assert!(token_launcher::get_platform_fee(&launchpad) == 100, 3);
        assert!(token_launcher::get_creation_fee(&launchpad) == 1_000_000_000, 4);
        assert!(token_launcher::get_graduation_fee(&launchpad) == 0, 5);
        assert!(vector::length(&token_launcher::get_launched_coins(&registry)) == 0, 2);

        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(registry);
    };
}

#[test]
fun test_update_admin() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Call and verify update_launchpad_admin function
    scenario.next_tx(ADMIN);
    {
        let mut launchpad = scenario.take_shared<Launchpad>();
        token_launcher::update_launchpad_admin(
            &mut launchpad,
            NEW_ADMIN,
            scenario.ctx(),
        );
        assert!(token_launcher::get_admin(&launchpad) == NEW_ADMIN, 0);
        test_scenario::return_shared(launchpad);
    };

    scenario.end();
}

#[test]
fun test_update_config() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Call and verify update_launchpad_config function
    scenario.next_tx(ADMIN);
    {
        let mut launchpad = scenario.take_shared<Launchpad>();
        token_launcher::update_launchpad_config(
            &mut launchpad,
            2,
            200,
            2_000_000_000,
            1_000_000_000,
            scenario.ctx(),
        );
        assert!(token_launcher::get_version(&launchpad) == 2, 0);
        assert!(token_launcher::get_platform_fee(&launchpad) == 200, 1);
        assert!(token_launcher::get_creation_fee(&launchpad) == 2_000_000_000, 2);
        assert!(token_launcher::get_graduation_fee(&launchpad) == 1_000_000_000, 3);
        test_scenario::return_shared(launchpad);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = token_launcher::E_NOT_ADMIN)]
fun test_update_config_by_non_admin() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    scenario.next_tx(USER);
    {
        let mut launchpad = scenario.take_shared<Launchpad>();
        token_launcher::update_launchpad_config(
            &mut launchpad,
            200,
            2_000_000_000,
            1_000_000_000,
            0,
            scenario.ctx(),
        );
        test_scenario::return_shared(launchpad);
    };

    scenario.end();
}

#[test]
#[expected_failure(abort_code = token_launcher::E_NOT_ADMIN)]
fun test_update_admin_by_non_admin() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    scenario.next_tx(USER);
    {
        let mut launchpad = scenario.take_shared<Launchpad>();
        token_launcher::update_launchpad_admin(
            &mut launchpad,
            NEW_ADMIN,
            scenario.ctx(),
        );
        test_scenario::return_shared(launchpad);
    };

    scenario.end();
}

#[test]
fun test_increment_coins_count() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Initialize first
    test_init_internal(&mut scenario);

    // Increment count
    scenario.next_tx(ADMIN);
    {
        let mut launchpad = scenario.take_shared<Launchpad>();
        token_launcher::increment_coins_count(&mut launchpad);
        assert!(token_launcher::launched_coins_count(&launchpad) == 1, 0);
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
    scenario.next_tx(ADMIN);
    {
        let mut registry = scenario.take_shared<LaunchedCoinsRegistry>();
        token_launcher::add_to_registry(&mut registry, test_addr);
        let coins = token_launcher::get_launched_coins(&registry);
        assert!(vector::length(&coins) == 1, 0);
        assert!(*vector::borrow(&coins, 0) == test_addr, 1);
        test_scenario::return_shared(registry);
    };

    test_scenario::end(scenario);
}
