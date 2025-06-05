module wagmint::battle_royale;

use std::string::String;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::table::{Self, Table};
use wagmint::token_launcher;
use wagmint::utils;

// Error codes
const E_NOT_ADMIN: u64 = 0;
const E_INSUFFICIENT_PAYMENT: u64 = 1;
const E_BR_NOT_OPEN: u64 = 2;
const E_BR_NOT_ENDED: u64 = 3;
const E_ALREADY_REGISTERED: u64 = 4;
const E_COIN_NOT_REGISTERED: u64 = 5;
const E_INVALID_TIME: u64 = 6;
const E_BR_ACTIVE: u64 = 7;
const E_PARTICIPANT_NOT_REGISTERED: u64 = 8;
const E_ALREADY_CLAIMED: u64 = 9;
const E_NOT_WINNER: u64 = 10;
const E_INVALID_SHARES: u64 = 11;

// Constants
const BPS_DENOMINATOR: u64 = 10000;
const DEFAULT_PLATFORM_FEE_BPS: u64 = 1000; // 10% of participation fee goes to platform
const DEFAULT_BR_FEE_BPS: u64 = 5000; // 50% of regular trading fees go to BR
const DEFAULT_PARTICIPATION_FEE: u64 = 100_000_000; // 0.1 SUI
const DEFAULT_FIRST_PLACE_BPS: u64 = 5500; // 55%
const DEFAULT_SECOND_PLACE_BPS: u64 = 3000; // 30%
const DEFAULT_THIRD_PLACE_BPS: u64 = 1500; // 15%
const DEFAULT_MAX_COINS_PER_PARTICIPANT: u64 = 1; // Max coins per participant
const DEFAULT_MID_BATTLE_REGISTRATION_ENABLED: bool = false; // Mid-battle registration disabled by default

// Represents a Battle Royale competition
public struct BattleRoyale has key {
    id: UID,
    admin: address,
    name: String,
    description: String,
    start_time: u64, // Epoch time when BR starts
    end_time: u64, // Epoch time when BR ends
    prize_pool: Balance<SUI>, // Total prize pool
    participant_to_coins: Table<address, vector<address>>, // Mapping of participant address -> coin address
    max_coins_per_participant: u64,
    mid_battle_registration_enabled: bool,
    coin_to_participant: Table<address, address>, // Mapping of coin address -> participant address
    participation_fee: u64,
    br_fee_bps: u64, // BPS of trading fees that go to BR
    first_place_bps: u64, // BPS of prize pool for first place
    second_place_bps: u64, // BPS of prize pool for second place
    third_place_bps: u64, // BPS of prize pool for third place
    platform_fee_bps: u64, // BPS of participation fee that goes to the platform
    is_finalized: bool, // whether prizes have been distributed
    is_cancelled: bool, // whether BR was cancelled
}

// Registry of winners for a Battle Royale
public struct WinnerRegistry has key {
    id: UID,
    battle_royale: address,
    winners: Table<address, WinnerInfo>, // Creator address -> winner info
    total_prize_pool: Balance<SUI>,
    is_fully_claimed: bool,
    claimed_count: u64,
}

// Info about a winner
public struct WinnerInfo has copy, drop, store {
    rank: u8,
    prize_amount: u64,
    claimed: bool,
    coin_address: address,
}

// Event for winner registry creation
public struct WinnerRegistryCreatedEvent has copy, drop {
    br_address: address,
    registry_address: address,
    first_place_user_address: address,
    first_place_coin_address: address,
    first_place_amount: u64,
    second_place_user_address: address,
    second_place_coin_address: address,
    second_place_amount: u64,
    third_place_user_address: address,
    third_place_coin_address: address,
    third_place_amount: u64,
    total_prize_pool: u64,
}

// Event for prize claim
public struct PrizeClaimedEvent has copy, drop {
    registry_address: address,
    br_address: address,
    creator_address: address,
    coin_address: address,
    claimer: address,
    rank: u8,
    prize_amount: u64,
}

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
    max_coins_per_participant: u64,
    mid_battle_registration_enabled: bool,
}

