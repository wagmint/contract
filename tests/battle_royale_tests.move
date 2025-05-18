#[test_only]
module wagmint::battle_royale_tests;

use std::string;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario};
use sui::test_utils::assert_eq;
use wagmint::battle_royale::{Self, BattleRoyale, WinnerRegistry};
use wagmint::coin_manager::{Self, CoinInfo};
use wagmint::test_coin::{TEST_COIN, create_test_token_for_testing};
use wagmint::token_launcher::{Self, Launchpad, LaunchedCoinsRegistry};

// Test addresses
const ADMIN: address = @0xAD;
const USER1: address = @0xB0B;
const USER2: address = @0xAB1;
const USER3: address = @0xB2B;
const USER4: address = @0xB3B;

// Constants for BR configuration
const BR_NAME: vector<u8> = b"Test Battle Royale";
const BR_DESCRIPTION: vector<u8> = b"A test battle royale for unit testing";
const BR_START_TIME: u64 = 1; // epoch 0
const BR_END_TIME: u64 = 2; // epoch 1
const BR_PARTICIPATION_FEE: u64 = 5_000_000_000; // 5 SUI
const BR_FEE_BPS: u64 = 5000; // 50%
const BR_FIRST_PLACE_BPS: u64 = 5000; // 50%
const BR_SECOND_PLACE_BPS: u64 = 3000; // 30%
const BR_THIRD_PLACE_BPS: u64 = 2000; // 20%
const BR_PLATFORM_FEE_BPS: u64 = 0; // 0% for testing
const BR_MAX_COINS_PER_PARTICIPANT: u64 = 1;
const BR_MID_BATTLE_REGISTRATION_ENABLED: bool = true;

// Helper struct to store addresses between transactions
public struct AddressHolder has key, store {
    id: UID,
    br_address: address,
    coin1_address: address,
    coin2_address: address,
    coin3_address: address,
}

#[test]
fun test_create_battle_royale() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);
    test_scenario::end(scenario);
}

// Initialize the test environment with token_launcher and test tokens
fun test_init_internal(scenario: &mut Scenario) {
    // First create the test token
    test_scenario::next_tx(scenario, ADMIN);
    {
        create_test_token_for_testing(test_scenario::ctx(scenario));
    };

    // Setup token launcher
    test_scenario::next_tx(scenario, ADMIN);
    {
        token_launcher::create_launchpad_for_testing(test_scenario::ctx(scenario));
    };

    // Create a BR
    test_scenario::next_tx(scenario, ADMIN);
    {
        let launchpad = test_scenario::take_shared<Launchpad>(scenario);

        // Call create_battle_royale
        battle_royale::create_battle_royale(
            &launchpad,
            string::utf8(BR_NAME),
            string::utf8(BR_DESCRIPTION),
            BR_START_TIME,
            BR_END_TIME,
            BR_MAX_COINS_PER_PARTICIPANT,
            BR_MID_BATTLE_REGISTRATION_ENABLED,
            BR_PARTICIPATION_FEE,
            BR_FEE_BPS,
            BR_FIRST_PLACE_BPS,
            BR_SECOND_PLACE_BPS,
            BR_THIRD_PLACE_BPS,
            BR_PLATFORM_FEE_BPS,
            test_scenario::ctx(scenario),
        );

        test_scenario::return_shared(launchpad);
    };

    test_scenario::next_tx(scenario, ADMIN);
    {
        let launchpad = test_scenario::take_shared<Launchpad>(scenario);

        // Verify BR was created
        let br = test_scenario::take_shared<BattleRoyale>(scenario);
        let (
            name,
            description,
            admin,
            start_time,
            end_time,
            prize_pool,
            participation_fee,
            is_finalized,
            is_cancelled,
        ) = battle_royale::get_battle_royale_info(&br);

        // Verify basic properties
        assert_eq(name, string::utf8(BR_NAME));
        assert_eq(description, string::utf8(BR_DESCRIPTION));
        assert_eq(admin, ADMIN);
        assert_eq(start_time, BR_START_TIME);
        assert_eq(end_time, BR_END_TIME);
        assert_eq(prize_pool, 0);
        assert_eq(participation_fee, BR_PARTICIPATION_FEE);
        assert_eq(is_finalized, false);
        assert_eq(is_cancelled, false);

        // Verify prize distribution
        let (
            first_place_bps,
            second_place_bps,
            third_place_bps,
            platform_fee_bps,
        ) = battle_royale::get_prize_distribution(&br);
        assert_eq(first_place_bps, BR_FIRST_PLACE_BPS);
        assert_eq(second_place_bps, BR_SECOND_PLACE_BPS);
        assert_eq(third_place_bps, BR_THIRD_PLACE_BPS);
        assert_eq(platform_fee_bps, BR_PLATFORM_FEE_BPS);

        // Verify fee BPS
        assert_eq(battle_royale::get_br_fee_bps(&br), BR_FEE_BPS);

        // Save BR address for later use
        let br_address = battle_royale::test_get_battle_royale_address(&br);
        let address_holder = AddressHolder {
            id: object::new(test_scenario::ctx(scenario)),
            br_address,
            coin1_address: @0x0, // Will be filled later
            coin2_address: @0x0,
            coin3_address: @0x0,
        };
        transfer::transfer(address_holder, ADMIN);

        // Return shared objects
        test_scenario::return_shared(br);
        test_scenario::return_shared(launchpad);
    };
}

