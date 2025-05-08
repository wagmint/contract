module wagmint::battle_royale;

use std::string::String;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};

// use wagmint::coin_manager::{Self, CoinInfo};

// use wagmint::token_launcher::{Self, Launchpad};

// Error codes
const E_NOT_ADMIN: u64 = 0;
const E_INSUFFICIENT_PAYMENT: u64 = 1;
const E_BR_NOT_OPEN: u64 = 2;
const E_BR_NOT_ENDED: u64 = 3;
const E_ALREADY_REGISTERED: u64 = 4;
const E_COIN_NOT_REGISTERED: u64 = 5;
const E_INVALID_TIME: u64 = 6;
const E_BR_ACTIVE: u64 = 7;

// Constants
const BPS_DENOMINATOR: u64 = 10000;
const DEFAULT_BR_FEE_BPS: u64 = 1000; // 10% of regular trading fees go to BR
const DEFAULT_PARTICIPATION_FEE: u64 = 5_000_000_000; // 5 SUI
const DEFAULT_FIRST_PLACE_BPS: u64 = 5000; // 50%
const DEFAULT_SECOND_PLACE_BPS: u64 = 2500; // 25%
const DEFAULT_THIRD_PLACE_BPS: u64 = 1500; // 15%
const DEFAULT_PLATFORM_FEE_BPS: u64 = 1000; // 10%

// Represents a Battle Royale competition
public struct BattleRoyale has key {
    id: UID,
    admin: address,
    name: String,
    description: String,
    start_time: u64, // Epoch time when BR starts
    end_time: u64, // Epoch time when BR ends
    prize_pool: Balance<SUI>, // Total prize pool
    participant_coins: Table<address, bool>, // Mapping of coin address -> is_registered
    participation_fee: u64,
    br_fee_bps: u64, // BPS of trading fees that go to BR
    first_place_bps: u64, // BPS of prize pool for first place
    second_place_bps: u64, // BPS of prize pool for second place
    third_place_bps: u64, // BPS of prize pool for third place
    platform_fee_bps: u64, // BPS of prize pool for platform fee
    is_active: bool, // whether BR is active or not
    is_finalized: bool, // whether prizes have been distributed
    is_cancelled: bool, // whether BR was cancelled
}

// Participant registration details
// public struct ParticipantInfo has copy, drop, store {
//     coin_address: address,
//     registration_time: u64,
// }

// Events
public struct BattleRoyaleCreatedEvent has copy, drop {
    br_address: address,
    admin: address,
    name: String,
    description: String,
    start_time: u64,
    end_time: u64,
    initial_prize_pool: u64,
    participation_fee: u64,
    br_fee_bps: u64,
    first_place_bps: u64,
    second_place_bps: u64,
    third_place_bps: u64,
    platform_fee_bps: u64,
}

public struct BattleRoyaleCancelledEvent has copy, drop {
    br_address: address,
    admin: address,
    reason: String,
}

public struct CoinRegisteredEvent has copy, drop {
    br_address: address,
    coin_address: address,
    participant: address,
    registration_time: u64,
    participation_fee: u64,
}

public struct PrizePoolContributionEvent has copy, drop {
    br_address: address,
    contributor: address,
    amount: u64,
    new_prize_pool: u64,
}

public struct BattleRoyaleFinalizedEvent has copy, drop {
    br_address: address,
    first_place: address,
    first_place_amount: u64,
    second_place: address,
    second_place_amount: u64,
    third_place: address,
    third_place_amount: u64,
    total_prize_pool: u64,
}

public struct TradeFeeToBREvent has copy, drop {
    br_address: address,
    coin_address: address,
    fee_amount: u64,
    new_prize_pool: u64,
}

// Function to register a coin in a BR and update registry
public entry fun register_coin(
    br: &mut BattleRoyale,
    coin_address: address,
    payment: &mut Coin<SUI>,
    ctx: &mut TxContext,
) {
    // let coin_address = object::uid_to_address(&coin_info.id);
    let br_address = object::uid_to_address(&br.id);
    let current_time = tx_context::epoch(ctx);

    // Ensure BR is not finalized or cancelled
    assert!(!br.is_finalized && !br.is_cancelled, E_BR_NOT_OPEN);

    // Ensure BR hasn't ended
    assert!(current_time <= br.end_time, E_BR_NOT_OPEN);

    // Ensure coin is not already registered in this BR
    assert!(!table::contains(&br.participant_coins, coin_address), E_ALREADY_REGISTERED);

    // Validate payment
    assert!(coin::value(payment) >= br.participation_fee, E_INSUFFICIENT_PAYMENT);

    // Process participation fee
    let fee_payment = coin::split(payment, br.participation_fee, ctx);
    let fee_balance = coin::into_balance(fee_payment);

    // Add fee to prize pool
    balance::join(&mut br.prize_pool, fee_balance);

    // Register the coin in the BR
    table::add(&mut br.participant_coins, coin_address, true);

    // Emit registration event
    event::emit(CoinRegisteredEvent {
        br_address,
        coin_address,
        participant: tx_context::sender(ctx),
        registration_time: current_time,
        participation_fee: br.participation_fee,
    });
}

