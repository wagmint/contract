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

// === Error Codes ===
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

// === Constants ===
const MAX_NAME_LENGTH: u64 = 32;
const MAX_SYMBOL_LENGTH: u64 = 10;
const MIN_TRADE_AMOUNT: u64 = 1;

// === Core Structs ===

/// Protected version of the treasury cap to prevent direct access
public struct ProtectedTreasuryCap<phantom T> has store {
    cap: TreasuryCap<T>,
}

/// Main coin information and bonding curve state
public struct CoinInfo<phantom T> has key, store {
    id: UID,
    // Metadata
    name: String,
    symbol: String,
    description: String,
    image_url: Url,
    creator: address,
    launch_time: u64,
    coin_type: String,
    token_decimals: u8,
    // Treasury and supply tracking
    protected_cap: ProtectedTreasuryCap<T>,
    supply: u64, // Total supply in circulation (from bonding curve)
    // Token allocation (80/20 split)
    bonding_curve_tokens: u64, // Tokens allocated to bonding curve (80%)
    amm_reserve_tokens: u64, // Tokens reserved for AMM (20%)
    total_token_supply: u64, // Total planned supply (100%)
    // Real reserves (actual tokens/SUI held)
    real_token_reserves: Balance<T>, // Tokens held by the bonding curve
    real_sui_reserves: Balance<SUI>, // Actual SUI reserves
    // Virtual reserves (for price calculation - maintains curve continuity)
    virtual_token_reserves: u64, // Virtual tokens for curve calculation
    virtual_sui_reserves: u64, // Virtual SUI for curve calculation
    // State
    graduated: bool, // Has token graduated to DEX?
}

// === Mock STEAMM Types (Temporary) ===
// TODO: Replace these with real STEAMM types when contracts are available

/// Mock registry for STEAMM
public struct MockRegistry has key {
    id: UID,
    version: u64,
}

/// Mock lending market for Suilend integration
public struct MockLendingMarket has key {
    id: UID,
    version: u64,
}

/// Mock bank for SUI deposits
public struct MockBank has key {
    id: UID,
    token_type: String,
}

/// Mock pool result for AMM creation
public struct MockPoolResult has copy, drop {
    pool_id: address,
    lp_token_amount: u64,
}

// === Events ===

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

public struct TokenGraduatedEvent has copy, drop {
    coin_address: address,
    graduation_time: u64,
    final_bonding_curve_price: u64,
    accumulated_sui_amount: u64,
    amm_reserve_tokens_minted: u64,
    total_supply_in_circulation: u64,
    creator: address,
    amm_pool_id: Option<address>,
}

public struct MockPoolCreatedEvent has copy, drop {
    pool_id: address,
    token_a_type: String,
    token_b_type: String,
    initial_liquidity_a: u64,
    initial_liquidity_b: u64,
    lp_tokens_minted: u64,
    creator: address,
}

// === Utility Functions ===

/// Calculate transaction fee based on amount and basis points
public fun calculate_transaction_fee(amount: u64, transaction_fee_bps: u64): u64 {
    utils::as_u64(utils::percentage_of(utils::from_u64(amount), transaction_fee_bps))
}

/// Validate coin name and symbol inputs
public fun validate_inputs(name: String, symbol: String): bool {
    std::string::length(&name) > 0 && 
    std::string::length(&name) <= MAX_NAME_LENGTH &&
    std::string::length(&symbol) > 0 && 
    std::string::length(&symbol) <= MAX_SYMBOL_LENGTH
}

// === Trading Helper Functions ===

