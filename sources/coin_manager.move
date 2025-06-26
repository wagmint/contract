module wagmint::coin_manager;

use cetus_clmm::config::GlobalConfig;
use cetus_clmm::factory::Pools;
use std::string::{String, as_bytes};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
use sui::event;
use sui::sui::SUI;
use sui::url::{Self, Url};
use wagmint::battle_royale::{Self, BattleRoyale};
use wagmint::bonding_curve;
use wagmint::graduation;
use wagmint::token_launcher::{Self, LaunchedCoinsRegistry};
use wagmint::utils;

// === Error Codes ===
const E_INVALID_NAME_LENGTH: u64 = 0;
const E_INSUFFICIENT_PAYMENT: u64 = 1;
const E_INSUFFICIENT_BALANCE: u64 = 2;
const E_AMOUNT_TOO_SMALL: u64 = 3;
const E_ALREADY_GRADUATED: u64 = 4;
const E_BATTLE_ROYALE_NOT_ACTIVE_FOR_TRADE: u64 = 5;
const E_SLIPPAGE_EXCEEDED_BUY: u64 = 6;
const E_SLIPPAGE_EXCEEDED_SELL: u64 = 7;
const E_NOT_ELIGIBLE_FOR_GRADUATION: u64 = 8;
const E_TOKEN_NOT_GRADUATED: u64 = 9;
const E_POOL_NOT_FOUND: u64 = 10;
const E_TRADING_LOCKED: u64 = 11;

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
    coin_metadata_id: address,
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
    cetus_pool_id: Option<address>, // Cetus pool ID after graduation
    graduation_locked: bool,
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
    coin_metadata_id: address,
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
    market_cap: Option<u64>,
    cetus_pool_sui_liquidity: Option<u64>,
    cetus_pool_token_liquidity: Option<u64>,
    is_graduated_trade: bool,
    is_eligible_for_graduation: Option<bool>,
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
    coin_metadata_id: address,
    clock: &Clock,
    br_address: Option<address>,
    ctx: &mut TxContext,
): address {
    let current_time = clock.timestamp_ms();

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
        launch_time: current_time,
        coin_type,
        coin_metadata_id,
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
        cetus_pool_id: option::none(),
        graduation_locked: false,
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
        launch_time: current_time,
        virtual_sui_reserves: coin_info.virtual_sui_reserves,
        virtual_token_reserves: coin_info.virtual_token_reserves,
        real_sui_reserves: balance::value(&coin_info.real_sui_reserves),
        real_token_reserves: balance::value(&coin_info.real_token_reserves),
        bonding_curve_tokens: coin_info.bonding_curve_tokens,
        amm_reserve_tokens: coin_info.amm_reserve_tokens,
        total_token_supply: coin_info.total_token_supply,
        token_decimals,
        coin_type: coin_info.coin_type,
        coin_metadata_id: coin_info.coin_metadata_id,
        br_address,
    });

    // Update registry
    token_launcher::increment_coins_count(launchpad);
    token_launcher::add_to_registry(registry, coin_address);
    transfer::share_object(coin_info);

    coin_address
}