#[test]
fun test_participant_registration_and_coin_creation() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Register USER1 as a participant
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take the BR address from holder
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);

        // Take the BR
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Create payment for participation fee
        let payment = coin::mint_for_testing<SUI>(
            BR_PARTICIPATION_FEE,
            test_scenario::ctx(&mut scenario),
        );

        // Register as participant
        battle_royale::register_participant(
            &mut launchpad,
            &mut br,
            payment,
            test_scenario::ctx(&mut scenario),
        );

        // Verify registration (indirectly, as we can't access the internal table)
        // We'll verify this by creating a coin later
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Create a coin for USER1
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take shared objects needed
        let mut address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let mut registry = test_scenario::take_shared<LaunchedCoinsRegistry>(&scenario);
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Get treasury cap for test coin
        let treasury_cap = test_scenario::take_from_address<TreasuryCap<TEST_COIN>>(
            &scenario,
            ADMIN,
        );

        // Payment for coin creation
        let payment = coin::mint_for_testing<SUI>(
            10_000_000_000, // 10 SUI
            test_scenario::ctx(&mut scenario),
        );

        // Create coin for battle royale
        let coin_address = coin_manager::create_coin_for_br<TEST_COIN>(
            &mut launchpad,
            treasury_cap,
            &mut registry,
            &mut br,
            payment,
            string::utf8(b"Battle Coin 1"),
            string::utf8(b"BC1"),
            string::utf8(b"A battle coin for testing"),
            string::utf8(b"https://example.com"),
            string::utf8(b"https://example.com/image.png"),
            string::utf8(b"coinType"),
            test_scenario::ctx(&mut scenario),
        );
        address_holder.coin1_address = coin_address;

        // Verify coin is registered in BR
        assert!(battle_royale::is_coin_registered(&br, coin_address), 0);

        // Return shared objects
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_trade_with_battle_royale() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Initialize and create coin
    test_init_internal(&mut scenario);
    setup_participant_with_coin(&mut scenario, USER1);

    // Fast forward to when BR is active
    test_scenario::next_epoch(&mut scenario, ADMIN);

    // Test buying tokens with BR
    test_scenario::next_tx(&mut scenario, USER2);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let coin_address = address_holder.coin1_address;
        let br_address = address_holder.br_address;

        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let mut coin_info = test_scenario::take_shared_by_id<CoinInfo<TEST_COIN>>(
            &scenario,
            object::id_from_address(coin_address),
        );
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Get initial values
        let initial_prize_pool = battle_royale::test_get_battle_royale_prize_pool(&br);
        let initial_supply = coin_manager::get_supply(&coin_info);
        let initial_real_sui = coin_manager::get_real_sui_reserves(&coin_info);

        // Create payment for buying tokens
        let mut payment = coin::mint_for_testing<SUI>(
            2_000_000_000, // 2 SUI
            test_scenario::ctx(&mut scenario),
        );

        // Buy tokens using BR
        let sui_amount = 1_000_000_000; // 1 SUI
        coin_manager::buy_tokens_with_br<TEST_COIN>(
            &mut launchpad,
            &mut coin_info,
            &mut payment,
            sui_amount,
            &mut br,
            test_scenario::ctx(&mut scenario),
        );

        // Verify state changes
        // 1. Supply increases
        assert!(coin_manager::get_supply(&coin_info) > initial_supply, 0);

        // 2. Real SUI reserves increase
        assert!(coin_manager::get_real_sui_reserves(&coin_info) > initial_real_sui, 0);

        // 3. Prize pool increases (due to BR fee)
        let new_prize_pool = battle_royale::test_get_battle_royale_prize_pool(&br);
        assert!(new_prize_pool > initial_prize_pool, 0);

        // Return leftover payment
        transfer::public_transfer(payment, USER2);

        // Return shared objects
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(coin_info);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_finalize_battle_royale_and_claim_prizes() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Setup BR with three participants
    test_init_internal(&mut scenario);
    setup_multiple_participants_and_coins(&mut scenario);

    // Fast forward to after BR ends
    test_scenario::next_epoch(&mut scenario, ADMIN);
    test_scenario::next_epoch(&mut scenario, ADMIN);
    test_scenario::next_epoch(&mut scenario, ADMIN);

    // Finalize BR
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let coin1_address = address_holder.coin1_address;
        let coin2_address = address_holder.coin2_address;
        let coin3_address = address_holder.coin3_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Finalize BR - assign winners
        battle_royale::finalize_battle_royale(
            &mut br,
            coin1_address, // USER1 takes first place
            coin2_address, // USER2 takes second place
            coin3_address, // USER3 takes third place
            test_scenario::ctx(&mut scenario),
        );

        // Verify BR is finalized
        assert!(battle_royale::is_battle_royale_finalized(&br), 0);

        // Return shared objects
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Find the winner registry and have USER1 claim first prize
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // First, find the winner registry that was created
        // It would be a shared object
        let mut winner_registry = test_scenario::take_shared<WinnerRegistry>(&scenario);

        // Claim prize as USER1 (first place)
        battle_royale::claim_prize(
            &mut winner_registry,
            test_scenario::ctx(&mut scenario),
        );

        // Verify USER1 received their prize by checking their balance
        // This is difficult in test scenario, but real tests would verify

        test_scenario::return_shared(winner_registry);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_cancel_battle_royale() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Cancel the BR
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Cancel BR
        battle_royale::cancel_battle_royale(
            &mut br,
            string::utf8(b"Testing cancellation"),
            test_scenario::ctx(&mut scenario),
        );

        // Verify BR is cancelled
        assert!(battle_royale::is_battle_royale_cancelled(&br), 0);

        // Return shared objects
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Drain remaining funds
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Drain funds
        battle_royale::drain_remaining_funds(
            &mut br,
            test_scenario::ctx(&mut scenario),
        );

        // Verify prize pool is empty
        let prize_pool = battle_royale::test_get_battle_royale_prize_pool(&br);
        assert_eq(prize_pool, 0);

        // Return shared objects
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Clean up
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let address_holder = test_scenario::take_from_sender<AddressHolder>(&scenario);
        let AddressHolder {
            id,
            br_address: _,
            coin1_address: _,
            coin2_address: _,
            coin3_address: _,
        } = address_holder;
        object::delete(id);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_contribute_to_prize_pool() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Contribute to prize pool
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Get initial prize pool
        let (_, _, _, _, _, initial_prize_pool, _, _, _) = battle_royale::get_battle_royale_info(
            &br,
        );

        // Create contribution
        let contribution = coin::mint_for_testing<SUI>(
            5_000_000_000, // 5 SUI
            test_scenario::ctx(&mut scenario),
        );

        // Contribute to prize pool
        battle_royale::contribute_to_prize_pool(
            &mut br,
            contribution,
            test_scenario::ctx(&mut scenario),
        );

        // Verify prize pool increased
        let (_, _, _, _, _, new_prize_pool, _, _, _) = battle_royale::get_battle_royale_info(&br);
        assert_eq(new_prize_pool, initial_prize_pool + 5_000_000_000);

        // Return shared objects
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_update_battle_royale() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Update BR settings
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // New values
        let new_max_coins = 2;
        let new_mid_battle = false;
        let new_fee = 3_000_000_000; // 3 SUI
        let new_br_fee_bps = 4000; // 40%
        let new_first_place_bps = 6000; // 60%
        let new_second_place_bps = 3000; // 30%
        let new_third_place_bps = 1000; // 10%
        let new_platform_fee_bps = 0; // 0%

        // Update BR
        battle_royale::update_battle_royale(
            &mut br,
            new_max_coins,
            new_mid_battle,
            new_fee,
            new_br_fee_bps,
            new_first_place_bps,
            new_second_place_bps,
            new_third_place_bps,
            new_platform_fee_bps,
            test_scenario::ctx(&mut scenario),
        );

        // Verify updates
        let (_, _, _, _, _, _, new_participation_fee, _, _) = battle_royale::get_battle_royale_info(
            &br,
        );
        assert_eq(new_participation_fee, new_fee);

        let (
            new_first,
            new_second,
            new_third,
            new_br_platform_fee,
        ) = battle_royale::get_prize_distribution(&br);
        assert_eq(new_first, new_first_place_bps);
        assert_eq(new_second, new_second_place_bps);
        assert_eq(new_third, new_third_place_bps);
        assert_eq(new_br_platform_fee, new_platform_fee_bps);

        assert_eq(battle_royale::get_br_fee_bps(&br), new_br_fee_bps);

        // Return shared objects
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_NOT_ADMIN)]
fun test_update_battle_royale_non_admin() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Try to update BR as non-admin user
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Try to update BR as non-admin - should fail
        battle_royale::update_battle_royale(
            &mut br,
            1, // Values don't matter since it should fail
            true,
            BR_PARTICIPATION_FEE,
            BR_FEE_BPS,
            BR_FIRST_PLACE_BPS,
            BR_SECOND_PLACE_BPS,
            BR_THIRD_PLACE_BPS,
            BR_PLATFORM_FEE_BPS,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_INVALID_SHARES)]