/// Internal helper for buy token logic
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

    // Calculate and process fees
    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let fee = calculate_transaction_fee(amount, platform_fee);
    let total_cost = amount + fee;

    // Validate and process payment
    let payment_amount = coin::value(&payment);
    assert!(payment_amount >= total_cost, E_INSUFFICIENT_PAYMENT);

    if (payment_amount > total_cost) {
        let remainder = coin::split(&mut payment, payment_amount - total_cost, ctx);
        transfer::public_transfer(remainder, tx_context::sender(ctx));
    };

    // Split payment between fee and reserves
    let mut paid_balance = coin::into_balance(payment);
    let fee_payment = balance::split(&mut paid_balance, fee);
    token_launcher::add_to_treasury(launchpad, fee_payment);
    balance::join(&mut coin_info.real_sui_reserves, paid_balance);

    // Update virtual reserves for price calculation
    coin_info.virtual_sui_reserves = coin_info.virtual_sui_reserves + amount;
    coin_info.virtual_token_reserves = coin_info.virtual_token_reserves - tokens_to_mint;

    (tokens_to_mint, fee)
}

/// Internal helper for sell token logic
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

    // Validate sufficient reserves
    assert!(balance::value(&coin_info.real_sui_reserves) >= return_cost, E_INSUFFICIENT_BALANCE);

    // Calculate fees and final return
    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let fee = calculate_transaction_fee(return_cost, platform_fee);
    let final_return_cost = return_cost - fee;

    // Update virtual reserves
    coin_info.virtual_sui_reserves = coin_info.virtual_sui_reserves - return_cost;
    coin_info.virtual_token_reserves = coin_info.virtual_token_reserves + amount;

    // Process payments
    let fee_payment = balance::split(&mut coin_info.real_sui_reserves, fee);
    let return_payment = balance::split(&mut coin_info.real_sui_reserves, final_return_cost);

    token_launcher::add_to_treasury(launchpad, fee_payment);
    let return_coin = coin::from_balance(return_payment, ctx);

    (return_cost, return_coin, fee)
}

// === Core Token Creation ===

/// Internal coin creation logic (shared between regular and battle royale)
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
    assert!(validate_inputs(name, symbol), E_INVALID_NAME_LENGTH);

    // Process creation fee
    let creation_fee = token_launcher::get_creation_fee(launchpad);
    let payment_amount = coin::value(&payment);
    assert!(payment_amount >= creation_fee, E_INSUFFICIENT_PAYMENT);

    if (payment_amount > creation_fee) {
        let remainder = coin::split(&mut payment, payment_amount - creation_fee, ctx);
        transfer::public_transfer(remainder, tx_context::sender(ctx));
    };

    let paid_balance = coin::into_balance(payment);
    token_launcher::add_to_treasury(launchpad, paid_balance);

    // Setup token parameters
    let mut protected_cap = ProtectedTreasuryCap<T> { cap: treasury_cap };
    let initial_virtual_sui = token_launcher::get_initial_virtual_sui(launchpad);
    let initial_virtual_tokens = token_launcher::get_initial_virtual_tokens(launchpad);
    let token_decimals = token_launcher::get_token_decimals(launchpad);
    let bonding_curve_tokens = token_launcher::calculate_bonding_curve_tokens(launchpad);
    let amm_reserve_tokens = token_launcher::calculate_amm_reserve_tokens(launchpad);

    // Mint only bonding curve tokens (80% of total)
    let minted_tokens = coin::mint(&mut protected_cap.cap, bonding_curve_tokens, ctx);
    let minted_balance = coin::into_balance(minted_tokens);

    // Create coin info object
    let coin_info = CoinInfo<T> {
        id: object::new(ctx),
        // Metadata
        name,
        symbol,
        description,
        image_url: url::new_unsafe_from_bytes(*as_bytes(&image_url)),
        creator: tx_context::sender(ctx),
        launch_time: tx_context::epoch(ctx),
        coin_type,
        token_decimals,
        // Treasury and supply
        protected_cap,
        supply: 0,
        // Token allocation
        bonding_curve_tokens,
        amm_reserve_tokens,
        total_token_supply: initial_virtual_tokens,
        // Reserves
        real_token_reserves: minted_balance,
        real_sui_reserves: balance::zero(),
        virtual_token_reserves: initial_virtual_tokens,
        virtual_sui_reserves: initial_virtual_sui,
        // State
        graduated: false,
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

    // Update registry
    token_launcher::increment_coins_count(launchpad);
    token_launcher::add_to_registry(registry, coin_address);
    transfer::share_object(coin_info);

    coin_address
}

