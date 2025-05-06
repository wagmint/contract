module wagmint::coin_manager;

use std::string::{String, as_bytes};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::sui::SUI;
use sui::url::{Self, Url};
use wagmint::bonding_curve;
use wagmint::token_launcher::{Self, LaunchedCoinsRegistry};

// Error codes
const E_INVALID_NAME_LENGTH: u64 = 0;
const E_INVALID_SYMBOL_LENGTH: u64 = 1;
const E_INSUFFICIENT_PAYMENT: u64 = 2;
const E_INSUFFICIENT_BALANCE: u64 = 3;
const E_AMOUNT_TOO_SMALL: u64 = 4;
const E_ALREADY_GRADUATED: u64 = 6;

// Constants for validation
const MAX_NAME_LENGTH: u64 = 32;
const MAX_SYMBOL_LENGTH: u64 = 10;
const MIN_TRADE_AMOUNT: u64 = 1;

// Constants
const BPS_DENOMINATOR: u64 = 10000;

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
    // Real reserves - actual tokens and SUI
    real_token_reserves: Balance<T>, // Tokens held by the bonding curve
    real_sui_reserves: Balance<SUI>, // Actual SUI reserves
    // Virtual reserves - for price calculation
    virtual_token_reserves: u64, // Virtual tokens for curve calculation
    virtual_sui_reserves: u64, // Virtual SUI for curve calculation
    // Token metadata
    token_decimals: u8, // Decimal places for the token
    graduated: bool, // Has token graduated to DEX?
    supply: u64, // Total supply in circulation
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
    token_decimals: u8,
}

public struct TradeEvent has copy, drop {
    is_buy: bool,
    coin_address: address,
    user_address: address,
    token_amount: u64,
    sui_amount: u64,
    new_supply: u64,
    new_price: u64,
    new_virtual_sui_reserves: u64,
    new_virtual_token_reserves: u64,
}

// Calculate transaction fee
public fun calculate_transaction_fee(amount: u64, transaction_fee_bps: u64): u64 {
    (amount * transaction_fee_bps) / BPS_DENOMINATOR
}

// === Buy functionality ===
public fun buy_tokens_helper<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    payment: &mut Coin<SUI>,
    amount: u64,
    ctx: &mut TxContext,
): u64 {
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
    assert!(coin::value(payment) >= total_cost, E_INSUFFICIENT_PAYMENT);

    // Process payment
    let paid = coin::split(payment, total_cost, ctx);
    let mut paid_balance = coin::into_balance(paid);

    // Split and transfer fee
    let fee_payment = balance::split(&mut paid_balance, fee);
    transfer::public_transfer(
        coin::from_balance(fee_payment, ctx),
        token_launcher::get_admin(launchpad),
    );

    // Add remaining to real reserve
    balance::join(&mut coin_info.real_sui_reserves, paid_balance);

    // Update virtual reserves
    coin_info.virtual_sui_reserves = coin_info.virtual_sui_reserves + amount;
    coin_info.virtual_token_reserves = coin_info.virtual_token_reserves - tokens_to_mint;

    // Check for graduation
    // if (
    //     bonding_curve::has_reached_graduation_threshold(
    //         coin_info.virtual_sui_reserves,
    //         bonding_curve::get_graduation_threshold(launchpad),
    //     )
    // ) {
    //     graduate_token(coin_info, ctx);
    // };
    tokens_to_mint
}

// === Sell functionality ===
public fun sell_tokens_helper<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    amount: u64,
    ctx: &mut TxContext,
): (u64, Coin<SUI>) {
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

    // Transfer fee to admin
    transfer::public_transfer(
        coin::from_balance(fee_payment, ctx),
        token_launcher::get_admin(launchpad),
    );

    let return_coin = coin::from_balance(return_payment, ctx);
    (return_cost, return_coin)
}

