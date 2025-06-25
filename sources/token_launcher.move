module wagmint::token_launcher;

use sui::balance::{Self, Balance};
use sui::coin;
use sui::event;
use sui::sui::SUI;

// Constants
const PLATFORM_FEE_BPS: u64 = 100; // 1%
const CREATION_FEE: u64 = 10_000_000; // 0.01 SUI
const GRADUATION_FEE: u64 = 100_000_000; // 0.1 SUI
const CURRENT_VERSION: u64 = 1;
const GRADUATION_THRESHOLD: u64 = 4_000_000_000; // 4 SUI

// Default virtual reserves
const DEFAULT_INITIAL_VIRTUAL_SUI: u64 = 300_000_000_000; // 300 SUI
const DEFAULT_INITIAL_VIRTUAL_TOKENS: u64 = 1_000_000_000_000_000; // 1B tokens
const DEFAULT_TOKEN_DECIMALS: u8 = 6;

// New: Bonding curve allocation percentages (in basis points)
const DEFAULT_BONDING_CURVE_BPS: u64 = 8000; // 80%
const DEFAULT_AMM_RESERVE_BPS: u64 = 2000; // 20%
const GRADUATED_SWAP_FEE_BPS: u64 = 25; // 0.25% swap fee for graduated tokens

// Error codes
const E_NOT_ADMIN: u64 = 0;
const E_INSUFFICIENT_BALANCE: u64 = 1;
const E_INVALID_PERCENTAGE: u64 = 2;

public struct Configuration has copy, store {
    version: u64,
    platform_fee: u64,
    creation_fee: u64,
    graduation_fee: u64,
    initial_virtual_sui: u64,
    initial_virtual_tokens: u64,
    token_decimals: u8,
    graduation_threshold: u64,
    bonding_curve_bps: u64, // Percentage of tokens for bonding curve (in basis points)
    amm_reserve_bps: u64, // Percentage of tokens reserved for AMM (in basis points)
    graduated_swap_fee_bps: u64, // Swap fee for graduated tokens (in basis points)
}

public struct Launchpad has key, store {
    id: UID,
    admin: address,
    launched_coins_count: u64,
    treasury: Balance<SUI>,
    config: Configuration,
}

public struct LaunchedCoinsRegistry has key {
    id: UID,
    coins: vector<address>,
}

public struct LaunchpadInitializedEvent has copy, drop {
    admin: address,
    initial_virtual_sui: u64,
    initial_virtual_tokens: u64,
    token_decimals: u8,
    bonding_curve_bps: u64,
    amm_reserve_bps: u64,
}

public struct ConfigurationUpdatedEvent has copy, drop {
    old_version: u64,
    old_platform_fee: u64,
    old_creation_fee: u64,
    old_graduation_threshold: u64,
    old_graduation_fee: u64,
    old_initial_virtual_sui: u64,
    old_initial_virtual_tokens: u64,
    old_token_decimals: u8,
    old_bonding_curve_bps: u64,
    old_amm_reserve_bps: u64,
    old_graduated_swap_fee_bps: u64,
    new_version: u64,
    new_platform_fee: u64,
    new_creation_fee: u64,
    new_graduation_threshold: u64,
    new_graduation_fee: u64,
    new_initial_virtual_sui: u64,
    new_initial_virtual_tokens: u64,
    new_token_decimals: u8,
    new_bonding_curve_bps: u64,
    new_amm_reserve_bps: u64,
    new_graduated_swap_fee_bps: u64,
}