fun test_update_battle_royale_invalid_shares() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Try to update BR with invalid shares
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Try to update BR with invalid shares (total > 100%)
        battle_royale::update_battle_royale(
            &mut br,
            BR_MAX_COINS_PER_PARTICIPANT,
            BR_MID_BATTLE_REGISTRATION_ENABLED,
            BR_PARTICIPATION_FEE,
            BR_FEE_BPS,
            6000, // 60%
            5000, // 50%
            1000, // 10%
            500, // 5%
            // Total: 125% - should fail
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_sell_tokens_with_battle_royale() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Initialize and create coin for USER1
    test_init_internal(&mut scenario);
    setup_participant_with_coin(&mut scenario, USER1);

    // Fast forward to when BR is active
    test_scenario::next_epoch(&mut scenario, ADMIN);

    // Have USER2 buy tokens first
    test_scenario::next_tx(&mut scenario, USER2);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let coin_address = address_holder.coin1_address;
        let br_address = address_holder.br_address;

        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let mut coin_info = test_scenario::take_shared_by_id<CoinInfo<TEST_COIN>>(
            &scenario,
            object::id_from_address(coin_address),
        );
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Create payment for buying tokens
        let mut payment = coin::mint_for_testing<SUI>(
            50_500_000_000, // 50 SUI
            test_scenario::ctx(&mut scenario),
        );

        // Buy tokens using BR
        let sui_amount = 50_000_000_000; // 5 SUI
        coin_manager::buy_tokens_with_br<TEST_COIN>(
            &mut launchpad,
            &mut coin_info,
            &mut payment,
            sui_amount,
            &mut br,
            test_scenario::ctx(&mut scenario),
        );

        // Return leftover payment
        transfer::public_transfer(payment, USER2);

        // Return shared objects
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(coin_info);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Now have USER2 sell some tokens back
    test_scenario::next_tx(&mut scenario, USER2);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let coin_address = address_holder.coin1_address;
        let br_address = address_holder.br_address;

        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let mut coin_info = test_scenario::take_shared_by_id<CoinInfo<TEST_COIN>>(
            &scenario,
            object::id_from_address(coin_address),
        );
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Get initial values
        let initial_prize_pool = battle_royale::test_get_battle_royale_prize_pool(&br);
        let initial_supply = coin_manager::get_supply(&coin_info);

        // Get the tokens owned by USER2
        let mut tokens = test_scenario::take_from_sender<Coin<TEST_COIN>>(&scenario);
        let token_amount = coin::value(&tokens);

        // Split the tokens to sell only a portion (e.g., 10%)
        let tokens_to_sell = coin::split(
            &mut tokens,
            token_amount / 10,
            test_scenario::ctx(&mut scenario),
        );

        // Sell half of the tokens
        coin_manager::sell_tokens_with_br<TEST_COIN>(
            &mut launchpad,
            &mut coin_info,
            tokens_to_sell,
            &mut br,
            test_scenario::ctx(&mut scenario),
        );

        // Verify state changes
        // 1. Supply decreases
        assert!(coin_manager::get_supply(&coin_info) < initial_supply, 0);

        // 2. Prize pool increases (due to BR fee)
        let new_prize_pool = battle_royale::test_get_battle_royale_prize_pool(&br);
        assert!(new_prize_pool > initial_prize_pool, 0);

        // Return shared objects
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(coin_info);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
        transfer::public_transfer(tokens, USER2);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_BR_NOT_OPEN)]