public struct BattleRoyaleCancelledEvent has copy, drop {
    br_address: address,
    admin: address,
    reason: String,
}

public struct ParticipantRegisteredEvent has copy, drop {
    br_address: address,
    participant: address,
    participation_fee: u64,
}

public struct CoinRegisteredEvent has copy, drop {
    br_address: address,
    coin_address: address,
    participant: address,
}

public struct PrizePoolContributionEvent has copy, drop {
    br_address: address,
    contributor: address,
    amount: u64,
    new_prize_pool: u64,
}

public struct BattleRoyaleFinalizedEvent has copy, drop {
    br_address: address,
    total_prize_pool: u64,
    admin: address,
}

public struct BattleRoyaleUpdatedEvent has copy, drop {
    br_address: address,
    admin: address,
    old_max_coins_per_participant: u64,
    new_max_coins_per_participant: u64,
    old_mid_battle_registration_enabled: bool,
    new_mid_battle_registration_enabled: bool,
    old_participation_fee: u64,
    new_participation_fee: u64,
    old_br_fee_bps: u64,
    new_br_fee_bps: u64,
    old_first_place_bps: u64,
    new_first_place_bps: u64,
    old_second_place_bps: u64,
    new_second_place_bps: u64,
    old_third_place_bps: u64,
    new_third_place_bps: u64,
    old_platform_fee_bps: u64,
    new_platform_fee_bps: u64,
}

public struct TradeFeeToBREvent has copy, drop {
    br_address: address,
    coin_address: address,
    fee_amount: u64,
    new_prize_pool: u64,
}

// Function to register a participant in a BR
public entry fun register_participant(
    launchpad: &mut token_launcher::Launchpad,
    br: &mut BattleRoyale,
    mut payment: Coin<SUI>,
    ctx: &mut TxContext,
) {
    // Ensure BR is not finalized or cancelled
    assert!(!br.is_finalized && !br.is_cancelled, E_BR_NOT_OPEN);
    assert!(
        !table::contains(&br.participant_to_coins, tx_context::sender(ctx)),
        E_ALREADY_REGISTERED,
    );

    // Ensure BR hasn't ended
    let current_time = tx_context::epoch(ctx);
    assert!(current_time <= br.end_time, E_BR_NOT_OPEN);

    if (current_time > br.start_time) {
        // Ensure mid-battle registration is enabled
        assert!(br.mid_battle_registration_enabled, E_BR_NOT_OPEN);
    };

    // Validate payment
    let payment_amount = coin::value(&payment);
    assert!(payment_amount >= br.participation_fee, E_INSUFFICIENT_PAYMENT);

    // Process participation fee
    if (payment_amount > br.participation_fee) {
        // Refund excess payment
        let excess_payment = coin::split(&mut payment, payment_amount - br.participation_fee, ctx);
        transfer::public_transfer(excess_payment, tx_context::sender(ctx));
    };
    let mut fee_balance = coin::into_balance(payment);

    // Transfer % of fee to platform, if any
    if (br.platform_fee_bps > 0) {
        let fee_amount = balance::value(&fee_balance);
        let platform_fee = utils::as_u64(
            utils::percentage_of(utils::from_u64(fee_amount), br.platform_fee_bps),
        );
        let platform_fee_balance = balance::split(&mut fee_balance, platform_fee);
        token_launcher::add_to_treasury(launchpad, platform_fee_balance);
    };

    // Add fee to prize pool
    balance::join(&mut br.prize_pool, fee_balance);

    // Register the participant in the BR
    table::add(&mut br.participant_to_coins, tx_context::sender(ctx), vector::empty<address>());

    // Emit registration event
    event::emit(ParticipantRegisteredEvent {
        br_address: object::uid_to_address(&br.id),
        participant: tx_context::sender(ctx),
        participation_fee: br.participation_fee,
    });
}