// === Public Entry Functions ===

/// Create a new token with bonding curve
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

/// Buy tokens from bonding curve
public entry fun buy_tokens<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    payment: Coin<SUI>,
    sui_amount: u64,
    min_tokens_out: u64,
    ctx: &mut TxContext,
) {
    // Validate inputs
    assert!(sui_amount >= MIN_TRADE_AMOUNT, E_AMOUNT_TOO_SMALL);

    // Check slippage protection
    let expected_tokens = bonding_curve::calculate_tokens_to_mint(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        sui_amount,
    );
    assert!(expected_tokens >= min_tokens_out, E_SLIPPAGE_EXCEEDED_BUY);

    // Process purchase
    let (tokens_to_mint, platform_fee_amount) = buy_tokens_helper(
        launchpad,
        coin_info,
        payment,
        sui_amount,
        ctx,
    );

    // Transfer tokens to buyer
    let tokens = coin::take(&mut coin_info.real_token_reserves, tokens_to_mint, ctx);
    transfer::public_transfer(tokens, tx_context::sender(ctx));

    // Update supply and emit event
    coin_info.supply = coin_info.supply + tokens_to_mint;
    let new_price = get_current_price(coin_info);

    event::emit(TradeEvent {
        is_buy: true,
        coin_address: object::uid_to_address(&coin_info.id),
        user_address: tx_context::sender(ctx),
        token_amount: tokens_to_mint,
        sui_amount,
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

/// Sell tokens back to bonding curve
public entry fun sell_tokens<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    tokens: Coin<T>,
    min_sui_out: u64,
    ctx: &mut TxContext,
) {
    let token_amount = coin::value(&tokens);

    // Check slippage protection
    let gross_return = bonding_curve::calculate_sale_return(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        token_amount,
    );
    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let fee = calculate_transaction_fee(gross_return, platform_fee);
    let net_return = gross_return - fee;
    assert!(net_return >= min_sui_out, E_SLIPPAGE_EXCEEDED_SELL);

    // Process sale
    let (sui_amount, return_coin, platform_fee_amount) = sell_tokens_helper(
        launchpad,
        coin_info,
        token_amount,
        ctx,
    );

    // Burn tokens and transfer SUI
    coin_info.supply = coin_info.supply - token_amount;
    coin::burn(&mut coin_info.protected_cap.cap, tokens);
    transfer::public_transfer(return_coin, tx_context::sender(ctx));

    // Emit event
    let new_price = get_current_price(coin_info);
    event::emit(TradeEvent {
        is_buy: false,
        coin_address: object::uid_to_address(&coin_info.id),
        user_address: tx_context::sender(ctx),
        token_amount,
        sui_amount,
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

// === Graduation Functions ===

/// Check if token meets graduation requirements
public fun check_graduation_eligibility<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &CoinInfo<T>,
): bool {
    if (coin_info.graduated) return false;

    let market_cap = calculate_market_cap(coin_info);
    let graduation_threshold = token_launcher::get_graduation_threshold(launchpad);
    market_cap >= graduation_threshold
}

/// Graduate token to AMM (with mock STEAMM integration)
public entry fun graduate_token<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    mock_registry: &MockRegistry,
    mock_lending_market: &MockLendingMarket,
    mock_sui_bank: &MockBank,
    ctx: &mut TxContext,
) {
    // Validate graduation eligibility
    assert!(!coin_info.graduated, E_ALREADY_GRADUATED);
    assert!(check_graduation_eligibility(launchpad, coin_info), E_NOT_ELIGIBLE_FOR_GRADUATION);

    // Store values before state changes
    let final_bc_price = get_current_price(coin_info);
    let creator = coin_info.creator;
    let coin_address = object::uid_to_address(&coin_info.id);

    // Extract all SUI from bonding curve
    let accumulated_sui_balance = balance::withdraw_all(&mut coin_info.real_sui_reserves);
    let accumulated_sui_amount = balance::value(&accumulated_sui_balance);

    // Mint reserved tokens for AMM (20% of total supply)
    let amm_reserve_tokens = coin::mint(
        &mut coin_info.protected_cap.cap,
        coin_info.amm_reserve_tokens,
        ctx,
    );
    let amm_reserve_tokens_minted = coin::value(&amm_reserve_tokens);

    // Mark as graduated (disables bonding curve)
    coin_info.graduated = true;

    // Mock STEAMM pool creation
    let mock_pool_result = mock_create_amm_pool(
        accumulated_sui_amount,
        amm_reserve_tokens_minted,
        mock_registry,
        mock_lending_market,
        mock_sui_bank,
        ctx,
    );

    // Emit events
    event::emit(MockPoolCreatedEvent {
        pool_id: mock_pool_result.pool_id,
        token_a_type: std::string::utf8(b"SUI"),
        token_b_type: coin_info.coin_type,
        initial_liquidity_a: accumulated_sui_amount,
        initial_liquidity_b: amm_reserve_tokens_minted,
        lp_tokens_minted: mock_pool_result.lp_token_amount,
        creator,
    });

    // Transfer liquidity to creator (temporary)
    transfer::public_transfer(coin::from_balance(accumulated_sui_balance, ctx), creator);
    transfer::public_transfer(amm_reserve_tokens, creator);

    event::emit(TokenGraduatedEvent {
        coin_address,
        graduation_time: tx_context::epoch(ctx),
        final_bonding_curve_price: final_bc_price,
        accumulated_sui_amount,
        amm_reserve_tokens_minted,
        total_supply_in_circulation: coin_info.supply,
        creator,
        amm_pool_id: option::some(mock_pool_result.pool_id),
    });
}

// === Mock STEAMM Functions ===

/// Create mock registry for testing
public fun create_mock_registry(ctx: &mut TxContext): MockRegistry {
    MockRegistry { id: object::new(ctx), version: 1 }
}

/// Create mock lending market for testing
public fun create_mock_lending_market(ctx: &mut TxContext): MockLendingMarket {
    MockLendingMarket { id: object::new(ctx), version: 1 }
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
    let lp_tokens = sui_amount + token_amount; // Simple 1:1 calculation

    MockPoolResult {
        pool_id: object::id_to_address(&pool_id),
        lp_token_amount: lp_tokens,
    }
}

/// Initialize mock STEAMM environment for testing
public entry fun setup_mock_steamm_environment(ctx: &mut TxContext) {
    let mock_registry = create_mock_registry(ctx);
    let mock_lending_market = create_mock_lending_market(ctx);
    let mock_sui_bank = create_mock_sui_bank(ctx);

    transfer::share_object(mock_registry);
    transfer::share_object(mock_lending_market);
    transfer::share_object(mock_sui_bank);
}

/// Test graduation function with mocks
public entry fun test_graduation_with_mocks<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    mock_registry: &MockRegistry,
    mock_lending_market: &MockLendingMarket,
    mock_sui_bank: &MockBank,
    ctx: &mut TxContext,
) {
    graduate_token<T>(launchpad, coin_info, mock_registry, mock_lending_market, mock_sui_bank, ctx);
}

// === View Functions ===

/// Get current token price from bonding curve
public fun get_current_price<T>(coin_info: &CoinInfo<T>): u64 {
    bonding_curve::calculate_price(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
    )
}

/// Calculate current market cap
public fun calculate_market_cap<T>(coin_info: &CoinInfo<T>): u64 {
    let price = get_current_price(coin_info);
    let circulating_supply = coin_info.supply;
    utils::as_u64(utils::mul(utils::from_u64(price), utils::from_u64(circulating_supply)))
}

/// Get graduation progress information
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
    } else { 0 };

    (current_market_cap, graduation_threshold, progress_percentage)
}