fun test_register_after_br_ends() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Fast forward to after BR ends
    test_scenario::next_epoch(&mut scenario, ADMIN);
    test_scenario::next_epoch(&mut scenario, ADMIN);
    test_scenario::next_epoch(&mut scenario, ADMIN);

    // Try to register after BR ends - should fail
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take the BR address from holder
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);

        // Take the BR
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Create payment for participation fee
        let payment = coin::mint_for_testing<SUI>(
            BR_PARTICIPATION_FEE,
            test_scenario::ctx(&mut scenario),
        );

        // Try to register as participant after BR ends - should fail
        battle_royale::register_participant(
            &mut launchpad,
            &mut br,
            payment,
            test_scenario::ctx(&mut scenario),
        );

        // Cleanup - won't be reached due to expected failure
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

// Helper function to register USER1 as a participant and create a coin
fun setup_participant_with_coin(scenario: &mut Scenario, user: address) {
    // Register USER1 as a participant
    test_scenario::next_tx(scenario, user);
    {
        // Take the BR address from holder
        let address_holder = test_scenario::take_from_address<AddressHolder>(scenario, ADMIN);
        let br_address = address_holder.br_address;
        let mut launchpad = test_scenario::take_shared<Launchpad>(scenario);

        // Take the BR
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            scenario,
            object::id_from_address(br_address),
        );

        // Create payment for participation fee
        let payment = coin::mint_for_testing<SUI>(
            BR_PARTICIPATION_FEE,
            test_scenario::ctx(scenario),
        );

        // Register as participant
        battle_royale::register_participant(
            &mut launchpad,
            &mut br,
            payment,
            test_scenario::ctx(scenario),
        );

        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Create a coin for USER1
    test_scenario::next_tx(scenario, user);
    {
        // Take shared objects needed
        let mut address_holder = test_scenario::take_from_address<AddressHolder>(scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut launchpad = test_scenario::take_shared<Launchpad>(scenario);
        let mut registry = test_scenario::take_shared<LaunchedCoinsRegistry>(scenario);
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            scenario,
            object::id_from_address(br_address),
        );

        // Get treasury cap for test coin
        let treasury_cap = test_scenario::take_from_address<TreasuryCap<TEST_COIN>>(
            scenario,
            ADMIN,
        );

        // Payment for coin creation
        let payment = coin::mint_for_testing<SUI>(
            10_000_000_000, // 10 SUI
            test_scenario::ctx(scenario),
        );

        // Create coin for battle royale
        let coin_address = coin_manager::create_coin_for_br<TEST_COIN>(
            &mut launchpad,
            treasury_cap,
            &mut registry,
            &mut br,
            payment,
            string::utf8(b"Battle Coin 1"),
            string::utf8(b"BC1"),
            string::utf8(b"A battle coin for testing"),
            string::utf8(b"https://example.com"),
            string::utf8(b"https://example.com/image.png"),
            string::utf8(b"coinType"),
            test_scenario::ctx(scenario),
        );
        address_holder.coin1_address = coin_address;

        // Return shared objects
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };
}

