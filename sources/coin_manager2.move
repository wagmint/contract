module wagmint::coin_manager2;

use std::string::{Self, String};
use std::type_name;
use std::u64;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::dynamic_object_field;
use sui::event;
use sui::object::{Self, UID};
use sui::sui::SUI;
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::url::{Self, Url};
use wagmint::curves;
use wagmint::utils;

// Error codes
const E_UNAUTHORIZED: u64 = 1;
const E_INVALID_INPUT: u64 = 2;
const E_INSUFFICIENT_PAYMENT: u64 = 6;
const E_POOL_COMPLETED: u64 = 5;
const E_INVALID_VERSION: u64 = 4;
const E_DUPLICATE_TOKEN: u64 = 7;

// Constants
const PLATFORM_FEE_BPS: u64 = 50; // 0.5%
const BPS_DENOMINATOR: u64 = 10000;
const DEFAULT_INIT_VIRTUAL_SUI: u64 = 3_000_000_000_000; // 3,000 SUI
const DEFAULT_INIT_VIRTUAL_TOKEN: u64 = 10_000_000_000_000_000; // 10T tokens
const DEFAULT_REMAIN_TOKEN: u64 = 2_000_000_000_000_000; // 2T tokens
const DEFAULT_DECIMAL: u8 = 6;
const GRADUATION_THRESHOLD: u64 = 6_000_000_000_000; // 6,000 SUI
const CURRENT_VERSION: u64 = 5;

// Configuration for all tokens
public struct Configuration has key, store {
    id: UID,
    version: u64,
    admin: address,
    platform_fee: u64,
    graduated_fee: u64,
    initial_virtual_sui_reserves: u64,
    initial_virtual_token_reserves: u64,
    remain_token_reserves: u64,
    token_decimals: u8,
}

// Pool for a specific token type
public struct Pool<phantom T> has key, store {
    id: UID,
    real_sui_reserves: Balance<SUI>,
    real_token_reserves: Balance<T>,
    virtual_sui_reserves: u64,
    virtual_token_reserves: u64,
    remain_token_reserves: Balance<T>,
    is_completed: bool,
}

// Events
public struct ConfigChangedEvent has copy, drop, store {
    old_platform_fee: u64,
    new_platform_fee: u64,
    old_graduated_fee: u64,
    new_graduated_fee: u64,
    old_initial_virtual_sui_reserves: u64,
    new_initial_virtual_sui_reserves: u64,
    old_initial_virtual_token_reserves: u64,
    new_initial_virtual_token_reserves: u64,
    old_remain_token_reserves: u64,
    new_remain_token_reserves: u64,
    old_token_decimals: u8,
    new_token_decimals: u8,
    ts: u64,
}

public struct CreatedEvent has copy, drop, store {
    name: String,
    symbol: String,
    uri: String,
    description: String,
    twitter: String,
    telegram: String,
    website: String,
    token_address: String,
    bonding_curve: String,
    pool_id: object::ID,
    created_by: address,
    virtual_sui_reserves: u64,
    virtual_token_reserves: u64,
    ts: u64,
}

public struct TradedEvent has copy, drop, store {
    is_buy: bool,
    user: address,
    token_address: String,
    sui_amount: u64,
    token_amount: u64,
    virtual_sui_reserves: u64,
    virtual_token_reserves: u64,
    pool_id: object::ID,
    ts: u64,
}

public struct OwnershipTransferredEvent has copy, drop, store {
    old_admin: address,
    new_admin: address,
    ts: u64,
}

// === Module initialization ===
fun init(ctx: &mut TxContext) {
    let config = Configuration {
        id: object::new(ctx),
        version: CURRENT_VERSION,
        admin: tx_context::sender(ctx),
        platform_fee: PLATFORM_FEE_BPS,
        graduated_fee: GRADUATION_THRESHOLD,
        initial_virtual_sui_reserves: DEFAULT_INIT_VIRTUAL_SUI,
        initial_virtual_token_reserves: DEFAULT_INIT_VIRTUAL_TOKEN,
        remain_token_reserves: DEFAULT_REMAIN_TOKEN,
        token_decimals: DEFAULT_DECIMAL,
    };
    transfer::public_share_object(config);
}

