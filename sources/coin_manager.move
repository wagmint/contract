module wagmint::coin_manager;

use std::string::{String, as_bytes};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::sui::SUI;
use sui::url::{Self, Url};
use wagmint::battle_royale::{Self, BattleRoyale};
use wagmint::bonding_curve;
use wagmint::token_launcher::{Self, LaunchedCoinsRegistry};
use wagmint::utils;

// Error codes
const E_INVALID_NAME_LENGTH: u64 = 0;
const E_INVALID_SYMBOL_LENGTH: u64 = 1;
const E_INSUFFICIENT_PAYMENT: u64 = 2;
const E_INSUFFICIENT_BALANCE: u64 = 3;
const E_AMOUNT_TOO_SMALL: u64 = 4;
const E_ALREADY_GRADUATED: u64 = 6;
const E_BATTLE_ROYALE_NOT_ACTIVE_FOR_TRADE: u64 = 7;
const E_SLIPPAGE_EXCEEDED_BUY: u64 = 8;
const E_SLIPPAGE_EXCEEDED_SELL: u64 = 9;
const E_NOT_ELIGIBLE_FOR_GRADUATION: u64 = 10;
const E_GRADUATION_ALREADY_IN_PROGRESS: u64 = 11;

// Constants for validation
const MAX_NAME_LENGTH: u64 = 32;
const MAX_SYMBOL_LENGTH: u64 = 10;
const MIN_TRADE_AMOUNT: u64 = 1;

// Protected version of the treasury cap
public struct ProtectedTreasuryCap<phantom T> has store {
    cap: TreasuryCap<T>,
}

// This represents our custom coin properties
public struct CoinInfo<phantom T> has key, store {
    id: UID,
    name: String,
    symbol: String,
    description: String,
    image_url: Url,
    creator: address,
    launch_time: u64,
    protected_cap: ProtectedTreasuryCap<T>,
    // Token allocation tracking
    bonding_curve_tokens: u64, // Tokens allocated to bonding curve (80%)
    amm_reserve_tokens: u64, // Tokens reserved for AMM (20%)
    total_token_supply: u64, // Total planned supply (100%)
    // Real reserves - only bonding curve portion
    real_token_reserves: Balance<T>, // Tokens held by the bonding curve
    real_sui_reserves: Balance<SUI>, // Actual SUI reserves
    // Virtual reserves - for price calculation (full amount for curve continuity)
    virtual_token_reserves: u64, // Virtual tokens for curve calculation
    virtual_sui_reserves: u64, // Virtual SUI for curve calculation
    // Token metadata
    token_decimals: u8, // Decimal places for the token
    graduated: bool, // Has token graduated to DEX?
    supply: u64, // Total supply in circulation (from bonding curve)
    coin_type: String,
}

// Events
public struct CoinCreatedEvent has copy, drop {
    name: String,
    symbol: String,
    image_url: String,
    description: String,
    website: String,
    creator: address,
    coin_address: address,
    launch_time: u64,
    virtual_sui_reserves: u64,
    virtual_token_reserves: u64,
    real_sui_reserves: u64,
    real_token_reserves: u64,
    bonding_curve_tokens: u64,
    amm_reserve_tokens: u64,
    total_token_supply: u64,
    token_decimals: u8,
    coin_type: String,
    br_address: Option<address>,
}

public struct TradeEvent has copy, drop {
    is_buy: bool,
    coin_address: address,
    user_address: address,
    token_amount: u64,
    sui_amount: u64,
    platform_fee_amount: u64,
    battle_royale_fee_amount: u64,
    new_supply: u64,
    new_price: u64,
    new_virtual_sui_reserves: u64,
    new_virtual_token_reserves: u64,
    new_real_sui_reserves: u64,
    new_real_token_reserves: u64,
}

// Graduation event
public struct TokenGraduatedEvent has copy, drop {
    coin_address: address,
    graduation_time: u64,
    final_bonding_curve_price: u64,
    accumulated_sui_amount: u64,
    amm_reserve_tokens_minted: u64,
    total_supply_in_circulation: u64,
    creator: address,
    // AMM pool info (will be populated when integrated)
    amm_pool_id: Option<address>,
}

// Calculate transaction fee
public fun calculate_transaction_fee(amount: u64, transaction_fee_bps: u64): u64 {
    utils::as_u64(utils::percentage_of(utils::from_u64(amount), transaction_fee_bps))
}