// Function to register a coin in a BR and update registry
public fun register_coin(br: &mut BattleRoyale, coin_address: address, ctx: &mut TxContext) {
    let br_address = object::uid_to_address(&br.id);
    let current_time = tx_context::epoch(ctx);

    // Ensure BR is not finalized or cancelled
    assert!(!br.is_finalized && !br.is_cancelled, E_BR_NOT_OPEN);

    // Ensure BR hasn't ended
    assert!(current_time <= br.end_time, E_BR_NOT_OPEN);

    // Ensure BR has started
    assert!(current_time >= br.start_time, E_BR_NOT_OPEN);

    // Ensure participant is already registered
    assert!(
        table::contains(&br.participant_to_coins, tx_context::sender(ctx)),
        E_PARTICIPANT_NOT_REGISTERED,
    );

    // Ensure coin is not already registered
    assert!(!table::contains(&br.coin_to_participant, coin_address), E_ALREADY_REGISTERED);

    let participant_coins = table::borrow(
        &br.participant_to_coins,
        tx_context::sender(ctx),
    );
    assert!(vector::length(participant_coins) < br.max_coins_per_participant, E_ALREADY_REGISTERED);

    br.participant_to_coins[tx_context::sender(ctx)].push_back(coin_address);
    table::add(&mut br.coin_to_participant, coin_address, tx_context::sender(ctx));

    // Emit registration event
    event::emit(CoinRegisteredEvent {
        br_address,
        coin_address,
        participant: tx_context::sender(ctx),
    });
}

// Create a BR with default settings
public entry fun create_default_battle_royale(
    launchpad: &token_launcher::Launchpad,
    name: String,
    description: String,
    start_time: u64,
    end_time: u64,
    ctx: &mut TxContext,
) {
    create_battle_royale(
        launchpad,
        name,
        description,
        start_time,
        end_time,
        DEFAULT_MAX_COINS_PER_PARTICIPANT,
        DEFAULT_MID_BATTLE_REGISTRATION_ENABLED,
        DEFAULT_PARTICIPATION_FEE,
        DEFAULT_BR_FEE_BPS,
        DEFAULT_FIRST_PLACE_BPS,
        DEFAULT_SECOND_PLACE_BPS,
        DEFAULT_THIRD_PLACE_BPS,
        DEFAULT_PLATFORM_FEE_BPS,
        ctx,
    )
}

// Create a new Battle Royale
public entry fun create_battle_royale(
    launchpad: &token_launcher::Launchpad,
    name: String,
    description: String,
    start_time: u64,
    end_time: u64,
    max_coins_per_participant: u64,
    mid_battle_registration_enabled: bool,
    participation_fee: u64,
    br_fee_bps: u64,
    first_place_bps: u64,
    second_place_bps: u64,
    third_place_bps: u64,
    platform_fee_bps: u64,
    ctx: &mut TxContext,
) {
    // Ensure only admin can create a BR
    assert!(tx_context::sender(ctx) == token_launcher::get_admin(launchpad), E_NOT_ADMIN);

    // Validate time parameters
    assert!(end_time > start_time, E_INVALID_TIME);

    // Validate prize distribution adds up to 10000 BPS (100%)
    assert!(
        first_place_bps + second_place_bps + third_place_bps == BPS_DENOMINATOR,
        E_INVALID_TIME,
    );

    // Create BR object
    let br = BattleRoyale {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
        name,
        description,
        start_time,
        end_time,
        prize_pool: balance::zero<SUI>(),
        participant_to_coins: table::new(ctx),
        coin_to_participant: table::new(ctx),
        max_coins_per_participant,
        mid_battle_registration_enabled,
        participation_fee,
        br_fee_bps,
        first_place_bps,
        second_place_bps,
        third_place_bps,
        platform_fee_bps,
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
        initial_prize_pool: 0,
        participation_fee,
        br_fee_bps,
        first_place_bps,
        second_place_bps,
        third_place_bps,
        platform_fee_bps,
        max_coins_per_participant,
        mid_battle_registration_enabled,
    });

    // Share the BR object
    transfer::share_object(br);
}