// Helper function to setup multiple participants and coins
fun setup_multiple_participants_and_coins(scenario: &mut Scenario) {
    // Setup USER1
    setup_participant_with_coin(scenario, USER1);

    // Setup USER2
    test_scenario::next_tx(scenario, USER2);
    {
        // Take the BR address from holder
        let address_holder = test_scenario::take_from_address<AddressHolder>(scenario, ADMIN);
        let br_address = address_holder.br_address;
        let mut launchpad = test_scenario::take_shared<Launchpad>(scenario);

        // Take the BR
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            scenario,
            object::id_from_address(br_address),
        );

        // Create payment for participation fee
        let payment = coin::mint_for_testing<SUI>(
            BR_PARTICIPATION_FEE,
            test_scenario::ctx(scenario),
        );

        // Register as participant
        battle_royale::register_participant(
            &mut launchpad,
            &mut br,
            payment,
            test_scenario::ctx(scenario),
        );

        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::next_tx(scenario, ADMIN); // ADMIN creates the token
    {
        create_test_token_for_testing(test_scenario::ctx(scenario));
    };

    // Create a coin for USER2
    test_scenario::next_tx(scenario, USER2);
    {
        // Take shared objects needed
        let mut address_holder = test_scenario::take_from_address<AddressHolder>(scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut launchpad = test_scenario::take_shared<Launchpad>(scenario);
        let mut registry = test_scenario::take_shared<LaunchedCoinsRegistry>(scenario);
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            scenario,
            object::id_from_address(br_address),
        );

        // Get treasury cap for test coin
        let treasury_cap = test_scenario::take_from_address<TreasuryCap<TEST_COIN>>(
            scenario,
            ADMIN,
        );

        // Payment for coin creation
        let payment = coin::mint_for_testing<SUI>(
            10_000_000_000, // 10 SUI
            test_scenario::ctx(scenario),
        );

        // Create coin for battle royale
        let coin_address = coin_manager::create_coin_for_br<TEST_COIN>(
            &mut launchpad,
            treasury_cap,
            &mut registry,
            &mut br,
            payment,
            string::utf8(b"Battle Coin 2"),
            string::utf8(b"BC2"),
            string::utf8(b"A battle coin for testing"),
            string::utf8(b"https://example.com"),
            string::utf8(b"https://example.com/image.png"),
            string::utf8(b"coinType"),
            test_scenario::ctx(scenario),
        );
        address_holder.coin2_address = coin_address;

        // Return shared objects
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Setup USER3
    test_scenario::next_tx(scenario, USER3);
    {
        // Take the BR address from holder
        let address_holder = test_scenario::take_from_address<AddressHolder>(scenario, ADMIN);
        let br_address = address_holder.br_address;
        let mut launchpad = test_scenario::take_shared<Launchpad>(scenario);

        // Take the BR
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            scenario,
            object::id_from_address(br_address),
        );

        // Create payment for participation fee
        let payment = coin::mint_for_testing<SUI>(
            BR_PARTICIPATION_FEE,
            test_scenario::ctx(scenario),
        );

        // Register as participant
        battle_royale::register_participant(
            &mut launchpad,
            &mut br,
            payment,
            test_scenario::ctx(scenario),
        );

        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::next_tx(scenario, ADMIN); // ADMIN creates the token
    {
        create_test_token_for_testing(test_scenario::ctx(scenario));
    };

    // Create a coin for USER3
    test_scenario::next_tx(scenario, USER3);
    {
        // Take shared objects needed
        let mut address_holder = test_scenario::take_from_address<AddressHolder>(scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut launchpad = test_scenario::take_shared<Launchpad>(scenario);
        let mut registry = test_scenario::take_shared<LaunchedCoinsRegistry>(scenario);
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            scenario,
            object::id_from_address(br_address),
        );

        // Get treasury cap for test coin
        let treasury_cap = test_scenario::take_from_address<TreasuryCap<TEST_COIN>>(
            scenario,
            ADMIN,
        );

        // Payment for coin creation
        let payment = coin::mint_for_testing<SUI>(
            10_000_000_000, // 10 SUI
            test_scenario::ctx(scenario),
        );

        // Create coin for battle royale
        let coin_address = coin_manager::create_coin_for_br<TEST_COIN>(
            &mut launchpad,
            treasury_cap,
            &mut registry,
            &mut br,
            payment,
            string::utf8(b"Battle Coin 3"),
            string::utf8(b"BC3"),
            string::utf8(b"A battle coin for testing"),
            string::utf8(b"https://example.com"),
            string::utf8(b"https://example.com/image.png"),
            string::utf8(b"coinType"),
            test_scenario::ctx(scenario),
        );
        address_holder.coin3_address = coin_address;

        // Return shared objects
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };
}

#[test]
#[expected_failure(abort_code = battle_royale::E_ALREADY_REGISTERED)]
fun test_register_participant_twice() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Register USER1 first time
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take the BR address from holder
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);

        // Take the BR
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Create payment for participation fee
        let payment = coin::mint_for_testing<SUI>(
            BR_PARTICIPATION_FEE,
            test_scenario::ctx(&mut scenario),
        );

        // Register as participant
        battle_royale::register_participant(
            &mut launchpad,
            &mut br,
            payment,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Try to register USER1 again - should fail
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take the BR address from holder
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);

        // Take the BR
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Create payment for participation fee
        let payment = coin::mint_for_testing<SUI>(
            BR_PARTICIPATION_FEE,
            test_scenario::ctx(&mut scenario),
        );

        // Try to register again - should fail
        battle_royale::register_participant(
            &mut launchpad,
            &mut br,
            payment,
            test_scenario::ctx(&mut scenario),
        );

        // Not reached due to expected failure
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_INSUFFICIENT_PAYMENT)]
fun test_register_insufficient_payment() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Try to register with insufficient payment
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take the BR address from holder
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);

        // Take the BR
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Create insufficient payment
        let payment = coin::mint_for_testing<SUI>(
            BR_PARTICIPATION_FEE - 1, // 1 mist less than required
            test_scenario::ctx(&mut scenario),
        );

        // Try to register with insufficient payment - should fail
        battle_royale::register_participant(
            &mut launchpad,
            &mut br,
            payment,
            test_scenario::ctx(&mut scenario),
        );

        // Not reached due to expected failure
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_PARTICIPANT_NOT_REGISTERED)]
fun test_register_coin_without_participant() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Try to register coin without registering participant first
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take shared objects needed
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        let mut registry = test_scenario::take_shared<LaunchedCoinsRegistry>(&scenario);
        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Get treasury cap for test coin
        let treasury_cap = test_scenario::take_from_address<TreasuryCap<TEST_COIN>>(
            &scenario,
            ADMIN,
        );

        // Payment for coin creation
        let payment = coin::mint_for_testing<SUI>(
            10_000_000_000, // 10 SUI
            test_scenario::ctx(&mut scenario),
        );

        // Try to create coin without registering participant - should fail
        coin_manager::create_coin_for_br<TEST_COIN>(
            &mut launchpad,
            treasury_cap,
            &mut registry,
            &mut br,
            payment,
            string::utf8(b"Battle Coin"),
            string::utf8(b"BC"),
            string::utf8(b"A battle coin for testing"),
            string::utf8(b"https://example.com"),
            string::utf8(b"https://example.com/image.png"),
            string::utf8(b"coinType"),
            test_scenario::ctx(&mut scenario),
        );

        // Not reached due to expected failure
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(registry);
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
        // test_scenario::return_to_address(ADMIN, treasury_cap);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_BR_NOT_ENDED)]