// === Helper functions ===

// Calculate transaction fee
public fun calculate_platform_fee(amount: u64, fee_bps: u64): u64 {
    utils::as_u64(
        utils::div(
            utils::mul(
                utils::from_u64(amount),
                utils::from_u64(fee_bps),
            ),
            utils::from_u64(BPS_DENOMINATOR),
        ),
    )
}

// Assert caller is admin
fun assert_admin(config: &Configuration, caller: address) {
    assert!(config.admin == caller, E_UNAUTHORIZED);
}

// Assert version compatibility
fun assert_version(version: u64) {
    assert!(version == CURRENT_VERSION, E_INVALID_VERSION);
}

// Assert LP value doesn't decrease (prevents manipulation)
fun assert_lp_value_is_increased_or_not_changed(
    old_token: u64,
    old_sui: u64,
    new_token: u64,
    new_sui: u64,
) {
    assert!(
        (old_token as u128) * (old_sui as u128) <= (new_token as u128) * (new_sui as u128),
        E_INVALID_INPUT,
    );
}

// Core swap logic for buys and sells
fun swap<T>(
    pool: &mut Pool<T>,
    token_in: Coin<T>,
    sui_in: Coin<SUI>,
    token_out: u64,
    sui_out: u64,
    ctx: &mut TxContext,
): (Balance<T>, Balance<SUI>) {
    // Ensure at least one side has value
    assert!(coin::value(&token_in) > 0 || coin::value(&sui_in) > 0, E_INVALID_INPUT);

    // Update virtual reserves for outgoing assets
    if (coin::value(&token_in) > 0) {
        pool.virtual_token_reserves = pool.virtual_token_reserves - token_out;
    };

    if (coin::value(&sui_in) > 0) {
        pool.virtual_sui_reserves = pool.virtual_sui_reserves - sui_out;
    };

    // Update virtual reserves for incoming assets
    pool.virtual_token_reserves = pool.virtual_token_reserves + coin::value(&token_in);
    pool.virtual_sui_reserves = pool.virtual_sui_reserves + coin::value(&sui_in);

    // Verify the pool value isn't being manipulated
    assert_lp_value_is_increased_or_not_changed(
        pool.virtual_token_reserves,
        pool.virtual_sui_reserves,
        pool.virtual_token_reserves,
        pool.virtual_sui_reserves,
    );

    // Join incoming assets to the pool
    balance::join(&mut pool.real_token_reserves, coin::into_balance(token_in));
    balance::join(&mut pool.real_sui_reserves, coin::into_balance(sui_in));

    // Split and return the outgoing assets
    (
        balance::split(&mut pool.real_token_reserves, token_out),
        balance::split(&mut pool.real_sui_reserves, sui_out),
    )
}

// Helper for buying tokens
fun buy_tokens_helper<T>(
    admin_address: address,
    platform_fee: u64,
    pool: &mut Pool<T>,
    payment: Coin<SUI>,
    token_amount: u64,
    ctx: &mut TxContext,
): (Balance<SUI>, Balance<T>) {
    // Verify pool is active
    assert!(!pool.is_completed, E_POOL_COMPLETED);
    assert!(token_amount > 0, E_INVALID_INPUT);

    // Calculate how many tokens are available
    let available_tokens =
        pool.virtual_token_reserves - balance::value(&pool.remain_token_reserves);
    let actual_token_amount = u64::min(token_amount, available_tokens);

    // Calculate costs
    let cost =
        curves::calculate_add_liquidity_cost(
            pool.virtual_sui_reserves, 
            pool.virtual_token_reserves, 
            actual_token_amount
        ) + 1;

    let fee = calculate_platform_fee(cost, platform_fee);

    // Verify sufficient payment
    let payment_amount = coin::value(&payment);
    assert!(payment_amount >= cost + fee, E_INSUFFICIENT_PAYMENT);

    // Execute swap
    let (tokens, sui_change) = swap(
        pool,
        coin::zero<T>(ctx),
        payment,
        actual_token_amount,
        payment_amount - cost - fee,
        ctx,
    );

    // Update virtual token reserves to reflect removed tokens
    pool.virtual_token_reserves = pool.virtual_token_reserves - balance::value(&tokens);

    // Split fee for admin
    let fee_balance = balance::split(&mut pool.real_sui_reserves, fee);
    let fee_coin = coin::from_balance(fee_balance, ctx);
    transfer::public_transfer(fee_coin, admin_address);

    // Tuple ordering: (change, tokens, fee)
    (sui_change, tokens)
}