/// Internal swap function using Cetus flash swap (without partner)
fun internal_swap<CoinTypeA, CoinTypeB>(
    config: &cetus_clmm::config::GlobalConfig,
    pool: &mut cetus_clmm::pool::Pool<CoinTypeA, CoinTypeB>,
    coin_a: &mut Coin<CoinTypeA>,
    coin_b: &mut Coin<CoinTypeB>,
    a2b: bool,
    by_amount_in: bool,
    amount: u64,
    sqrt_price_limit: u128,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64) {
    // Returns (in_amount, out_amount)
    // Flash swap first
    let (receive_a, receive_b, flash_receipt) = cetus_clmm::pool::flash_swap<CoinTypeA, CoinTypeB>(
        config,
        pool,
        a2b,
        by_amount_in,
        amount,
        sqrt_price_limit,
        clock,
    );

    let (in_amount, out_amount) = (
        cetus_clmm::pool::swap_pay_amount(&flash_receipt),
        if (a2b) balance::value(&receive_b) else balance::value(&receive_a),
    );

    // Pay for flash swap
    let (pay_coin_a, pay_coin_b) = if (a2b) {
        (coin::into_balance(coin::split(coin_a, in_amount, ctx)), balance::zero<CoinTypeB>())
    } else {
        (balance::zero<CoinTypeA>(), coin::into_balance(coin::split(coin_b, in_amount, ctx)))
    };

    // Add received coins to user's coins
    coin::join(coin_b, coin::from_balance(receive_b, ctx));
    coin::join(coin_a, coin::from_balance(receive_a, ctx));

    // Repay flash swap
    cetus_clmm::pool::repay_flash_swap<CoinTypeA, CoinTypeB>(
        config,
        pool,
        pay_coin_a,
        pay_coin_b,
        flash_receipt,
    );

    (in_amount, out_amount)
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
    coin_metadata_id: address,
    clock: &Clock,
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
        coin_metadata_id,
        clock,
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

    // CRITICAL: Check if trading is locked or graduated
    assert!(!coin_info.graduation_locked, E_TRADING_LOCKED);
    assert!(!coin_info.graduated, E_ALREADY_GRADUATED);

    // Check slippage protection
    let expected_tokens = bonding_curve::calculate_tokens_to_mint(
        coin_info.virtual_sui_reserves,
        coin_info.virtual_token_reserves,
        sui_amount,
    );
    assert!(expected_tokens >= min_tokens_out, E_SLIPPAGE_EXCEEDED_BUY);

    // Check if THIS transaction would trigger graduation eligibility
    let will_trigger_graduation = would_trigger_graduation(launchpad, coin_info, sui_amount);

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

    // Update supply
    coin_info.supply = coin_info.supply + tokens_to_mint;

    // If this trade triggered graduation eligibility, LOCK trading
    if (will_trigger_graduation) {
        coin_info.graduation_locked = true;
    };

    // Check graduation eligibility after the trade
    let is_eligible_for_graduation = check_graduation_eligibility(launchpad, coin_info);
    let new_price = get_current_price(coin_info);

    // Emit event with graduation eligibility info
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
        market_cap: option::none(),
        cetus_pool_sui_liquidity: option::none(),
        cetus_pool_token_liquidity: option::none(),
        is_graduated_trade: false,
        is_eligible_for_graduation: option::some(is_eligible_for_graduation),
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
    assert!(!coin_info.graduation_locked, E_TRADING_LOCKED);
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
        market_cap: option::none(),
        cetus_pool_sui_liquidity: option::none(),
        cetus_pool_token_liquidity: option::none(),
        is_graduated_trade: false,
        is_eligible_for_graduation: option::none(),
    });
}

// === Graduation Functions ===

public entry fun graduate_token<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    cetus_config: &GlobalConfig,
    cetus_pools: &mut Pools,
    coin_a_metadata: &CoinMetadata<SUI>,
    coin_b_metadata: &CoinMetadata<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate graduation eligibility - must be locked for graduation
    assert!(!coin_info.graduated, E_ALREADY_GRADUATED);
    assert!(coin_info.graduation_locked, E_TRADING_LOCKED);
    assert!(check_graduation_eligibility(launchpad, coin_info), E_NOT_ELIGIBLE_FOR_GRADUATION);

    // Store values before state changes
    let final_bc_price = get_current_price(coin_info);
    let coin_address = object::uid_to_address(&coin_info.id);

    // Extract all SUI from bonding curve
    let real_sui_amount = balance::value(&coin_info.real_sui_reserves);
    let accumulated_sui_balance = balance::withdraw_all(&mut coin_info.real_sui_reserves);

    // Delegate to graduation module
    let (_, _, pool_id) = graduation::execute_graduation(
        launchpad,
        &mut coin_info.protected_cap.cap,
        accumulated_sui_balance,
        coin_info.amm_reserve_tokens,
        coin_address,
        coin_info.coin_type,
        final_bc_price,
        coin_info.supply,
        coin_info.graduated,
        real_sui_amount,
        cetus_config,
        cetus_pools,
        coin_a_metadata,
        coin_b_metadata,
        clock,
        ctx,
    );

    // Mark as graduated (disables bonding curve)
    coin_info.graduated = true;
    coin_info.cetus_pool_id = option::some(pool_id);
}