fun test_finalize_battle_royale_before_end() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);
    setup_multiple_participants_and_coins(&mut scenario);

    // Try to finalize BR before it ends - should fail
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let coin1_address = address_holder.coin1_address;
        let coin2_address = address_holder.coin2_address;
        let coin3_address = address_holder.coin3_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Try to finalize BR before it ends - should fail
        battle_royale::finalize_battle_royale(
            &mut br,
            coin1_address,
            coin2_address,
            coin3_address,
            test_scenario::ctx(&mut scenario),
        );

        // Not reached due to expected failure
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_NOT_ADMIN)]
fun test_finalize_battle_royale_non_admin() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);
    setup_multiple_participants_and_coins(&mut scenario);

    // Fast forward to after BR ends
    test_scenario::next_epoch(&mut scenario, ADMIN);
    // Try to finalize BR as non-admin - should fail
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let coin1_address = address_holder.coin1_address;
        let coin2_address = address_holder.coin2_address;
        let coin3_address = address_holder.coin3_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Try to finalize BR as non-admin - should fail
        battle_royale::finalize_battle_royale(
            &mut br,
            coin1_address,
            coin2_address,
            coin3_address,
            test_scenario::ctx(&mut scenario),
        );

        // Not reached due to expected failure
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_ALREADY_CLAIMED)]
fun test_claim_prize_twice() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Setup BR with participants
    test_init_internal(&mut scenario);
    setup_multiple_participants_and_coins(&mut scenario);

    // Fast forward to after BR ends
    test_scenario::next_epoch(&mut scenario, ADMIN);
    test_scenario::next_epoch(&mut scenario, ADMIN);
    test_scenario::next_epoch(&mut scenario, ADMIN);

    // Finalize BR
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let coin1_address = address_holder.coin1_address;
        let coin2_address = address_holder.coin2_address;
        let coin3_address = address_holder.coin3_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Finalize BR with USER1 as first place
        battle_royale::finalize_battle_royale(
            &mut br,
            coin1_address, // USER1 takes first place
            coin2_address, // USER2 takes second place
            coin3_address, // USER3 takes third place
            test_scenario::ctx(&mut scenario),
        );

        // Return shared objects
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Have USER1 claim prize first time
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Find the winner registry
        let mut winner_registry = test_scenario::take_shared<WinnerRegistry>(&scenario);

        // Claim prize as USER1 (first place)
        battle_royale::claim_prize(
            &mut winner_registry,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(winner_registry);
    };

    // Try to have USER1 claim prize again - should fail
    test_scenario::next_tx(&mut scenario, USER1);
    {
        // Find the winner registry
        let mut winner_registry = test_scenario::take_shared<WinnerRegistry>(&scenario);

        // Try to claim prize again - should fail
        battle_royale::claim_prize(
            &mut winner_registry,
            test_scenario::ctx(&mut scenario),
        );

        // Not reached due to expected failure
        test_scenario::return_shared(winner_registry);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_NOT_WINNER)]