// Create a new Battle Royale
public entry fun create_battle_royale(
    name: String,
    description: String,
    start_time: u64,
    end_time: u64,
    initial_prize: Coin<SUI>,
    participation_fee: u64,
    br_fee_bps: u64,
    first_place_bps: u64,
    second_place_bps: u64,
    third_place_bps: u64,
    platform_fee_bps: u64,
    ctx: &mut TxContext,
) {
    // Validate time parameters
    assert!(end_time > start_time, E_INVALID_TIME);

    // Validate prize distribution adds up to 10000 BPS (100%)
    assert!(
        first_place_bps + second_place_bps + third_place_bps == BPS_DENOMINATOR,
        E_INVALID_TIME,
    );

    // Create BR object
    let initial_prize_amount = coin::value(&initial_prize);
    let prize_pool = coin::into_balance(initial_prize);

    let br = BattleRoyale {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
        name,
        description,
        start_time,
        end_time,
        prize_pool,
        participant_coins: table::new(ctx),
        participation_fee,
        br_fee_bps,
        first_place_bps,
        second_place_bps,
        third_place_bps,
        platform_fee_bps,
        is_active: false, // BR becomes active when start_time is reached
        is_finalized: false,
        is_cancelled: false,
    };

    let br_address = object::uid_to_address(&br.id);

    // Emit creation event
    event::emit(BattleRoyaleCreatedEvent {
        br_address,
        admin: tx_context::sender(ctx),
        name,
        description,
        start_time,
        end_time,
        initial_prize_pool: initial_prize_amount,
        participation_fee,
        br_fee_bps,
        first_place_bps,
        second_place_bps,
        third_place_bps,
        platform_fee_bps,
    });

    // Share the BR object
    transfer::share_object(br);
}

// Utility to check if BR is ongoing (between start and end time)
// fun is_battle_royale_ongoing(br: &BattleRoyale, current_time: u64): bool {
//     current_time >= br.start_time && current_time <= br.end_time
// }

// Add to prize pool (can be called by anyone)
public entry fun contribute_to_prize_pool(
    br: &mut BattleRoyale,
    contribution: Coin<SUI>,
    ctx: &mut TxContext,
) {
    // Ensure BR is not finalized or cancelled
    assert!(!br.is_finalized && !br.is_cancelled, E_BR_NOT_OPEN);

    let contribution_amount = coin::value(&contribution);
    let contribution_balance = coin::into_balance(contribution);

    // Add contribution to prize pool
    balance::join(&mut br.prize_pool, contribution_balance);

    // Emit contribution event
    event::emit(PrizePoolContributionEvent {
        br_address: object::uid_to_address(&br.id),
        contributor: tx_context::sender(ctx),
        amount: contribution_amount,
        new_prize_pool: balance::value(&br.prize_pool),
    });
}

// Called during trades in coin_manager to contribute fees to BR
public fun contribute_trade_fee(
    br: &mut BattleRoyale,
    coin_address: address,
    fee_balance: Balance<SUI>,
) {
    let fee_amount = balance::value(&fee_balance);

    // Add fee to prize pool
    balance::join(&mut br.prize_pool, fee_balance);

    // Emit fee contribution event
    event::emit(TradeFeeToBREvent {
        br_address: object::uid_to_address(&br.id),
        coin_address,
        fee_amount,
        new_prize_pool: balance::value(&br.prize_pool),
    });
}