// === Buy functionality ===
#[allow(lint(self_transfer))]
public fun buy_tokens_helper<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    mut payment: Coin<SUI>,
    amount: u64,
    ctx: &mut TxContext,
): (u64, u64) {
    // Ensure the token hasn't graduated yet
    assert!(!coin_info.graduated, E_ALREADY_GRADUATED);

    // Calculate tokens to mint based on the constant product formula
    let tokens_to_mint = bonding_curve::calculate_tokens_to_mint(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        amount,
    );

    // Calculate the fee
    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let fee = calculate_transaction_fee(amount, platform_fee);
    let total_cost = amount + fee;

    // Validate payment
    let payment_amount = coin::value(&payment);
    assert!(payment_amount >= total_cost, E_INSUFFICIENT_PAYMENT);

    if (payment_amount > total_cost) {
        // Return excess payment to sender
        let remainder = coin::split(&mut payment, payment_amount - total_cost, ctx);
        transfer::public_transfer(remainder, tx_context::sender(ctx));
    };

    // Process payment
    let mut paid_balance = coin::into_balance(payment);

    // Split and transfer fee
    let fee_payment = balance::split(&mut paid_balance, fee);
    token_launcher::add_to_treasury(launchpad, fee_payment);

    // Add remaining to real reserve
    balance::join(&mut coin_info.real_sui_reserves, paid_balance);

    // Update virtual reserves
    coin_info.virtual_sui_reserves = coin_info.virtual_sui_reserves + amount;
    coin_info.virtual_token_reserves = coin_info.virtual_token_reserves - tokens_to_mint;

    (tokens_to_mint, fee)
}

// === Sell functionality ===
public fun sell_tokens_helper<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    amount: u64,
    ctx: &mut TxContext,
): (u64, Coin<SUI>, u64) {
    // Ensure the token hasn't graduated yet
    assert!(!coin_info.graduated, E_ALREADY_GRADUATED);

    // Calculate return amount using bonding curve
    let return_cost = bonding_curve::calculate_sale_return(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        amount,
    );

    // Validate reserve has enough
    assert!(balance::value(&coin_info.real_sui_reserves) >= return_cost, E_INSUFFICIENT_BALANCE);

    // Calculate fee and final return amount
    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let fee = calculate_transaction_fee(return_cost, platform_fee);
    let final_return_cost = return_cost - fee;

    // Update virtual reserves
    coin_info.virtual_sui_reserves = coin_info.virtual_sui_reserves - return_cost;
    coin_info.virtual_token_reserves = coin_info.virtual_token_reserves + amount;

    // Take fee and return amount from reserve
    let fee_payment = balance::split(&mut coin_info.real_sui_reserves, fee);
    let return_payment = balance::split(&mut coin_info.real_sui_reserves, final_return_cost);

    // Transfer fee to treasury
    token_launcher::add_to_treasury(launchpad, fee_payment);

    let return_coin = coin::from_balance(return_payment, ctx);
    (return_cost, return_coin, fee)
}