// Graduate token to DEX
// fun graduate_token<T>(coin_info: &mut CoinInfo<T>, ctx: &mut TxContext) {
//     // Only graduate once
//     if (!coin_info.graduated) {
//         coin_info.graduated = true;

//         // Emit graduation event
//         event::emit(TokenGraduatedEvent {
//             coin_address: object::uid_to_address(&coin_info.id),
//             supply: coin_info.supply,
//             sui_reserves: balance::value(&coin_info.real_sui_reserves),
//             virtual_sui_reserves: coin_info.virtual_sui_reserves,
//             virtual_token_reserves: coin_info.virtual_token_reserves,
//         });
//     }
// }

// First we need function to create a new coin type
public entry fun create_coin<T>(
    launchpad: &mut token_launcher::Launchpad,
    treasury_cap: TreasuryCap<T>,
    registry: &mut LaunchedCoinsRegistry,
    mut payment: Coin<SUI>,
    name: String,
    symbol: String,
    description: String,
    website: String,
    image_url: String,
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
    transfer::public_transfer(payment, token_launcher::get_admin(launchpad));

    // Wrap the treasury cap in the protected structure
    let mut protected_cap = ProtectedTreasuryCap<T> {
        cap: treasury_cap,
    };

    // Get initial virtual reserves from launchpad config
    let initial_virtual_sui = token_launcher::get_initial_virtual_sui(launchpad);
    let initial_virtual_tokens = token_launcher::get_initial_virtual_tokens(launchpad);
    let token_decimals = token_launcher::get_token_decimals(launchpad);

    // Mint actual tokens for initial distribution (all tokens are held by the bonding curve)
    let minted_tokens = coin::mint(
        &mut protected_cap.cap,
        initial_virtual_tokens,
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
        // Initial token allocation
        real_token_reserves: minted_balance,
        real_sui_reserves: balance::zero(),
        virtual_token_reserves: initial_virtual_tokens,
        virtual_sui_reserves: initial_virtual_sui,
        token_decimals,
        graduated: false,
        supply: 0, // No tokens in circulation yet
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
        token_decimals,
    });

    token_launcher::increment_coins_count(launchpad);
    token_launcher::add_to_registry(registry, coin_address);

    // Share the coin info object
    transfer::share_object(coin_info);

    // Return the address so caller knows where to find it
    coin_address
}

public entry fun buy_tokens<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    payment: &mut Coin<SUI>,
    sui_amount: u64,
    ctx: &mut TxContext,
) {
    // Validate amount
    assert!(sui_amount >= MIN_TRADE_AMOUNT, E_AMOUNT_TOO_SMALL);

    // Use the bonding curve to calculate tokens and process payment
    let tokens_to_mint = buy_tokens_helper(
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
        new_supply: coin_info.supply,
        new_price,
        new_virtual_sui_reserves: coin_info.virtual_sui_reserves,
        new_virtual_token_reserves: coin_info.virtual_token_reserves,
    });
}

public entry fun sell_tokens<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    tokens: Coin<T>,
    ctx: &mut TxContext,
) {
    let token_amount = coin::value(&tokens);

    // Process the sell operation using bonding curve
    let (sui_amount, return_coin) = sell_tokens_helper(
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
        new_supply: coin_info.supply,
        new_price,
        new_virtual_sui_reserves: coin_info.virtual_sui_reserves,
        new_virtual_token_reserves: coin_info.virtual_token_reserves,
    });
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
    let total_tokens = coin_info.virtual_token_reserves;
    let fully_diluted_market_cap = price * total_tokens;

    // Return the fully diluted market cap (like pump.fun)
    fully_diluted_market_cap
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

// Extracted validation logic for testing
public fun validate_inputs(name: String, symbol: String): bool {
    std::string::length(&name) > 0 && 
    std::string::length(&name) <= MAX_NAME_LENGTH &&
    std::string::length(&symbol) > 0 && 
    std::string::length(&symbol) <= MAX_SYMBOL_LENGTH
}