// Function to calculate market caps and determine winners
// This is a complex function that would need integration with an oracle or indexer
// For this example, we'll assume we have winner addresses determined externally
public entry fun finalize_battle_royale(
    br: &mut BattleRoyale,
    first_place: address,
    second_place: address,
    third_place: address,
    ctx: &mut TxContext,
) {
    // Ensure only admin can finalize
    assert!(tx_context::sender(ctx) == br.admin, E_NOT_ADMIN);

    // Ensure BR has ended
    let current_time = tx_context::epoch(ctx);
    assert!(current_time > br.end_time, E_BR_NOT_ENDED);

    // Ensure BR is not already finalized
    assert!(!br.is_finalized, E_BR_NOT_OPEN);

    // Ensure BR is not cancelled
    assert!(!br.is_cancelled, E_BR_NOT_OPEN);

    // Validate winners are registered participants
    assert!(table::contains(&br.participant_coins, first_place), E_COIN_NOT_REGISTERED);
    assert!(table::contains(&br.participant_coins, second_place), E_COIN_NOT_REGISTERED);
    assert!(table::contains(&br.participant_coins, third_place), E_COIN_NOT_REGISTERED);

    // Calculate prize amounts
    let total_prize = balance::value(&br.prize_pool);
    let first_prize = (total_prize * br.first_place_bps) / BPS_DENOMINATOR;
    let second_prize = (total_prize * br.second_place_bps) / BPS_DENOMINATOR;
    let third_prize = (total_prize * br.third_place_bps) / BPS_DENOMINATOR;

    // Get owners of winning coins (in a real implementation, this would need coin_manager integration)
    // For example, this could be done by getting creator addresses from CoinInfo objects
    let first_owner = first_place; // This is simplified
    let second_owner = second_place; // This is simplified
    let third_owner = third_place; // This is simplified

    // Distribute prizes
    let first_prize_coin = coin::take(&mut br.prize_pool, first_prize, ctx);
    let second_prize_coin = coin::take(&mut br.prize_pool, second_prize, ctx);
    let third_prize_coin = coin::take(&mut br.prize_pool, third_prize, ctx);

    transfer::public_transfer(first_prize_coin, first_owner);
    transfer::public_transfer(second_prize_coin, second_owner);
    transfer::public_transfer(third_prize_coin, third_owner);

    // Mark BR as finalized
    br.is_active = false;
    br.is_finalized = true;

    // Emit finalization event
    event::emit(BattleRoyaleFinalizedEvent {
        br_address: object::uid_to_address(&br.id),
        first_place,
        first_place_amount: first_prize,
        second_place,
        second_place_amount: second_prize,
        third_place,
        third_place_amount: third_prize,
        total_prize_pool: total_prize,
    });
}

// Admin-only function to cancel a BR before it ends
public entry fun cancel_battle_royale(br: &mut BattleRoyale, reason: String, ctx: &mut TxContext) {
    // Ensure only admin can cancel
    assert!(tx_context::sender(ctx) == br.admin, E_NOT_ADMIN);

    // Ensure BR has not been finalized or cancelled
    assert!(!br.is_finalized && !br.is_cancelled, E_BR_NOT_OPEN);

    // Mark BR as cancelled
    br.is_active = false;
    br.is_cancelled = true;

    // Emit cancellation event
    event::emit(BattleRoyaleCancelledEvent {
        br_address: object::uid_to_address(&br.id),
        admin: br.admin,
        reason,
    });
}

// Admin-only function to drain remaining funds after BR is finalized or cancelled
public entry fun drain_remaining_funds(br: &mut BattleRoyale, ctx: &mut TxContext) {
    // Ensure only admin can drain funds
    assert!(tx_context::sender(ctx) == br.admin, E_NOT_ADMIN);

    // Ensure BR is finalized or cancelled
    assert!(br.is_finalized || br.is_cancelled, E_BR_ACTIVE);

    let remaining = balance::value(&br.prize_pool);
    if (remaining > 0) {
        let drain_coin = coin::take(&mut br.prize_pool, remaining, ctx);
        transfer::public_transfer(drain_coin, br.admin);
    };
}

// Get BR info
public fun get_battle_royale_info(
    br: &BattleRoyale,
): (String, String, address, u64, u64, u64, u64, bool, bool, bool) {
    (
        br.name,
        br.description,
        br.admin,
        br.start_time,
        br.end_time,
        balance::value(&br.prize_pool),
        br.participation_fee,
        br.is_active,
        br.is_finalized,
        br.is_cancelled,
    )
}

// Check if a coin is registered in a BR
public fun is_coin_registered(br: &BattleRoyale, coin_address: address): bool {
    table::contains(&br.participant_coins, coin_address)
}

// Get prize distribution percentages
public fun get_prize_distribution(br: &BattleRoyale): (u64, u64, u64) {
    (br.first_place_bps, br.second_place_bps, br.third_place_bps)
}

// Get BR fee percentage
public fun get_br_fee_bps(br: &BattleRoyale): u64 {
    br.br_fee_bps
}

// Get br participating coins
public fun does_coin_participate(br: &BattleRoyale, coin_address: address): bool {
    table::contains(&br.participant_coins, coin_address)
}

// Get BR is active
public fun is_battle_royale_active(br: &BattleRoyale): bool {
    br.is_active
}

// Get BR is finalized
public fun is_battle_royale_finalized(br: &BattleRoyale): bool {
    br.is_finalized
}

// Get BR is cancelled
public fun is_battle_royale_cancelled(br: &BattleRoyale): bool {
    br.is_cancelled
}

// Create a BR with default settings
public entry fun create_default_battle_royale(
    name: String,
    description: String,
    start_time: u64,
    end_time: u64,
    initial_prize: Coin<SUI>,
    ctx: &mut TxContext,
) {
    create_battle_royale(
        name,
        description,
        start_time,
        end_time,
        initial_prize,
        DEFAULT_PARTICIPATION_FEE,
        DEFAULT_BR_FEE_BPS,
        DEFAULT_FIRST_PLACE_BPS,
        DEFAULT_SECOND_PLACE_BPS,
        DEFAULT_THIRD_PLACE_BPS,
        DEFAULT_PLATFORM_FEE_BPS,
        ctx,
    )
}