// === Create Coin internal ===
#[allow(lint(self_transfer))]
public fun create_coin_internal<T>(
    launchpad: &mut token_launcher::Launchpad,
    treasury_cap: TreasuryCap<T>,
    registry: &mut LaunchedCoinsRegistry,
    mut payment: Coin<SUI>,
    name: String,
    symbol: String,
    description: String,
    website: String,
    image_url: String,
    coin_type: String,
    br_address: Option<address>,
    ctx: &mut TxContext,
): address {
    // Validate inputs
    assert!(
        std::string::length(&name) > 0 && std::string::length(&name) <= MAX_NAME_LENGTH,
        E_INVALID_NAME_LENGTH,
    );
    assert!(
        std::string::length(&symbol) > 0 && std::string::length(&symbol) <= MAX_SYMBOL_LENGTH,
        E_INVALID_SYMBOL_LENGTH,
    );

    // Determine fee
    let creation_fee = token_launcher::get_creation_fee(launchpad);

    // Validate payment
    let payment_amount = coin::value(&payment);
    assert!(payment_amount >= creation_fee, E_INSUFFICIENT_PAYMENT);

    // Take the fee and return change if necessary
    if (payment_amount > creation_fee) {
        // Return excess payment to sender
        let remainder = coin::split(&mut payment, payment_amount - creation_fee, ctx);
        transfer::public_transfer(remainder, tx_context::sender(ctx));
    };

    // Transfer the fee
    let paid_balance = coin::into_balance(payment);
    token_launcher::add_to_treasury(launchpad, paid_balance);

    // Wrap the treasury cap in the protected structure
    let mut protected_cap = ProtectedTreasuryCap<T> {
        cap: treasury_cap,
    };

    // Get configuration from launchpad
    let initial_virtual_sui = token_launcher::get_initial_virtual_sui(launchpad);
    let initial_virtual_tokens = token_launcher::get_initial_virtual_tokens(launchpad);
    let token_decimals = token_launcher::get_token_decimals(launchpad);

    // Calculate token allocation based on bonding_curve_tokens/amm_reserve_tokens split
    let bonding_curve_tokens = token_launcher::calculate_bonding_curve_tokens(launchpad);
    let amm_reserve_tokens = token_launcher::calculate_amm_reserve_tokens(launchpad);

    // Mint only the bonding curve tokens initially (bonding_curve_reserve %)
    let minted_tokens = coin::mint(
        &mut protected_cap.cap,
        bonding_curve_tokens,
        ctx,
    );
    let minted_balance = coin::into_balance(minted_tokens);

    let coin_info = CoinInfo<T> {
        id: object::new(ctx),
        name,
        symbol,
        description,
        image_url: url::new_unsafe_from_bytes(*as_bytes(&image_url)),
        creator: tx_context::sender(ctx),
        launch_time: tx_context::epoch(ctx),
        protected_cap,
        // Token allocation tracking
        bonding_curve_tokens,
        amm_reserve_tokens,
        total_token_supply: initial_virtual_tokens,
        // Real reserves (only bonding curve portion)
        real_token_reserves: minted_balance,
        real_sui_reserves: balance::zero(),
        // Virtual reserves (still use full amount for price calculation continuity)
        virtual_token_reserves: initial_virtual_tokens,
        virtual_sui_reserves: initial_virtual_sui,
        token_decimals,
        graduated: false,
        supply: 0, // No tokens in circulation yet
        coin_type: coin_type,
    };

    let coin_address = object::uid_to_address(&coin_info.id);

    // Emit creation event
    event::emit(CoinCreatedEvent {
        name,
        symbol,
        image_url,
        description,
        website,
        creator: tx_context::sender(ctx),
        coin_address,
        launch_time: tx_context::epoch(ctx),
        virtual_sui_reserves: coin_info.virtual_sui_reserves,
        virtual_token_reserves: coin_info.virtual_token_reserves,
        real_sui_reserves: balance::value(&coin_info.real_sui_reserves),
        real_token_reserves: balance::value(&coin_info.real_token_reserves),
        bonding_curve_tokens: coin_info.bonding_curve_tokens,
        amm_reserve_tokens: coin_info.amm_reserve_tokens,
        total_token_supply: coin_info.total_token_supply,
        token_decimals,
        coin_type: coin_info.coin_type,
        br_address,
    });

    token_launcher::increment_coins_count(launchpad);
    token_launcher::add_to_registry(registry, coin_address);

    // Share the coin info object
    transfer::share_object(coin_info);

    // Return the address so caller knows where to find it
    coin_address
}

// First we need function to create a new coin type
public entry fun create_coin<T>(
    launchpad: &mut token_launcher::Launchpad,
    treasury_cap: TreasuryCap<T>,
    registry: &mut LaunchedCoinsRegistry,
    payment: Coin<SUI>,
    name: String,
    symbol: String,
    description: String,
    website: String,
    image_url: String,
    coin_type: String,
    ctx: &mut TxContext,
): address {
    create_coin_internal(
        launchpad,
        treasury_cap,
        registry,
        payment,
        name,
        symbol,
        description,
        website,
        image_url,
        coin_type,
        option::none(),
        ctx,
    )
}

public entry fun buy_tokens<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    payment: Coin<SUI>,
    sui_amount: u64,
    min_tokens_out: u64,
    ctx: &mut TxContext,
) {
    // Validate amount
    assert!(sui_amount >= MIN_TRADE_AMOUNT, E_AMOUNT_TOO_SMALL);

    // Calculate what we would get (without executing)
    let expected_tokens = bonding_curve::calculate_tokens_to_mint(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        sui_amount,
    );

    // Check slippage BEFORE any state changes
    assert!(expected_tokens >= min_tokens_out, E_SLIPPAGE_EXCEEDED_BUY);

    // Use the bonding curve to calculate tokens and process payment
    let (tokens_to_mint, platform_fee_amount) = buy_tokens_helper(
        launchpad,
        coin_info,
        payment,
        sui_amount,
        ctx,
    );

    // Take tokens from real reserves
    let tokens = coin::take(
        &mut coin_info.real_token_reserves,
        tokens_to_mint,
        ctx,
    );

    // Transfer tokens to buyer
    transfer::public_transfer(tokens, tx_context::sender(ctx));

    // Update supply
    coin_info.supply = coin_info.supply + tokens_to_mint;

    // Calculate new price
    let new_price = bonding_curve::calculate_price(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
    );

    // Emit purchase event
    event::emit(TradeEvent {
        is_buy: true,
        coin_address: object::uid_to_address(&coin_info.id),
        user_address: tx_context::sender(ctx),
        token_amount: tokens_to_mint,
        sui_amount: sui_amount,
        platform_fee_amount,
        battle_royale_fee_amount: 0,
        new_supply: coin_info.supply,
        new_price,
        new_virtual_sui_reserves: coin_info.virtual_sui_reserves,
        new_virtual_token_reserves: coin_info.virtual_token_reserves,
        new_real_sui_reserves: balance::value(&coin_info.real_sui_reserves),
        new_real_token_reserves: balance::value(&coin_info.real_token_reserves),
    });
}