// Helper for selling tokens
fun sell_tokens_helper<T>(
    admin_address: address,
    platform_fee: u64,
    pool: &mut Pool<T>,
    tokens: Coin<T>,
    min_sui_out: u64,
    ctx: &mut TxContext,
): Balance<SUI> {
    // Verify pool is active
    assert!(!pool.is_completed, E_POOL_COMPLETED);

    // Verify non-zero input
    let token_amount = coin::value(&tokens);
    assert!(token_amount > 0, E_INVALID_INPUT);

    // Calculate return amount
    let sui_return = curves::calculate_remove_liquidity_return(
        pool.virtual_token_reserves,
        pool.virtual_sui_reserves,
        token_amount,
    );

    // Calculate fee
    let fee = calculate_platform_fee(sui_return, platform_fee);

    // Verify minimum return requirement
    assert!(sui_return - fee >= min_sui_out, E_INVALID_INPUT);

    // Execute swap
    let (token_out, mut sui_out) = swap(
        pool,
        tokens,
        coin::zero<SUI>(ctx),
        0,
        sui_return,
        ctx,
    );
    balance::join(&mut pool.real_token_reserves, token_out);

    // Update virtual SUI reserves
    pool.virtual_sui_reserves = pool.virtual_sui_reserves - balance::value(&sui_out);

    // Split fee for admin
    let fee_balance = balance::split(&mut sui_out, fee);
    let fee_coin = coin::from_balance(fee_balance, ctx);
    transfer::public_transfer(fee_coin, admin_address);

    sui_out
}

// === Public entry functions ===

// Create a new token pool
public entry fun create<T>(
    config: &mut Configuration,
    mut treasury_cap: coin::TreasuryCap<T>,
    clock: &Clock,
    name: String,
    symbol: String,
    uri: String,
    description: String,
    twitter: String,
    telegram: String,
    website: String,
    ctx: &mut TxContext,
) {
    // Validate inputs
    assert!(string::length(&uri) <= 300, E_INVALID_INPUT);
    assert!(string::length(&description) <= 1000, E_INVALID_INPUT);
    assert!(string::length(&twitter) <= 500, E_INVALID_INPUT);
    assert!(string::length(&telegram) <= 500, E_INVALID_INPUT);
    assert!(string::length(&website) <= 500, E_INVALID_INPUT);

    // Verify token hasn't been minted yet
    assert!(coin::total_supply(&treasury_cap) == 0, E_DUPLICATE_TOKEN);

    // Burn the treasury cap to lock supply
    // First mint all the tokens we need
    let real_tokens = coin::mint<T>(
        &mut treasury_cap,
        config.initial_virtual_token_reserves - config.remain_token_reserves,
        ctx,
    );
    let remain_tokens = coin::mint<T>(&mut treasury_cap, config.remain_token_reserves, ctx);

    // Now burn the treasury cap to lock supply
    transfer::public_transfer(treasury_cap, @0x0);

    // Create the pool with the minted tokens
    let pool = Pool<T> {
        id: object::new(ctx),
        real_sui_reserves: balance::zero<SUI>(),
        real_token_reserves: coin::into_balance(real_tokens),
        virtual_token_reserves: config.initial_virtual_token_reserves,
        virtual_sui_reserves: config.initial_virtual_sui_reserves,
        remain_token_reserves: coin::into_balance(remain_tokens),
        is_completed: false,
    };

    // Store the pool
    let pool_id = object::id(&pool);
    let token_type = type_name::get<T>();
    dynamic_object_field::add(&mut config.id, type_name::get_address(&token_type), pool);

    // Emit creation event
    let pool_type = type_name::get<Pool<T>>();
    event::emit(CreatedEvent {
        name,
        symbol,
        uri,
        description,
        twitter,
        telegram,
        website,
        token_address: utils::ascii_to_string(&type_name::into_string(token_type)),
        bonding_curve: utils::ascii_to_string(&type_name::get_module(&pool_type)),
        pool_id: pool_id,
        created_by: tx_context::sender(ctx),
        virtual_sui_reserves: config.initial_virtual_sui_reserves,
        virtual_token_reserves: config.initial_virtual_token_reserves,
        ts: clock::timestamp_ms(clock),
    });
}