/// Check if token meets graduation requirements
public fun check_graduation_eligibility<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &CoinInfo<T>,
): bool {
    graduation::check_graduation_eligibility(
        launchpad,
        balance::value(&coin_info.real_sui_reserves),
        coin_info.graduated,
    )
}

/// Check if this trade would trigger graduation
fun would_trigger_graduation<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &CoinInfo<T>,
    sui_amount: u64,
): bool {
    if (coin_info.graduated) return false;

    let current_reserves = balance::value(&coin_info.real_sui_reserves);
    let graduation_threshold = token_launcher::get_graduation_threshold(launchpad);

    (current_reserves + sui_amount) >= graduation_threshold
}

// === Routing Functions ===

/// Swap SUI for graduated tokens via Cetus
public entry fun swap_graduated_sui_to_token<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &CoinInfo<T>,
    payment: &mut Coin<SUI>,
    sui_amount: u64,
    min_tokens_out: u64,
    cetus_config: &cetus_clmm::config::GlobalConfig,
    cetus_pool: &mut cetus_clmm::pool::Pool<T, SUI>, // Note: T, SUI order
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate token is graduated and has pool
    assert!(coin_info.graduated, E_TOKEN_NOT_GRADUATED);
    assert!(option::is_some(&coin_info.cetus_pool_id), E_POOL_NOT_FOUND);

    // Validate minimum trade amount
    assert!(sui_amount >= MIN_TRADE_AMOUNT, E_AMOUNT_TOO_SMALL);

    // Calculate and deduct platform fee (0.25%)
    let graduated_swap_fee_bps = token_launcher::get_graduated_swap_fee_bps(launchpad);
    let fee_amount = calculate_transaction_fee(sui_amount, graduated_swap_fee_bps);
    let swap_amount = sui_amount - fee_amount;

    // Pre-calculate swap result for slippage protection
    // SUI → Token is b2a direction since pool is <T, SUI>
    let calc_result = cetus_clmm::pool::calculate_swap_result<T, SUI>(
        cetus_pool,
        false, // a2b = false (b2a: SUI -> Token)
        true, // by_amount_in = true (exact input)
        swap_amount, // amount (SUI amount after fee)
    );

    // Check for calculation errors
    assert!(
        !cetus_clmm::pool::calculated_swap_result_is_exceed(&calc_result),
        E_SLIPPAGE_EXCEEDED_BUY,
    );

    // Validate slippage protection BEFORE executing swap
    let expected_tokens_out = cetus_clmm::pool::calculated_swap_result_amount_out(&calc_result);
    assert!(expected_tokens_out >= min_tokens_out, E_SLIPPAGE_EXCEEDED_BUY);

    // Split exact amount from user's coin
    let mut payment_coin = coin::split(payment, sui_amount, ctx);

    // Process platform fee
    let fee_coin = coin::split(&mut payment_coin, fee_amount, ctx);
    let fee_balance = coin::into_balance(fee_coin);
    token_launcher::add_to_treasury(launchpad, fee_balance);

    // Prepare coins for swap
    let mut tokens_coin = coin::zero<T>(ctx);

    // Execute swap with confidence (we already validated slippage)
    let (in_amount, out_amount) = internal_swap<T, SUI>(
        cetus_config,
        cetus_pool,
        &mut tokens_coin, // coin_a (tokens - will receive output)
        &mut payment_coin, // coin_b (SUI - providing input)
        false, // a2b = false (SUI -> Token, so b2a)
        true, // by_amount_in = true (exact input)
        swap_amount, // amount (exact SUI amount to spend)
        cetus_clmm::tick_math::max_sqrt_price(), // sqrt_price_limit (no limit - we pre-validated)
        clock,
        ctx,
    );

    // Sanity checks (should match pre-calculation)
    assert!(in_amount == swap_amount, E_INSUFFICIENT_PAYMENT);
    assert!(out_amount >= min_tokens_out, E_SLIPPAGE_EXCEEDED_BUY);

    // Return any remaining SUI to user (should be zero for exact input)
    if (coin::value(&payment_coin) > 0) {
        coin::join(payment, payment_coin);
    } else {
        coin::destroy_zero(payment_coin);
    };

    // Transfer tokens to user
    transfer::public_transfer(tokens_coin, tx_context::sender(ctx));

    // Calculate graduated token metrics
    let current_price = get_graduated_token_price_via_simulation(coin_info, cetus_pool);
    let market_cap = calculate_graduated_market_cap(coin_info, current_price);
    let (token_liquidity, sui_liquidity) = get_graduated_token_liquidity(cetus_pool);

    // Emit trade event
    let coin_address = object::uid_to_address(&coin_info.id);
    event::emit(TradeEvent {
        is_buy: true,
        coin_address,
        user_address: tx_context::sender(ctx),
        token_amount: out_amount,
        sui_amount: in_amount,
        platform_fee_amount: fee_amount,
        battle_royale_fee_amount: 0,
        new_supply: coin_info.supply, // Supply doesn't change for graduated tokens
        new_price: current_price, // Price determined by Cetus, not bonding curve
        new_virtual_sui_reserves: 0, // No longer relevant
        new_virtual_token_reserves: 0, // No longer relevant
        new_real_sui_reserves: 0, // No longer relevant
        new_real_token_reserves: 0, // No longer relevant
        market_cap: option::some(market_cap),
        cetus_pool_sui_liquidity: option::some(sui_liquidity),
        cetus_pool_token_liquidity: option::some(token_liquidity),
        is_graduated_trade: true,
        is_eligible_for_graduation: option::none(),
    });
}