fun init(ctx: &mut TxContext) {
    let config = Configuration {
        version: CURRENT_VERSION,
        platform_fee: PLATFORM_FEE_BPS,
        creation_fee: CREATION_FEE,
        graduation_fee: GRADUATION_FEE,
        initial_virtual_sui: DEFAULT_INITIAL_VIRTUAL_SUI,
        initial_virtual_tokens: DEFAULT_INITIAL_VIRTUAL_TOKENS,
        token_decimals: DEFAULT_TOKEN_DECIMALS,
        graduation_threshold: GRADUATION_THRESHOLD,
        bonding_curve_bps: DEFAULT_BONDING_CURVE_BPS,
        amm_reserve_bps: DEFAULT_AMM_RESERVE_BPS,
        graduated_swap_fee_bps: GRADUATED_SWAP_FEE_BPS,
    };

    let initial_virtual_sui = config.initial_virtual_sui;
    let initial_virtual_tokens = config.initial_virtual_tokens;
    let token_decimals = config.token_decimals;
    let bonding_curve_bps = config.bonding_curve_bps;
    let amm_reserve_bps = config.amm_reserve_bps;

    let launchpad = Launchpad {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
        launched_coins_count: 0,
        treasury: balance::zero<SUI>(),
        config: config,
    };

    let registry = LaunchedCoinsRegistry {
        id: object::new(ctx),
        coins: vector::empty(),
    };

    // Emit an event when launchpad is initialized
    event::emit(LaunchpadInitializedEvent {
        admin: tx_context::sender(ctx),
        initial_virtual_sui,
        initial_virtual_tokens,
        token_decimals,
        bonding_curve_bps,
        amm_reserve_bps,
    });

    transfer::public_share_object(launchpad);
    transfer::share_object(registry);
}

public entry fun update_launchpad_admin(
    lp: &mut Launchpad,
    new_admin: address,
    ctx: &mut TxContext,
) {
    assert!(lp.admin == tx_context::sender(ctx), E_NOT_ADMIN);
    lp.admin = new_admin;
}

public entry fun update_launchpad_config(
    lp: &mut Launchpad,
    version: u64,
    platform_fee: u64,
    creation_fee: u64,
    graduation_threshold: u64,
    graduation_fee: u64,
    initial_virtual_sui: u64,
    initial_virtual_tokens: u64,
    token_decimals: u8,
    bonding_curve_bps: u64,
    amm_reserve_bps: u64,
    graduated_swap_fee_bps: u64,
    ctx: &mut TxContext,
) {
    assert!(lp.admin == tx_context::sender(ctx), E_NOT_ADMIN);

    // Validate percentages add up to 100%
    assert!(bonding_curve_bps + amm_reserve_bps == 10000, E_INVALID_PERCENTAGE);

    let old_version = lp.config.version;
    let old_platform_fee = lp.config.platform_fee;
    let old_creation_fee = lp.config.creation_fee;
    let old_graduation_threshold = lp.config.graduation_threshold;
    let old_graduation_fee = lp.config.graduation_fee;
    let old_initial_virtual_sui = lp.config.initial_virtual_sui;
    let old_initial_virtual_tokens = lp.config.initial_virtual_tokens;
    let old_token_decimals = lp.config.token_decimals;
    let old_bonding_curve_bps = lp.config.bonding_curve_bps;
    let old_amm_reserve_bps = lp.config.amm_reserve_bps;
    let old_graduated_swap_fee_bps = lp.config.graduated_swap_fee_bps;

    lp.config.version = version;
    lp.config.platform_fee = platform_fee;
    lp.config.creation_fee = creation_fee;
    lp.config.graduation_threshold = graduation_threshold;
    lp.config.graduation_fee = graduation_fee;
    lp.config.initial_virtual_sui = initial_virtual_sui;
    lp.config.initial_virtual_tokens = initial_virtual_tokens;
    lp.config.token_decimals = token_decimals;
    lp.config.bonding_curve_bps = bonding_curve_bps;
    lp.config.amm_reserve_bps = amm_reserve_bps;
    lp.config.graduated_swap_fee_bps = graduated_swap_fee_bps;

    // Emit an event when launchpad config is updated
    event::emit(ConfigurationUpdatedEvent {
        old_version,
        old_platform_fee,
        old_creation_fee,
        old_graduation_threshold,
        old_graduation_fee,
        old_initial_virtual_sui,
        old_initial_virtual_tokens,
        old_token_decimals,
        old_bonding_curve_bps,
        old_amm_reserve_bps,
        old_graduated_swap_fee_bps,
        new_version: version,
        new_platform_fee: platform_fee,
        new_creation_fee: creation_fee,
        new_graduation_threshold: graduation_threshold,
        new_graduation_fee: graduation_fee,
        new_initial_virtual_sui: initial_virtual_sui,
        new_initial_virtual_tokens: initial_virtual_tokens,
        new_token_decimals: token_decimals,
        new_bonding_curve_bps: bonding_curve_bps,
        new_amm_reserve_bps: amm_reserve_bps,
        new_graduated_swap_fee_bps: graduated_swap_fee_bps,
    });
}