public entry fun sell_tokens<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    tokens: Coin<T>,
    min_sui_out: u64,
    ctx: &mut TxContext,
) {
    let token_amount = coin::value(&tokens);

    // Calculate what we would get (without executing)
    let gross_return = bonding_curve::calculate_sale_return(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        token_amount,
    );

    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let fee = calculate_transaction_fee(gross_return, platform_fee);
    let net_return = gross_return - fee;

    // Check slippage BEFORE any state changes
    assert!(net_return >= min_sui_out, E_SLIPPAGE_EXCEEDED_SELL);

    // Process the sell operation using bonding curve
    let (sui_amount, return_coin, platform_fee_amount) = sell_tokens_helper(
        launchpad,
        coin_info,
        token_amount,
        ctx,
    );

    // Update supply (decrease)
    coin_info.supply = coin_info.supply - token_amount;

    // Burn the tokens
    coin::burn(&mut coin_info.protected_cap.cap, tokens);

    // Transfer return amount to seller
    transfer::public_transfer(return_coin, tx_context::sender(ctx));

    // Calculate new price
    let new_price = bonding_curve::calculate_price(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
    );

    // Emit sell event
    event::emit(TradeEvent {
        is_buy: false,
        coin_address: object::uid_to_address(&coin_info.id),
        user_address: tx_context::sender(ctx),
        token_amount: token_amount,
        sui_amount: sui_amount,
        platform_fee_amount,
        battle_royale_fee_amount: 0,
        new_supply: coin_info.supply,
        new_price,
        new_virtual_sui_reserves: coin_info.virtual_sui_reserves,
        new_virtual_token_reserves: coin_info.virtual_token_reserves,
        new_real_sui_reserves: balance::value(&coin_info.real_sui_reserves),
        new_real_token_reserves: balance::value(&coin_info.real_token_reserves),
    });
}

// === Battle Royale ===
public entry fun create_coin_for_br<T>(
    launchpad: &mut token_launcher::Launchpad,
    treasury_cap: TreasuryCap<T>,
    registry: &mut LaunchedCoinsRegistry,
    battle_royale: &mut BattleRoyale,
    payment: Coin<SUI>,
    name: String,
    symbol: String,
    description: String,
    website: String,
    image_url: String,
    coin_type: String,
    ctx: &mut TxContext,
): address {
    let br_address = battle_royale::get_address(battle_royale);
    let coin_address = create_coin_internal(
        launchpad,
        treasury_cap,
        registry,
        payment,
        name,
        symbol,
        description,
        website,
        image_url,
        coin_type,
        option::some(br_address),
        ctx,
    );

    // Register the coin in the battle royale
    battle_royale::register_coin(battle_royale, coin_address, ctx);
    coin_address
}