/// Get estimated AMM liquidity upon graduation
public fun get_estimated_amm_liquidity<T>(coin_info: &CoinInfo<T>): (u64, u64) {
    (balance::value(&coin_info.real_sui_reserves), coin_info.amm_reserve_tokens)
}

// === Simple Getters ===

public fun get_coin_address<T>(info: &CoinInfo<T>): address { object::uid_to_address(&info.id) }

public fun get_supply<T>(info: &CoinInfo<T>): u64 { info.supply }

public fun get_real_sui_reserves<T>(info: &CoinInfo<T>): u64 {
    balance::value(&info.real_sui_reserves)
}

public fun get_real_token_reserves<T>(info: &CoinInfo<T>): u64 {
    balance::value(&info.real_token_reserves)
}

public fun get_virtual_sui_reserves<T>(info: &CoinInfo<T>): u64 { info.virtual_sui_reserves }

public fun get_virtual_token_reserves<T>(info: &CoinInfo<T>): u64 { info.virtual_token_reserves }

public fun get_token_decimals<T>(info: &CoinInfo<T>): u8 { info.token_decimals }

public fun has_graduated<T>(info: &CoinInfo<T>): bool { info.graduated }

public fun get_creator<T>(info: &CoinInfo<T>): address { info.creator }

public fun get_launch_time<T>(info: &CoinInfo<T>): u64 { info.launch_time }