/// Swap graduated tokens for SUI via Cetus
public entry fun swap_graduated_token_to_sui<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &CoinInfo<T>,
    tokens: &mut Coin<T>,
    token_amount: u64,
    min_sui_out: u64,
    cetus_config: &cetus_clmm::config::GlobalConfig,
    cetus_pool: &mut cetus_clmm::pool::Pool<T, SUI>, // Note: T, SUI order
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Validate token is graduated and has pool
    assert!(coin_info.graduated, E_TOKEN_NOT_GRADUATED);
    assert!(option::is_some(&coin_info.cetus_pool_id), E_POOL_NOT_FOUND);
    assert!(token_amount >= MIN_TRADE_AMOUNT, E_AMOUNT_TOO_SMALL);

    let mut tokens_to_trade = coin::split(tokens, token_amount, ctx);

    // Pre-calculate swap result for slippage protection
    // Token → SUI is a2b direction since pool is <T, SUI>
    let calc_result = cetus_clmm::pool::calculate_swap_result<T, SUI>(
        cetus_pool,
        true, // a2b = true (Token -> SUI)
        true, // by_amount_in = true (exact input)
        token_amount, // amount (exact token amount)
    );

    // Check for calculation errors
    assert!(
        !cetus_clmm::pool::calculated_swap_result_is_exceed(&calc_result),
        E_SLIPPAGE_EXCEEDED_SELL,
    );

    // Calculate expected SUI after our platform fee
    let expected_sui_out = cetus_clmm::pool::calculated_swap_result_amount_out(&calc_result);
    let graduated_swap_fee_bps = token_launcher::get_graduated_swap_fee_bps(launchpad);
    let fee_amount = calculate_transaction_fee(expected_sui_out, graduated_swap_fee_bps);
    let expected_sui_after_fee = expected_sui_out - fee_amount;

    // Validate slippage protection BEFORE executing swap
    assert!(expected_sui_after_fee >= min_sui_out, E_SLIPPAGE_EXCEEDED_SELL);

    // Prepare coins for swap
    let mut sui_coin = coin::zero<SUI>(ctx);

    // Execute swap with confidence (we already validated slippage)
    let (in_amount, out_amount) = internal_swap<T, SUI>(
        cetus_config,
        cetus_pool,
        &mut tokens_to_trade, // coin_a (tokens - providing input)
        &mut sui_coin, // coin_b (SUI - will receive output)
        true, // a2b = true (Token -> SUI)
        true, // by_amount_in = true (exact input)
        token_amount, // amount (exact token amount to spend)
        cetus_clmm::tick_math::min_sqrt_price(), // sqrt_price_limit (no limit - we pre-validated)
        clock,
        ctx,
    );

    // Sanity checks (should match pre-calculation)
    assert!(in_amount == token_amount, E_INSUFFICIENT_BALANCE);
    assert!(out_amount == expected_sui_out, E_SLIPPAGE_EXCEEDED_SELL);

    // Tokens should be consumed (zero remaining)
    coin::destroy_zero(tokens_to_trade);

    // Calculate and process platform fee (0.25% of received SUI)
    let actual_fee_amount = calculate_transaction_fee(out_amount, graduated_swap_fee_bps);
    let fee_coin = coin::split(&mut sui_coin, actual_fee_amount, ctx);

    // Add fee to treasury
    let fee_balance = coin::into_balance(fee_coin);
    token_launcher::add_to_treasury(launchpad, fee_balance);

    // Remaining SUI after fee
    let final_sui_amount = out_amount - actual_fee_amount;

    // Final slippage check (should pass since we pre-calculated)
    assert!(final_sui_amount >= min_sui_out, E_SLIPPAGE_EXCEEDED_SELL);

    // Transfer SUI to user
    transfer::public_transfer(sui_coin, tx_context::sender(ctx));

    // Calculate graduated token metrics
    let current_price = get_graduated_token_price_via_simulation(coin_info, cetus_pool);
    let market_cap = calculate_graduated_market_cap(coin_info, current_price);
    let (token_liquidity, sui_liquidity) = get_graduated_token_liquidity(cetus_pool);

    // Emit trade event
    let coin_address = object::uid_to_address(&coin_info.id);
    event::emit(TradeEvent {
        is_buy: false,
        coin_address,
        user_address: tx_context::sender(ctx),
        token_amount: in_amount,
        sui_amount: final_sui_amount,
        platform_fee_amount: actual_fee_amount,
        battle_royale_fee_amount: 0,
        new_supply: coin_info.supply, // Supply doesn't change for graduated tokens
        new_price: current_price, // Price determined by Cetus, not bonding curve
        new_virtual_sui_reserves: 0, // No longer relevant
        new_virtual_token_reserves: 0, // No longer relevant
        new_real_sui_reserves: 0, // No longer relevant
        new_real_token_reserves: 0, // No longer relevant
        market_cap: option::some(market_cap),
        cetus_pool_sui_liquidity: option::some(sui_liquidity),
        cetus_pool_token_liquidity: option::some(token_liquidity),
        is_graduated_trade: true,
        is_eligible_for_graduation: option::none(),
    });
}