// Buy tokens
public entry fun buy<T>(
    config: &mut Configuration,
    payment: Coin<SUI>,
    token_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = tx_context::sender(ctx);
    assert_version(config.version);

    // Get the pool
    let token_type = type_name::get<T>();
    let pool = dynamic_object_field::borrow_mut<String, Pool<T>>(
        &mut config.id,
        utils::ascii_to_string(&type_name::get_address(&token_type)),
    );

    // Execute buy
    let original_payment_amount = coin::value(&payment);
    let (change, tokens) = buy_tokens_helper(
        config.admin,
        config.platform_fee,
        pool,
        payment,
        token_amount,
        ctx,
    );
    let change_amount = balance::value(&change);

    // Transfer tokens and change to buyer
    let change_coin = coin::from_balance(change, ctx);
    let tokens_coin = coin::from_balance(tokens, ctx);

    transfer::public_transfer(change_coin, sender);
    transfer::public_transfer(tokens_coin, sender);

    let spent_amount = original_payment_amount - change_amount;

    // Emit trade event
    event::emit(TradedEvent {
        is_buy: true,
        user: sender,
        token_address: utils::ascii_to_string(&type_name::into_string(token_type)),
        sui_amount: spent_amount,
        token_amount,
        virtual_sui_reserves: pool.virtual_sui_reserves,
        virtual_token_reserves: pool.virtual_token_reserves,
        pool_id: object::id(pool),
        ts: clock::timestamp_ms(clock),
    });
}

// Sell tokens
public entry fun sell<T>(
    config: &mut Configuration,
    tokens: Coin<T>,
    min_sui_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let sender = tx_context::sender(ctx);

    // Get the pool
    let token_type = type_name::get<T>();
    let pool = dynamic_object_field::borrow_mut<String, Pool<T>>(
        &mut config.id,
        utils::ascii_to_string(&type_name::get_address(&token_type)),
    );

    // Execute sell
    let token_amount = coin::value(&tokens);
    let sui_out = sell_tokens_helper(
        config.admin,
        config.platform_fee,
        pool,
        tokens,
        min_sui_out,
        ctx,
    );
    let sui_out_amount = balance::value(&sui_out);
    let sui_out_coin = coin::from_balance(sui_out, ctx);

    // Transfer SUI to seller
    transfer::public_transfer(sui_out_coin, sender);

    // Emit trade event
    event::emit(TradedEvent {
        is_buy: false,
        user: sender,
        token_address: utils::ascii_to_string(&type_name::into_string(token_type)),
        sui_amount: sui_out_amount,
        token_amount: token_amount,
        virtual_sui_reserves: pool.virtual_sui_reserves,
        virtual_token_reserves: pool.virtual_token_reserves,
        pool_id: object::id(pool),
        ts: clock::timestamp_ms(clock),
    });
}