public entry fun buy_tokens_with_br<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    payment: &mut Coin<SUI>,
    sui_amount: u64,
    min_tokens_out: u64,
    br: &mut BattleRoyale,
    ctx: &mut TxContext,
) {
    let current_epoch = tx_context::epoch(ctx);
    assert!(
        battle_royale::is_coin_valid_for_battle_royale(
            br,
            object::uid_to_address(&coin_info.id),
            current_epoch,
        ),
        E_BATTLE_ROYALE_NOT_ACTIVE_FOR_TRADE,
    );

    // Validate amount
    assert!(sui_amount >= MIN_TRADE_AMOUNT, E_AMOUNT_TOO_SMALL);

    // Get coin address
    let coin_address = object::uid_to_address(&coin_info.id);

    // Use the bonding curve to calculate tokens and process payment
    // Calculate tokens to mint based on the constant product formula
    let tokens_to_mint = bonding_curve::calculate_tokens_to_mint(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        sui_amount,
    );

    // Check slippage BEFORE any state changes
    assert!(tokens_to_mint >= min_tokens_out, E_SLIPPAGE_EXCEEDED_BUY);

    // Calculate the fee
    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let mut fee = calculate_transaction_fee(sui_amount, platform_fee);
    let total_cost = sui_amount + fee;

    // Validate payment
    assert!(coin::value(payment) >= total_cost, E_INSUFFICIENT_PAYMENT);

    // Process payment
    let paid = coin::split(payment, total_cost, ctx);
    let mut paid_balance = coin::into_balance(paid);

    // Calculate BR fee
    let br_fee_bps = battle_royale::get_br_fee_bps(br);
    let br_fee = utils::as_u64(utils::percentage_of(utils::from_u64(fee), br_fee_bps));
    if (
        battle_royale::is_coin_valid_for_battle_royale(br, coin_address, current_epoch) && br_fee > 0
    ) {
        // Create BR fee payment
        let br_fee_payment = balance::split(&mut paid_balance, br_fee);
        fee = fee - br_fee;

        // Contribute fee to BR
        battle_royale::contribute_trade_fee(launchpad, br, coin_address, br_fee_payment, ctx);
    };

    // Split and transfer fee
    let fee_payment = balance::split(&mut paid_balance, fee);
    token_launcher::add_to_treasury(launchpad, fee_payment);

    // Add remaining to real reserve
    balance::join(&mut coin_info.real_sui_reserves, paid_balance);

    // Update virtual reserves
    coin_info.virtual_sui_reserves = coin_info.virtual_sui_reserves + sui_amount;
    coin_info.virtual_token_reserves = coin_info.virtual_token_reserves - tokens_to_mint;

    // Take tokens from real reserves
    let tokens = coin::take(
        &mut coin_info.real_token_reserves,
        tokens_to_mint,
        ctx,
    );

    // Transfer tokens to buyer
    transfer::public_transfer(tokens, tx_context::sender(ctx));

    // Update supply
    coin_info.supply = coin_info.supply + tokens_to_mint;

    // Calculate new price
    let new_price = bonding_curve::calculate_price(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
    );

    // Emit purchase event
    event::emit(TradeEvent {
        is_buy: true,
        coin_address,
        user_address: tx_context::sender(ctx),
        token_amount: tokens_to_mint,
        sui_amount,
        platform_fee_amount: fee,
        battle_royale_fee_amount: br_fee,
        new_supply: coin_info.supply,
        new_price,
        new_virtual_sui_reserves: coin_info.virtual_sui_reserves,
        new_virtual_token_reserves: coin_info.virtual_token_reserves,
        new_real_sui_reserves: balance::value(&coin_info.real_sui_reserves),
        new_real_token_reserves: balance::value(&coin_info.real_token_reserves),
    });
}

public entry fun sell_tokens_with_br<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    tokens: Coin<T>,
    min_sui_out: u64,
    br: &mut BattleRoyale,
    ctx: &mut TxContext,
) {
    let current_epoch = tx_context::epoch(ctx);
    assert!(
        battle_royale::is_battle_royale_open(br, current_epoch),
        E_BATTLE_ROYALE_NOT_ACTIVE_FOR_TRADE,
    );

    let token_amount = coin::value(&tokens);

    // Get coin address
    let coin_address = object::uid_to_address(&coin_info.id);

    // Process the sell operation using bonding curve
    let return_cost = bonding_curve::calculate_sale_return(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        token_amount,
    );

    // Validate reserve has enough
    assert!(balance::value(&coin_info.real_sui_reserves) >= return_cost, E_INSUFFICIENT_BALANCE);

    // Calculate fee and final return amount
    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let fee = calculate_transaction_fee(return_cost, platform_fee);
    let final_return_cost = return_cost - fee;

    // Check slippage BEFORE any state changes
    assert!(final_return_cost >= min_sui_out, E_SLIPPAGE_EXCEEDED_SELL);

    // Update virtual reserves
    coin_info.virtual_sui_reserves = coin_info.virtual_sui_reserves - return_cost;
    coin_info.virtual_token_reserves = coin_info.virtual_token_reserves + token_amount;

    // Take fee and return amount from reserve
    let mut fee_payment = balance::split(&mut coin_info.real_sui_reserves, fee);
    let return_payment = balance::split(&mut coin_info.real_sui_reserves, final_return_cost);

    // If valid BR, collect fees
    let br_fee_bps = battle_royale::get_br_fee_bps(br);
    let br_fee = utils::as_u64(utils::percentage_of(utils::from_u64(fee), br_fee_bps));

    if (
        battle_royale::is_coin_valid_for_battle_royale(br, coin_address, current_epoch) && br_fee > 0
    ) {
        // Create BR fee payment
        let br_fee_payment = balance::split(&mut fee_payment, br_fee);

        // Contribute fee to BR
        battle_royale::contribute_trade_fee(launchpad, br, coin_address, br_fee_payment, ctx);
    };

    // Transfer fee to treasury
    token_launcher::add_to_treasury(launchpad, fee_payment);

    let return_coin = coin::from_balance(return_payment, ctx);

    // Update supply (decrease)
    coin_info.supply = coin_info.supply - token_amount;

    // Burn the tokens
    coin::burn(&mut coin_info.protected_cap.cap, tokens);

    // Transfer return amount to seller
    transfer::public_transfer(return_coin, tx_context::sender(ctx));

    // Calculate new price
    let new_price = bonding_curve::calculate_price(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
    );

    // Emit sell event
    event::emit(TradeEvent {
        is_buy: false,
        coin_address: object::uid_to_address(&coin_info.id),
        user_address: tx_context::sender(ctx),
        token_amount: token_amount,
        sui_amount: return_cost,
        platform_fee_amount: fee,
        battle_royale_fee_amount: br_fee,
        new_supply: coin_info.supply,
        new_price,
        new_virtual_sui_reserves: coin_info.virtual_sui_reserves,
        new_virtual_token_reserves: coin_info.virtual_token_reserves,
        new_real_sui_reserves: balance::value(&coin_info.real_sui_reserves),
        new_real_token_reserves: balance::value(&coin_info.real_token_reserves),
    });
}