// Add admin function to withdraw fees
public entry fun withdraw_treasury(
    launchpad: &mut Launchpad,
    amount: u64,
    to_address: address,
    ctx: &mut TxContext,
) {
    // Only admin can withdraw
    assert!(launchpad.admin == tx_context::sender(ctx), E_NOT_ADMIN);

    // Check if we have enough balance
    let treasury_balance = balance::value(&launchpad.treasury);
    assert!(treasury_balance >= amount, E_INSUFFICIENT_BALANCE);

    // Split and transfer the requested amount
    let withdraw_balance = balance::split(&mut launchpad.treasury, amount);
    transfer::public_transfer(
        coin::from_balance(withdraw_balance, ctx),
        to_address,
    );
}

// Function to withdraw all funds
public entry fun withdraw_all_treasury(
    launchpad: &mut Launchpad,
    to_address: address,
    ctx: &mut TxContext,
) {
    // Only admin can withdraw
    assert!(launchpad.admin == tx_context::sender(ctx), E_NOT_ADMIN);

    // Get current treasury balance
    let treasury_balance = balance::value(&launchpad.treasury);

    // Skip if nothing to withdraw
    if (treasury_balance == 0) {
        return
    };

    // Take all funds and transfer
    let withdraw_balance = balance::split(&mut launchpad.treasury, treasury_balance);
    transfer::public_transfer(
        coin::from_balance(withdraw_balance, ctx),
        to_address,
    );
}

public fun add_to_treasury(launchpad: &mut Launchpad, payment: Balance<SUI>) {
    balance::join(&mut launchpad.treasury, payment);
}

public fun increment_coins_count(launchpad: &mut Launchpad) {
    launchpad.launched_coins_count = launchpad.launched_coins_count + 1;
}

public fun add_to_registry(registry: &mut LaunchedCoinsRegistry, coin_address: address) {
    vector::push_back(&mut registry.coins, coin_address);
}

// === View Functions ===
public fun get_launched_coins_count(launchpad: &Launchpad): u64 {
    launchpad.launched_coins_count
}

public fun get_launched_coins(registry: &LaunchedCoinsRegistry): vector<address> {
    *&registry.coins
}

public fun get_admin(launchpad: &Launchpad): address {
    launchpad.admin
}

public fun get_config(launchpad: &Launchpad): Configuration {
    launchpad.config
}

public fun get_platform_fee(launchpad: &Launchpad): u64 {
    launchpad.config.platform_fee
}

public fun get_creation_fee(launchpad: &Launchpad): u64 {
    launchpad.config.creation_fee
}

public fun get_graduation_fee(launchpad: &Launchpad): u64 {
    launchpad.config.graduation_fee
}

public fun get_initial_virtual_sui(launchpad: &Launchpad): u64 {
    launchpad.config.initial_virtual_sui
}

public fun get_initial_virtual_tokens(launchpad: &Launchpad): u64 {
    launchpad.config.initial_virtual_tokens
}

public fun get_token_decimals(launchpad: &Launchpad): u8 {
    launchpad.config.token_decimals
}

public fun get_version(launchpad: &Launchpad): u64 {
    launchpad.config.version
}

public fun get_treasury(launchpad: &Launchpad): &Balance<SUI> {
    &launchpad.treasury
}

// New: Getter functions for allocation percentages
public fun get_bonding_curve_bps(launchpad: &Launchpad): u64 {
    launchpad.config.bonding_curve_bps
}

public fun get_amm_reserve_bps(launchpad: &Launchpad): u64 {
    launchpad.config.amm_reserve_bps
}

public fun get_graduated_swap_fee_bps(launchpad: &Launchpad): u64 {
    launchpad.config.graduated_swap_fee_bps
}

public fun get_graduation_threshold(launchpad: &Launchpad): u64 {
    launchpad.config.graduation_threshold
}

// Helper function to calculate actual token amounts based on percentages
public fun calculate_bonding_curve_tokens(launchpad: &Launchpad): u64 {
    let total_tokens = launchpad.config.initial_virtual_tokens;
    (total_tokens * launchpad.config.bonding_curve_bps) / 10000
}

public fun calculate_amm_reserve_tokens(launchpad: &Launchpad): u64 {
    let total_tokens = launchpad.config.initial_virtual_tokens;
    (total_tokens * launchpad.config.amm_reserve_bps) / 10000
}

// Add test helper function
#[test_only]
public(package) fun create_launchpad_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
