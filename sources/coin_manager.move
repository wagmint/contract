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

    // Calculate token allocation based on 80/20 split
    let bonding_curve_tokens = token_launcher::calculate_bonding_curve_tokens(launchpad);
    let amm_reserve_tokens = token_launcher::calculate_amm_reserve_tokens(launchpad);

    // Mint only the bonding curve tokens initially (80%)
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