// === Graduation Functions ===

// === Mock STEAMM Types for Testing ===
// TODO: Replace these with real STEAMM types when contracts are available

/// Mock registry for STEAMM (temporary)
public struct MockRegistry has key {
    id: UID,
    version: u64,
}

/// Mock lending market for Suilend integration (temporary)
public struct MockLendingMarket has key {
    id: UID,
    version: u64,
}

/// Mock bank for SUI deposits (temporary)
public struct MockBank has key {
    id: UID,
    token_type: String,
}

/// Mock pool result for AMM creation (temporary)
public struct MockPoolResult has copy, drop {
    pool_id: address,
    lp_token_amount: u64,
}

// === Mock STEAMM Events ===
public struct MockPoolCreatedEvent has copy, drop {
    pool_id: address,
    token_a_type: String,
    token_b_type: String,
    initial_liquidity_a: u64,
    initial_liquidity_b: u64,
    lp_tokens_minted: u64,
    creator: address,
}

// === Mock Helper Functions ===

/// Create mock registry for testing
public fun create_mock_registry(ctx: &mut TxContext): MockRegistry {
    MockRegistry {
        id: object::new(ctx),
        version: 1,
    }
}

/// Create mock lending market for testing
public fun create_mock_lending_market(ctx: &mut TxContext): MockLendingMarket {
    MockLendingMarket {
        id: object::new(ctx),
        version: 1,
    }
}

/// Create mock SUI bank for testing
public fun create_mock_sui_bank(ctx: &mut TxContext): MockBank {
    MockBank {
        id: object::new(ctx),
        token_type: std::string::utf8(b"SUI"),
    }
}

/// Mock AMM pool creation (simulates STEAMM integration)
fun mock_create_amm_pool(
    sui_amount: u64,
    token_amount: u64,
    _registry: &MockRegistry,
    _lending_market: &MockLendingMarket,
    _sui_bank: &MockBank,
    ctx: &TxContext,
): MockPoolResult {
    let pool_id = object::id_from_address(tx_context::sender(ctx));

    // Simulate LP token calculation (simple 1:1 for testing)
    let lp_tokens = sui_amount + token_amount;

    MockPoolResult {
        pool_id: object::id_to_address(&pool_id),
        lp_token_amount: lp_tokens,
    }
}

// Check if token is eligible for graduation
public fun check_graduation_eligibility<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &CoinInfo<T>,
): bool {
    if (coin_info.graduated) {
        return false
    };

    let market_cap = calculate_market_cap(coin_info);
    let graduation_threshold = token_launcher::get_graduation_threshold(launchpad);

    market_cap >= graduation_threshold
}