fun test_claim_prize_wrong_creator() {
    let mut scenario = test_scenario::begin(ADMIN);

    // Setup BR with participants
    test_init_internal(&mut scenario);
    setup_multiple_participants_and_coins(&mut scenario);

    // Fast forward to after BR ends
    test_scenario::next_epoch(&mut scenario, ADMIN);
    test_scenario::next_epoch(&mut scenario, ADMIN);
    test_scenario::next_epoch(&mut scenario, ADMIN);

    // Finalize BR
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;
        let coin1_address = address_holder.coin1_address;
        let coin2_address = address_holder.coin2_address;
        let coin3_address = address_holder.coin3_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Finalize BR with USER1 as first place
        battle_royale::finalize_battle_royale(
            &mut br,
            coin1_address, // USER1 takes first place
            coin2_address, // USER2 takes second place
            coin3_address, // USER3 takes third place
            test_scenario::ctx(&mut scenario),
        );

        // Return shared objects
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    // Have USER4 try to claim a prize - should fail
    test_scenario::next_tx(&mut scenario, USER4);
    {
        // Find the winner registry
        let mut winner_registry = test_scenario::take_shared<WinnerRegistry>(&scenario);

        // Try to claim a prize as USER4 - should fail
        battle_royale::claim_prize(
            &mut winner_registry,
            test_scenario::ctx(&mut scenario),
        );

        // Not reached due to expected failure
        test_scenario::return_shared(winner_registry);
    };

    test_scenario::end(scenario);
}