public fun get_symbol<T>(info: &CoinInfo<T>): String { info.symbol }

public fun get_name<T>(info: &CoinInfo<T>): String { info.name }

public fun get_image_url<T>(info: &CoinInfo<T>): Url { info.image_url }

public fun get_total_token_supply<T>(info: &CoinInfo<T>): u64 { info.total_token_supply }

public fun get_amm_reserve_tokens<T>(info: &CoinInfo<T>): u64 { info.amm_reserve_tokens }

public fun get_bonding_curve_tokens<T>(info: &CoinInfo<T>): u64 { info.bonding_curve_tokens }

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

// === Battle Royale Functions ===
// Note: Battle Royale functions are less frequently used but provide competitive token launches

/// Create a token for battle royale competition
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

    battle_royale::register_coin(battle_royale, coin_address, ctx);
    coin_address
}

/// Buy tokens with battle royale fee sharing
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
    let coin_address = object::uid_to_address(&coin_info.id);

    // Validate battle royale eligibility
    assert!(
        battle_royale::is_coin_valid_for_battle_royale(br, coin_address, current_epoch),
        E_BATTLE_ROYALE_NOT_ACTIVE_FOR_TRADE,
    );
    assert!(sui_amount >= MIN_TRADE_AMOUNT, E_AMOUNT_TOO_SMALL);

    // Check slippage protection
    let tokens_to_mint = bonding_curve::calculate_tokens_to_mint(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        sui_amount,
    );
    assert!(tokens_to_mint >= min_tokens_out, E_SLIPPAGE_EXCEEDED_BUY);

    // Calculate fees (platform + battle royale)
    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let mut fee = calculate_transaction_fee(sui_amount, platform_fee);
    let total_cost = sui_amount + fee;
    assert!(coin::value(payment) >= total_cost, E_INSUFFICIENT_PAYMENT);

    // Process payment and split fees
    let paid = coin::split(payment, total_cost, ctx);
    let mut paid_balance = coin::into_balance(paid);

    // Calculate and handle battle royale fee
    let br_fee_bps = battle_royale::get_br_fee_bps(br);
    let br_fee = utils::as_u64(utils::percentage_of(utils::from_u64(fee), br_fee_bps));

    if (
        battle_royale::is_coin_valid_for_battle_royale(br, coin_address, current_epoch) && br_fee > 0
    ) {
        let br_fee_payment = balance::split(&mut paid_balance, br_fee);
        fee = fee - br_fee;
        battle_royale::contribute_trade_fee(launchpad, br, coin_address, br_fee_payment, ctx);
    };

    // Process remaining fees and update reserves
    let fee_payment = balance::split(&mut paid_balance, fee);
    token_launcher::add_to_treasury(launchpad, fee_payment);
    balance::join(&mut coin_info.real_sui_reserves, paid_balance);

    // Update virtual reserves and mint tokens
    coin_info.virtual_sui_reserves = coin_info.virtual_sui_reserves + sui_amount;
    coin_info.virtual_token_reserves = coin_info.virtual_token_reserves - tokens_to_mint;

    let tokens = coin::take(&mut coin_info.real_token_reserves, tokens_to_mint, ctx);
    transfer::public_transfer(tokens, tx_context::sender(ctx));
    coin_info.supply = coin_info.supply + tokens_to_mint;

    // Emit trade event
    let new_price = get_current_price(coin_info);
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