public entry fun update_battle_royale(
    br: &mut BattleRoyale,
    max_coins_per_participant: u64,
    mid_battle_registration_enabled: bool,
    participation_fee: u64,
    br_fee_bps: u64,
    first_place_bps: u64,
    second_place_bps: u64,
    third_place_bps: u64,
    platform_fee_bps: u64,
    ctx: &mut TxContext,
) {
    // Ensure only admin can update a BR
    assert!(tx_context::sender(ctx) == br.admin, E_NOT_ADMIN);

    // Validate prize distribution adds up to 10000 BPS (100%)
    assert!(
        first_place_bps + second_place_bps + third_place_bps == BPS_DENOMINATOR,
        E_INVALID_SHARES,
    );

    // Ensure BR is not finalized or cancelled
    assert!(!br.is_finalized && !br.is_cancelled, E_BR_NOT_OPEN);
    assert!(tx_context::epoch(ctx) < br.end_time, E_BR_NOT_OPEN);

    let old_max_coins_per_participant = br.max_coins_per_participant;
    let old_mid_battle_registration_enabled = br.mid_battle_registration_enabled;
    let old_participation_fee = br.participation_fee;
    let old_br_fee_bps = br.br_fee_bps;
    let old_first_place_bps = br.first_place_bps;
    let old_second_place_bps = br.second_place_bps;
    let old_third_place_bps = br.third_place_bps;
    let old_platform_fee_bps = br.platform_fee_bps;

    // Update BR object
    br.max_coins_per_participant = max_coins_per_participant;
    br.mid_battle_registration_enabled = mid_battle_registration_enabled;
    br.participation_fee = participation_fee;
    br.br_fee_bps = br_fee_bps;
    br.first_place_bps = first_place_bps;
    br.second_place_bps = second_place_bps;
    br.third_place_bps = third_place_bps;
    br.platform_fee_bps = platform_fee_bps;

    // Emit update event
    event::emit(BattleRoyaleUpdatedEvent {
        br_address: object::uid_to_address(&br.id),
        admin: tx_context::sender(ctx),
        old_max_coins_per_participant,
        new_max_coins_per_participant: max_coins_per_participant,
        old_mid_battle_registration_enabled,
        new_mid_battle_registration_enabled: mid_battle_registration_enabled,
        old_participation_fee,
        new_participation_fee: participation_fee,
        old_br_fee_bps,
        new_br_fee_bps: br_fee_bps,
        old_first_place_bps,
        new_first_place_bps: first_place_bps,
        old_second_place_bps,
        new_second_place_bps: second_place_bps,
        old_third_place_bps,
        new_third_place_bps: third_place_bps,
        old_platform_fee_bps,
        new_platform_fee_bps: platform_fee_bps,
    });
}

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
    launchpad: &mut token_launcher::Launchpad,
    br: &mut BattleRoyale,
    coin_address: address,
    fee_balance: Balance<SUI>,
    ctx: &mut TxContext,
) {
    let current_time = tx_context::epoch(ctx);
    if (!is_battle_royale_active(br, current_time)) {
        // transfer fee to treasury
        token_launcher::add_to_treasury(launchpad, fee_balance);
        return
    };

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
    first_place_coin_address: address,
    second_place_coin_address: address,
    third_place_coin_address: address,
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
    assert!(
        table::contains(&br.coin_to_participant, first_place_coin_address),
        E_COIN_NOT_REGISTERED,
    );
    assert!(
        table::contains(&br.coin_to_participant, second_place_coin_address),
        E_COIN_NOT_REGISTERED,
    );
    assert!(
        table::contains(&br.coin_to_participant, third_place_coin_address),
        E_COIN_NOT_REGISTERED,
    );

    // Calculate prize amounts
    let total_prize = balance::value(&br.prize_pool);
    let first_prize = utils::as_u64(
        utils::percentage_of(utils::from_u64(total_prize), br.first_place_bps),
    );
    let second_prize = utils::as_u64(
        utils::percentage_of(utils::from_u64(total_prize), br.second_place_bps),
    );
    let third_prize = utils::as_u64(
        utils::percentage_of(utils::from_u64(total_prize), br.third_place_bps),
    );
    // Verify that all shares add up to total (optional safety check)
    assert!(first_prize + second_prize + third_prize <= total_prize, E_INVALID_SHARES);

    // Get creators of winning coins
    let first_place_user_address = br.coin_to_participant[first_place_coin_address];
    let second_place_user_address = br.coin_to_participant[second_place_coin_address];
    let third_place_user_address = br.coin_to_participant[third_place_coin_address];

    // Create winner registry
    let mut winner_registry = WinnerRegistry {
        id: object::new(ctx),
        battle_royale: object::uid_to_address(&br.id),
        winners: table::new(ctx),
        total_prize_pool: balance::zero<SUI>(),
        is_fully_claimed: false,
        claimed_count: 0,
    };

    // Add winners to registry
    table::add(
        &mut winner_registry.winners,
        first_place_user_address,
        WinnerInfo {
            rank: 1,
            prize_amount: first_prize,
            claimed: false,
            coin_address: first_place_coin_address,
        },
    );

    table::add(
        &mut winner_registry.winners,
        second_place_user_address,
        WinnerInfo {
            rank: 2,
            prize_amount: second_prize,
            claimed: false,
            coin_address: second_place_coin_address,
        },
    );

    table::add(
        &mut winner_registry.winners,
        third_place_user_address,
        WinnerInfo {
            rank: 3,
            prize_amount: third_prize,
            claimed: false,
            coin_address: third_place_coin_address,
        },
    );

    balance::join(&mut winner_registry.total_prize_pool, balance::withdraw_all(&mut br.prize_pool));

    // Mark BR as finalized
    br.is_finalized = true;

    // Emit finalization event
    event::emit(WinnerRegistryCreatedEvent {
        br_address: object::uid_to_address(&br.id),
        registry_address: object::uid_to_address(&winner_registry.id),
        first_place_user_address,
        first_place_coin_address,
        first_place_amount: first_prize,
        second_place_user_address,
        second_place_coin_address,
        second_place_amount: second_prize,
        third_place_user_address,
        third_place_coin_address,
        third_place_amount: third_prize,
        total_prize_pool: total_prize,
    });

    // Emit finalization event
    event::emit(BattleRoyaleFinalizedEvent {
        br_address: object::uid_to_address(&br.id),
        total_prize_pool: total_prize,
        admin: tx_context::sender(ctx),
    });

    // Share the winner registry
    transfer::share_object(winner_registry);
}