#[test]
#[expected_failure(abort_code = battle_royale::E_BR_ACTIVE)]
fun test_drain_active_battle_royale() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Try to drain funds from active BR - should fail
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let mut br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Try to drain funds from active BR - should fail
        battle_royale::drain_remaining_funds(
            &mut br,
            test_scenario::ctx(&mut scenario),
        );

        // Not reached due to expected failure
        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_is_battle_royale_active() {
    let mut scenario = test_scenario::begin(ADMIN);
    test_init_internal(&mut scenario);

    // Check BR activity at different times
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        // Take shared objects
        let address_holder = test_scenario::take_from_address<AddressHolder>(&scenario, ADMIN);
        let br_address = address_holder.br_address;

        let br = test_scenario::take_shared_by_id<BattleRoyale>(
            &scenario,
            object::id_from_address(br_address),
        );

        // Before start time - not active
        assert!(!battle_royale::is_battle_royale_active(&br, BR_START_TIME - 1), 0);

        // At start time - active
        assert!(battle_royale::is_battle_royale_active(&br, BR_START_TIME), 0);

        // During BR - active
        assert!(battle_royale::is_battle_royale_active(&br, BR_START_TIME + 1), 0);

        // At end time - active
        assert!(battle_royale::is_battle_royale_active(&br, BR_END_TIME), 0);

        // After end time - not active
        assert!(!battle_royale::is_battle_royale_active(&br, BR_END_TIME + 1), 0);

        test_scenario::return_shared(br);
        test_scenario::return_to_address(ADMIN, address_holder);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_default_battle_royale_creation() {
    let mut scenario = test_scenario::begin(ADMIN);

    // First create the test token
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        create_test_token_for_testing(test_scenario::ctx(&mut scenario));
    };

    // Setup token launcher
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        token_launcher::create_launchpad_for_testing(test_scenario::ctx(&mut scenario));
    };

    // Create default BR
    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let launchpad = test_scenario::take_shared<Launchpad>(&scenario);

        // Call create_default_battle_royale
        battle_royale::create_default_battle_royale(
            &launchpad,
            string::utf8(BR_NAME),
            string::utf8(BR_DESCRIPTION),
            BR_START_TIME,
            BR_END_TIME,
            test_scenario::ctx(&mut scenario),
        );
        test_scenario::return_shared(launchpad);
    };

    test_scenario::next_tx(&mut scenario, ADMIN);
    {
        let launchpad = test_scenario::take_shared<Launchpad>(&scenario);
        // Verify BR was created (we'll just check it exists by taking it)
        let br = test_scenario::take_shared<BattleRoyale>(&scenario);

        // Verify default values
        let (_, _, _, _, _, _, participation_fee, _, _) = battle_royale::get_battle_royale_info(
            &br,
        );
        assert_eq(participation_fee, battle_royale::test_get_DEFAULT_PARTICIPATION_FEE());

        let (first, second, third, platform) = battle_royale::get_prize_distribution(&br);
        assert_eq(first, battle_royale::test_get_DEFAULT_FIRST_PLACE_BPS());
        assert_eq(second, battle_royale::test_get_DEFAULT_SECOND_PLACE_BPS());
        assert_eq(third, battle_royale::test_get_DEFAULT_THIRD_PLACE_BPS());
        assert_eq(platform, battle_royale::test_get_DEFAULT_PLATFORM_FEE_BPS());

        assert_eq(battle_royale::get_br_fee_bps(&br), battle_royale::test_get_DEFAULT_BR_FEE_BPS());

        // Return shared objects
        test_scenario::return_shared(launchpad);
        test_scenario::return_shared(br);
    };

    test_scenario::end(scenario);
}