/// Sell tokens with battle royale fee sharing
public entry fun sell_tokens_with_br<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    tokens: Coin<T>,
    min_sui_out: u64,
    br: &mut BattleRoyale,
    ctx: &mut TxContext,
) {
    let current_epoch = tx_context::epoch(ctx);
    let coin_address = object::uid_to_address(&coin_info.id);
    let token_amount = coin::value(&tokens);

    // Validate battle royale is active
    assert!(
        battle_royale::is_battle_royale_open(br, current_epoch),
        E_BATTLE_ROYALE_NOT_ACTIVE_FOR_TRADE,
    );

    // Calculate return and validate slippage
    let return_cost = bonding_curve::calculate_sale_return(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        token_amount,
    );
    assert!(balance::value(&coin_info.real_sui_reserves) >= return_cost, E_INSUFFICIENT_BALANCE);

    let platform_fee = token_launcher::get_platform_fee(launchpad);
    let fee = calculate_transaction_fee(return_cost, platform_fee);
    let final_return_cost = return_cost - fee;
    assert!(final_return_cost >= min_sui_out, E_SLIPPAGE_EXCEEDED_SELL);

    // Update virtual reserves
    coin_info.virtual_sui_reserves = coin_info.virtual_sui_reserves - return_cost;
    coin_info.virtual_token_reserves = coin_info.virtual_token_reserves + token_amount;

    // Handle fees with battle royale split
    let mut fee_payment = balance::split(&mut coin_info.real_sui_reserves, fee);
    let return_payment = balance::split(&mut coin_info.real_sui_reserves, final_return_cost);

    let br_fee_bps = battle_royale::get_br_fee_bps(br);
    let br_fee = utils::as_u64(utils::percentage_of(utils::from_u64(fee), br_fee_bps));

    if (
        battle_royale::is_coin_valid_for_battle_royale(br, coin_address, current_epoch) && br_fee > 0
    ) {
        let br_fee_payment = balance::split(&mut fee_payment, br_fee);
        battle_royale::contribute_trade_fee(launchpad, br, coin_address, br_fee_payment, ctx);
    };

    // Process sale completion
    token_launcher::add_to_treasury(launchpad, fee_payment);
    let return_coin = coin::from_balance(return_payment, ctx);

    coin_info.supply = coin_info.supply - token_amount;
    coin::burn(&mut coin_info.protected_cap.cap, tokens);
    transfer::public_transfer(return_coin, tx_context::sender(ctx));

    // Emit trade event
    let new_price = get_current_price(coin_info);
    event::emit(TradeEvent {
        is_buy: false,
        coin_address,
        user_address: tx_context::sender(ctx),
        token_amount,
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