// Main graduation function
// Updated graduation function with mock STEAMM integration
public entry fun graduate_token<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    // Mock STEAMM dependencies (temporary - will be replaced with real objects)
    mock_registry: &MockRegistry,
    mock_lending_market: &MockLendingMarket,
    mock_sui_bank: &MockBank,
    ctx: &mut TxContext,
) {
    // 1. Validate graduation eligibility
    assert!(!coin_info.graduated, E_ALREADY_GRADUATED);
    assert!(check_graduation_eligibility(launchpad, coin_info), E_NOT_ELIGIBLE_FOR_GRADUATION);

    // Store some values before we modify the state
    let final_bc_price = get_current_price(coin_info);
    let creator = coin_info.creator;
    let coin_address = object::uid_to_address(&coin_info.id);

    // 2. Extract accumulated SUI from bonding curve
    let accumulated_sui_balance = balance::withdraw_all(&mut coin_info.real_sui_reserves);
    let accumulated_sui_amount = balance::value(&accumulated_sui_balance);

    // 3. Mint the reserved tokens for AMM (20% of total supply)
    let amm_reserve_tokens = coin::mint(
        &mut coin_info.protected_cap.cap,
        coin_info.amm_reserve_tokens,
        ctx,
    );
    let amm_reserve_tokens_minted = coin::value(&amm_reserve_tokens);

    // 4. Mark as graduated (disables bonding curve trading)
    coin_info.graduated = true;

    // 5. MOCK STEAMM Integration (TODO: Replace with real STEAMM calls)

    // STEP 1: Mock - Check/create bToken and bank for custom token
    // TODO: Replace with real bank creation:
    // let custom_token_bank = if (!has_bank_for_token<T>()) {
    //     create_bank_for_token<T>(mock_registry, mock_lending_market, ctx)
    // } else {
    //     get_existing_bank<T>()
    // };

    // STEP 2: Mock - Create LP token type
    // TODO: Replace with real LP token creation:
    // let lp_treasury = create_lp_token_type<SUI, T>(ctx);

    // STEP 3: Mock - Create AMM pool and deposit liquidity
    let mock_pool_result = mock_create_amm_pool(
        accumulated_sui_amount,
        amm_reserve_tokens_minted,
        mock_registry,
        mock_lending_market,
        mock_sui_bank,
        ctx,
    );

    // Emit mock pool creation event
    event::emit(MockPoolCreatedEvent {
        pool_id: mock_pool_result.pool_id,
        token_a_type: std::string::utf8(b"SUI"),
        token_b_type: coin_info.coin_type,
        initial_liquidity_a: accumulated_sui_amount,
        initial_liquidity_b: amm_reserve_tokens_minted,
        lp_tokens_minted: mock_pool_result.lp_token_amount,
        creator,
    });

    // TODO: When real STEAMM is available, replace above with:
    // let pool = pool::new<B_SUI, B_CUSTOM_TOKEN, CpQuoter, LP_TOKEN>(
    //     mock_registry,
    //     30, // fee tier bps
    //     quoter,
    //     sui_metadata,
    //     custom_token_metadata,
    //     &mut lp_metadata,
    //     lp_treasury,
    //     ctx
    // );
    //
    // let (lp_tokens, _) = pool::deposit_liquidity(
    //     &mut pool,
    //     &mut sui_coin_from_accumulated,
    //     &mut amm_reserve_tokens,
    //     accumulated_sui_amount,
    //     amm_reserve_tokens_minted,
    //     ctx
    // );

    // For now, transfer liquidity to creator (will be replaced with LP tokens)
    transfer::public_transfer(coin::from_balance(accumulated_sui_balance, ctx), creator);
    transfer::public_transfer(amm_reserve_tokens, creator);

    // Emit graduation event with mock pool info
    event::emit(TokenGraduatedEvent {
        coin_address,
        graduation_time: tx_context::epoch(ctx),
        final_bonding_curve_price: final_bc_price,
        accumulated_sui_amount,
        amm_reserve_tokens_minted,
        total_supply_in_circulation: coin_info.supply,
        creator,
        amm_pool_id: option::some(mock_pool_result.pool_id), // Mock pool ID
    });
}

// === Mock Setup Functions for Testing ===

/// Initialize mock STEAMM environment for testing
/// Call this once to set up mock objects, then use them for graduation testing
public entry fun setup_mock_steamm_environment(ctx: &mut TxContext) {
    // Create mock objects
    let mock_registry = create_mock_registry(ctx);
    let mock_lending_market = create_mock_lending_market(ctx);
    let mock_sui_bank = create_mock_sui_bank(ctx);

    // Share them so they can be used in graduation calls
    transfer::share_object(mock_registry);
    transfer::share_object(mock_lending_market);
    transfer::share_object(mock_sui_bank);
}

/// Test function to verify mock graduation works
/// This can be called after creating a token and getting it to graduation threshold
public entry fun test_graduation_with_mocks<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    mock_registry: &MockRegistry,
    mock_lending_market: &MockLendingMarket,
    mock_sui_bank: &MockBank,
    ctx: &mut TxContext,
) {
    // Just call the regular graduation function
    graduate_token<T>(
        launchpad,
        coin_info,
        mock_registry,
        mock_lending_market,
        mock_sui_bank,
        ctx,
    );
}