// === Helper Functions ===
/// Get the Cetus pool ID for a graduated token
public fun get_cetus_pool_id<T>(coin_info: &CoinInfo<T>): Option<address> {
    coin_info.cetus_pool_id
}

/// Check if a token can be traded via Cetus
public fun can_trade_via_cetus<T>(coin_info: &CoinInfo<T>): bool {
    coin_info.graduated && option::is_some(&coin_info.cetus_pool_id)
}

/// Get current price for graduated token using simulation
fun get_graduated_token_price_via_simulation<T>(
    coin_info: &CoinInfo<T>,
    cetus_pool: &cetus_clmm::pool::Pool<T, SUI>,
): u64 {
    // Use 1 token in its smallest unit based on actual decimals
    let token_decimals = coin_info.token_decimals;
    let one_token = utils::as_u64(utils::pow(utils::from_u64(10), (token_decimals as u64)));

    let calc_result = cetus_clmm::pool::calculate_swap_result<T, SUI>(
        cetus_pool,
        true, // a2b = true (Token -> SUI)
        true, // by_amount_in = true
        one_token, // 1 token in smallest unit (actual decimals)
    );

    if (cetus_clmm::pool::calculated_swap_result_is_exceed(&calc_result)) {
        return 0
    };

    let sui_out = cetus_clmm::pool::calculated_swap_result_amount_out(&calc_result);
    sui_out
}

/// Get Cetus pool liquidity for graduated token
fun get_graduated_token_liquidity<T>(cetus_pool: &cetus_clmm::pool::Pool<T, SUI>): (u64, u64) {
    let (balance_a, balance_b) = cetus_clmm::pool::balances(cetus_pool);
    (balance::value(balance_a), balance::value(balance_b))
}