// New function for winners to claim prizes
public entry fun claim_prize(winner_registry: &mut WinnerRegistry, ctx: &mut TxContext) {
    assert!(table::contains(&winner_registry.winners, tx_context::sender(ctx)), E_NOT_WINNER);

    // Get winner info
    let length = table::length(&winner_registry.winners);
    let winner_info = table::borrow_mut(&mut winner_registry.winners, tx_context::sender(ctx));

    // Ensure prize hasn't been claimed yet
    assert!(!winner_info.claimed, E_ALREADY_CLAIMED);

    // Get prize amount
    let prize_amount = winner_info.prize_amount;

    // Transfer the prize
    let prize_coin = coin::take(&mut winner_registry.total_prize_pool, prize_amount, ctx);
    transfer::public_transfer(prize_coin, tx_context::sender(ctx));

    // Mark as claimed
    winner_info.claimed = true;

    // Check if all prizes claimed
    winner_registry.claimed_count = winner_registry.claimed_count + 1;

    // Update registry status if all claimed
    if (winner_registry.claimed_count == length) {
        winner_registry.is_fully_claimed = true;
    };

    // Emit claim event
    event::emit(PrizeClaimedEvent {
        registry_address: object::uid_to_address(&winner_registry.id),
        br_address: winner_registry.battle_royale,
        creator_address: tx_context::sender(ctx),
        coin_address: winner_info.coin_address,
        claimer: tx_context::sender(ctx),
        rank: winner_info.rank,
        prize_amount,
    });
}