// Update configuration
public entry fun update_config(
    config: &mut Configuration,
    platform_fee: u64,
    graduated_fee: u64,
    init_virtual_sui: u64,
    init_virtual_token: u64,
    remain_token: u64,
    decimals: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify caller is admin
    let sender = tx_context::sender(ctx);
    assert_admin(config, sender);

    // Store old values for event
    let old_platform_fee = config.platform_fee;
    let old_graduated_fee = config.graduated_fee;
    let old_init_virtual_sui = config.initial_virtual_sui_reserves;
    let old_init_virtual_token = config.initial_virtual_token_reserves;
    let old_remain_token = config.remain_token_reserves;
    let old_decimals = config.token_decimals;

    // Update config
    config.platform_fee = platform_fee;
    config.graduated_fee = graduated_fee;
    config.initial_virtual_sui_reserves = init_virtual_sui;
    config.initial_virtual_token_reserves = init_virtual_token;
    config.remain_token_reserves = remain_token;
    config.token_decimals = decimals;

    // Emit change event
    event::emit(ConfigChangedEvent {
        old_platform_fee: old_platform_fee,
        new_platform_fee: platform_fee,
        old_graduated_fee: old_graduated_fee,
        new_graduated_fee: graduated_fee,
        old_initial_virtual_sui_reserves: old_init_virtual_sui,
        new_initial_virtual_sui_reserves: init_virtual_sui,
        old_initial_virtual_token_reserves: old_init_virtual_token,
        new_initial_virtual_token_reserves: init_virtual_token,
        old_remain_token_reserves: old_remain_token,
        new_remain_token_reserves: remain_token,
        old_token_decimals: old_decimals,
        new_token_decimals: decimals,
        ts: clock::timestamp_ms(clock),
    });
}

// Transfer admin rights
public entry fun transfer_admin(
    config: &mut Configuration,
    new_admin: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Verify caller is admin
    let sender = tx_context::sender(ctx);
    assert_admin(config, sender);

    // Update admin
    let old_admin = config.admin;
    config.admin = new_admin;

    // Emit event
    event::emit(OwnershipTransferredEvent {
        old_admin,
        new_admin,
        ts: clock::timestamp_ms(clock),
    });
}

// Update version
public entry fun migrate_version(
    config: &mut Configuration,
    new_version: u64,
    ctx: &mut TxContext,
) {
    // Verify caller is admin
    let sender = tx_context::sender(ctx);
    assert_admin(config, sender);

    // Update version
    config.version = new_version;
}

// === View functions ===

// Get current price of token
public fun get_current_price<T>(config: &Configuration): u64 {
    let token_type = type_name::get<T>();
    let pool = dynamic_object_field::borrow<String, Pool<T>>(
        &config.id,
        utils::ascii_to_string(&type_name::get_address(&token_type)),
    );

    curves::calculate_price(pool.virtual_sui_reserves, pool.virtual_token_reserves)
}

// Get cost to buy specific amount
public fun get_purchase_cost<T>(config: &Configuration, amount: u64): u64 {
    let token_type = type_name::get<T>();
    let pool = dynamic_object_field::borrow<String, Pool<T>>(
        &config.id,
        utils::ascii_to_string(&type_name::get_address(&token_type)),
    );

    curves::calculate_add_liquidity_cost(
        pool.virtual_sui_reserves,
        pool.virtual_token_reserves,
        amount,
    )
}

// Get return amount for selling specific amount
public fun get_sale_return<T>(config: &Configuration, amount: u64): u64 {
    let token_type = type_name::get<T>();
    let pool = dynamic_object_field::borrow<String, Pool<T>>(
        &config.id,
        utils::ascii_to_string(&type_name::get_address(&token_type)),
    );

    curves::calculate_remove_liquidity_return(
        pool.virtual_token_reserves,
        pool.virtual_sui_reserves,
        amount,
    )
}

// Get supply and reserves
public fun get_pool_info<T>(config: &Configuration): (u64, u64, u64, bool) {
    let token_type = type_name::get<T>();
    let pool = dynamic_object_field::borrow<String, Pool<T>>(
        &config.id,
        utils::ascii_to_string(&type_name::get_address(&token_type)),
    );

    (
        pool.virtual_token_reserves,
        pool.virtual_sui_reserves,
        balance::value(&pool.remain_token_reserves),
        pool.is_completed,
    )
}

// Get configuration values
public fun get_config_info(config: &Configuration): (u64, address, u64, u64, u64, u64, u64, u8) {
    (
        config.version,
        config.admin,
        config.platform_fee,
        config.graduated_fee,
        config.initial_virtual_sui_reserves,
        config.initial_virtual_token_reserves,
        config.remain_token_reserves,
        config.token_decimals,
    )
}