/// Calculate market cap for graduated token
fun calculate_graduated_market_cap<T>(coin_info: &CoinInfo<T>, price: u64): u64 {
    let total_supply = coin_info.supply;
    utils::as_u64(
        utils::mul(utils::from_u64(price), utils::from_u64(total_supply)),
    )
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
    graduation::get_graduation_progress(
        launchpad,
        balance::value(&coin_info.real_sui_reserves),
    )
}

public fun get_estimated_amm_liquidity<T>(coin_info: &CoinInfo<T>): (u64, u64) {
    graduation::get_estimated_amm_liquidity(
        balance::value(&coin_info.real_sui_reserves),
        coin_info.amm_reserve_tokens,
    )
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

public fun is_graduation_locked<T>(info: &CoinInfo<T>): bool { info.graduation_locked }

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
    coin_metadata_id: address,
    clock: &Clock,
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
        coin_metadata_id,
        clock,
        option::some(br_address),
        ctx,
    );

    battle_royale::register_coin(battle_royale, coin_address, clock, ctx);
    coin_address
}

/// Buy tokens with battle royale fee sharing
public entry fun buy_tokens_with_br<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    mut payment: Coin<SUI>, // ← Changed from &mut Coin<SUI> to Coin<SUI>
    sui_amount: u64,
    min_tokens_out: u64,
    clock: &Clock,
    br: &mut BattleRoyale,
    ctx: &mut TxContext,
) {
    assert!(!coin_info.graduation_locked, E_TRADING_LOCKED);
    let current_epoch = clock.timestamp_ms();
    let coin_address = object::uid_to_address(&coin_info.id);

    // Check if this trade triggers graduation and lock if so
    let will_trigger_graduation = would_trigger_graduation(launchpad, coin_info, sui_amount);
    if (will_trigger_graduation) {
        coin_info.graduation_locked = true;
    };

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
    let payment_amount = coin::value(&payment);
    let total_cost = sui_amount + fee;
    assert!(payment_amount >= total_cost, E_INSUFFICIENT_PAYMENT);

    // Handle remainder BEFORE processing (like buy_tokens does)
    if (payment_amount > total_cost) {
        let remainder = coin::split(&mut payment, payment_amount - total_cost, ctx);
        transfer::public_transfer(remainder, tx_context::sender(ctx));
    };

    // Convert entire remaining payment to balance and split fees
    let mut paid_balance = coin::into_balance(payment);

    // Calculate and handle battle royale fee
    let br_fee_bps = battle_royale::get_br_fee_bps(br);
    let br_fee = utils::as_u64(utils::percentage_of(utils::from_u64(fee), br_fee_bps));

    if (
        battle_royale::is_coin_valid_for_battle_royale(br, coin_address, current_epoch) && br_fee > 0
    ) {
        let br_fee_payment = balance::split(&mut paid_balance, br_fee);
        fee = fee - br_fee;
        battle_royale::contribute_trade_fee(launchpad, br, coin_address, br_fee_payment, clock);
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
    let is_eligible_for_graduation = check_graduation_eligibility(launchpad, coin_info);
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
        market_cap: option::none(),
        cetus_pool_sui_liquidity: option::none(),
        cetus_pool_token_liquidity: option::none(),
        is_graduated_trade: false,
        is_eligible_for_graduation: option::some(is_eligible_for_graduation),
    });
}

/// Sell tokens with battle royale fee sharing
public entry fun sell_tokens_with_br<T>(
    launchpad: &mut token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    tokens: Coin<T>,
    min_sui_out: u64,
    clock: &Clock,
    br: &mut BattleRoyale,
    ctx: &mut TxContext,
) {
    assert!(!coin_info.graduation_locked, E_TRADING_LOCKED);
    let current_epoch = clock.timestamp_ms();
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
        battle_royale::contribute_trade_fee(launchpad, br, coin_address, br_fee_payment, clock);
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
        market_cap: option::none(),
        cetus_pool_sui_liquidity: option::none(),
        cetus_pool_token_liquidity: option::none(),
        is_graduated_trade: false,
        is_eligible_for_graduation: option::none(),
    });
}