// Admin-only function to cancel a BR before it ends
public entry fun cancel_battle_royale(br: &mut BattleRoyale, reason: String, ctx: &mut TxContext) {
    // Ensure only admin can cancel
    assert!(tx_context::sender(ctx) == br.admin, E_NOT_ADMIN);

    // Ensure BR has not been finalized or cancelled
    assert!(!br.is_finalized && !br.is_cancelled, E_BR_NOT_OPEN);

    // Mark BR as cancelled
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
): (String, String, address, u64, u64, u64, u64, bool, bool) {
    (
        br.name,
        br.description,
        br.admin,
        br.start_time,
        br.end_time,
        balance::value(&br.prize_pool),
        br.participation_fee,
        br.is_finalized,
        br.is_cancelled,
    )
}

public fun get_address(br: &BattleRoyale): address {
    object::uid_to_address(&br.id)
}

// Check if a coin is registered in a BR
public fun is_coin_registered(br: &BattleRoyale, coin_address: address): bool {
    table::contains(&br.coin_to_participant, coin_address)
}

// Get prize distribution percentages
public fun get_prize_distribution(br: &BattleRoyale): (u64, u64, u64, u64) {
    (br.first_place_bps, br.second_place_bps, br.third_place_bps, br.platform_fee_bps)
}

// Get BR fee percentage
public fun get_br_fee_bps(br: &BattleRoyale): u64 {
    br.br_fee_bps
}

// Get br participating coins
public fun does_coin_participate(br: &BattleRoyale, coin_address: address): bool {
    table::contains(&br.coin_to_participant, coin_address)
}

// Get BR is active
public fun is_battle_royale_active(br: &BattleRoyale, current_time: u64): bool {
    current_time >= br.start_time && current_time <= br.end_time
}

// Get BR is open
public fun is_battle_royale_open(br: &BattleRoyale, current_time: u64): bool {
    current_time >= br.start_time
}

// Get BR is finalized
public fun is_battle_royale_finalized(br: &BattleRoyale): bool {
    br.is_finalized
}

// Get BR is cancelled
public fun is_battle_royale_cancelled(br: &BattleRoyale): bool {
    br.is_cancelled
}

// Check if a coin is valid for Battle Royale
public fun is_coin_valid_for_battle_royale(
    br: &BattleRoyale,
    coin_address: address,
    current_time: u64,
): bool {
    does_coin_participate(br, coin_address) &&
    is_battle_royale_active(br, current_time) &&
    !is_battle_royale_finalized(br) &&
    !is_battle_royale_cancelled(br)
}

// Test only
public fun test_get_battle_royale_address(br: &BattleRoyale): address {
    object::uid_to_address(&br.id)
}

public fun test_get_battle_royale_prize_pool(br: &BattleRoyale): u64 {
    balance::value(&br.prize_pool)
}

public fun test_get_DEFAULT_PARTICIPATION_FEE(): u64 {
    DEFAULT_PARTICIPATION_FEE
}

public fun test_get_DEFAULT_BR_FEE_BPS(): u64 {
    DEFAULT_BR_FEE_BPS
}

public fun test_get_DEFAULT_FIRST_PLACE_BPS(): u64 {
    DEFAULT_FIRST_PLACE_BPS
}

public fun test_get_DEFAULT_SECOND_PLACE_BPS(): u64 {
    DEFAULT_SECOND_PLACE_BPS
}

public fun test_get_DEFAULT_THIRD_PLACE_BPS(): u64 {
    DEFAULT_THIRD_PLACE_BPS
}

public fun test_get_DEFAULT_PLATFORM_FEE_BPS(): u64 {
    DEFAULT_PLATFORM_FEE_BPS
}