// Helper function to estimate graduation readiness
public fun get_graduation_progress<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &CoinInfo<T>,
): (u64, u64, u64) {
    let current_market_cap = calculate_market_cap(coin_info);
    let graduation_threshold = token_launcher::get_graduation_threshold(launchpad);

    let progress_percentage = if (graduation_threshold > 0) {
        utils::as_u64(
            utils::div(
                utils::mul(utils::from_u64(current_market_cap), utils::from_u64(10000)),
                utils::from_u64(graduation_threshold),
            ),
        )
    } else {
        0
    };

    (current_market_cap, graduation_threshold, progress_percentage)
}

// Get estimated AMM liquidity upon graduation
public fun get_estimated_amm_liquidity<T>(coin_info: &CoinInfo<T>): (u64, u64) {
    let estimated_sui_liquidity = balance::value(&coin_info.real_sui_reserves);
    let estimated_token_liquidity = coin_info.amm_reserve_tokens;

    (estimated_sui_liquidity, estimated_token_liquidity)
}

// Get AMM reserve tokens (these will be minted during graduation)
public fun get_amm_reserve_tokens<T>(coin_info: &CoinInfo<T>): u64 {
    coin_info.amm_reserve_tokens
}

// Get bonding curve tokens
public fun get_bonding_curve_tokens<T>(coin_info: &CoinInfo<T>): u64 {
    coin_info.bonding_curve_tokens
}

// View functions
public fun get_coin_info<T>(info: &CoinInfo<T>): (String, String, Url, address, u64, u64) {
    (
        info.name,
        info.symbol,
        info.image_url,
        info.creator,
        info.supply,
        balance::value(&info.real_sui_reserves),
    )
}

// Get current spot price of the coin
public fun get_current_price<T>(coin_info: &CoinInfo<T>): u64 {
    bonding_curve::calculate_price(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
    )
}

// Calculate market cap
public fun calculate_market_cap<T>(coin_info: &CoinInfo<T>): u64 {
    let price = get_current_price(coin_info);
    let circulating_supply = coin_info.supply; // Tokens actually in circulation
    utils::as_u64(
        utils::mul(utils::from_u64(price), utils::from_u64(circulating_supply)),
    )
}

// Get coin ID
public fun get_coin_address<T>(info: &CoinInfo<T>): address {
    object::uid_to_address(&info.id)
}

// Get just the supply
public fun get_supply<T>(info: &CoinInfo<T>): u64 {
    info.supply
}

// Get just the real reserve balance
public fun get_real_sui_reserves<T>(info: &CoinInfo<T>): u64 {
    balance::value(&info.real_sui_reserves)
}

// Get real token reserves
public fun get_real_token_reserves<T>(info: &CoinInfo<T>): u64 {
    balance::value(&info.real_token_reserves)
}

// Get virtual SUI reserves
public fun get_virtual_sui_reserves<T>(info: &CoinInfo<T>): u64 {
    info.virtual_sui_reserves
}

// Get virtual token reserves
public fun get_virtual_token_reserves<T>(info: &CoinInfo<T>): u64 {
    info.virtual_token_reserves
}

// Get token decimals
public fun get_token_decimals<T>(info: &CoinInfo<T>): u8 {
    info.token_decimals
}

// Check if token has graduated
public fun has_graduated<T>(info: &CoinInfo<T>): bool {
    info.graduated
}

// Get creator address
public fun get_creator<T>(info: &CoinInfo<T>): address {
    info.creator
}

// Get launch time
public fun get_launch_time<T>(info: &CoinInfo<T>): u64 {
    info.launch_time
}

// Get symbol
public fun get_symbol<T>(info: &CoinInfo<T>): String {
    info.symbol
}

// Get name
public fun get_name<T>(info: &CoinInfo<T>): String {
    info.name
}

// Get image URL
public fun get_image_url<T>(info: &CoinInfo<T>): Url {
    info.image_url
}

// Get total token supply
public fun get_total_token_supply<T>(info: &CoinInfo<T>): u64 {
    info.total_token_supply
}

// Extracted validation logic for testing
public fun validate_inputs(name: String, symbol: String): bool {
    std::string::length(&name) > 0 && 
    std::string::length(&name) <= MAX_NAME_LENGTH &&
    std::string::length(&symbol) > 0 && 
    std::string::length(&symbol) <= MAX_SYMBOL_LENGTH
}
