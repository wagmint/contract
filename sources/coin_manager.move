module wagmint::coin_manager;

use std::string::{String, as_bytes};
use std::u64;
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

// Constants for validation
const MAX_NAME_LENGTH: u64 = 32;
const MAX_SYMBOL_LENGTH: u64 = 10;
const MIN_TRADE_AMOUNT: u64 = 1;

// Constants
const MIN_CREATION_FEE: u64 = 1_000_000_000; // 1 SUI = 1_000_000_000
const TRANSACTION_FEE_BPS: u64 = 100; // 1% = 100 basis points
const BPS_DENOMINATOR: u64 = 10000;

// This represents our custom coin properties
public struct CoinInfo<phantom T> has key, store {
    id: UID,
    name: String,
    symbol: String,
    image_url: Url,
    creator: address,
    launch_time: u64,
    treasury_cap: TreasuryCap<T>,
    supply: u64, // Track supply for bonding curve
    reserve_balance: Balance<SUI>, // Track reserve balance
}

// Events
public struct CoinCreated has copy, drop {
    name: String,
    symbol: String,
    creator: address,
    coin_address: address,
    launch_time: u64,
}

public struct TokensPurchased has copy, drop {
    coin_address: address,
    buyer: address,
    amount: u64,
    cost: u64,
    new_supply: u64,
    new_price: u64,
}

public struct TokensSold has copy, drop {
    coin_address: address,
    seller: address,
    amount: u64,
    return_amount: u64,
    new_supply: u64,
    new_price: u64,
}

// First we need function to create a new coin type
#[allow(lint(share_owned))]
public fun create_coin<T: drop>(
    witness: T, // Witness from caller
    launchpad: &mut token_launcher::Launchpad,
    registry: &mut LaunchedCoinsRegistry,
    payment: &mut Coin<SUI>, // Added payment parameter
    name: String,
    symbol: String,
    description: String,
    image_url: vector<u8>,
    mut custom_fee: Option<u64>,
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

    // Determine fee - use custom fee if provided and >= MIN_CREATION_FEE
    let fee_amount = if (option::is_some(&custom_fee)) {
        let custom_amount = option::extract(&mut custom_fee);
        u64::max(custom_amount, MIN_CREATION_FEE)
    } else {
        MIN_CREATION_FEE
    };

    // Validate payment
    let payment_amount = coin::value(payment);
    assert!(payment_amount >= fee_amount, E_INSUFFICIENT_PAYMENT);

    // Take the determined fee
    let fee = coin::split(payment, fee_amount, ctx);
    transfer::public_transfer(fee, token_launcher::get_admin(launchpad));

    // Create the coin with treasury cap
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        9, // decimals
        *as_bytes(&symbol),
        *as_bytes(&name),
        *as_bytes(&description),
        option::some(url::new_unsafe_from_bytes(image_url)),
        ctx,
    );
    transfer::public_share_object(metadata);

    let coin_info = CoinInfo<T> {
        id: object::new(ctx),
        name,
        symbol,
        image_url: url::new_unsafe_from_bytes(image_url),
        creator: tx_context::sender(ctx),
        launch_time: tx_context::epoch(ctx),
        treasury_cap,
        supply: 0,
        reserve_balance: balance::zero(), // Initialize empty balance
    };

    let coin_address = object::uid_to_address(&coin_info.id);
    // Emit creation event
    event::emit(CoinCreated {
        name,
        symbol,
        creator: tx_context::sender(ctx),
        coin_address: coin_address,
        launch_time: tx_context::epoch(ctx),
    });

    token_launcher::increment_coins_count(launchpad);
    token_launcher::add_to_registry(registry, object::uid_to_address(&coin_info.id));

    // Share the coin info object instead of returning it
    transfer::share_object(coin_info);

    // Return the address so caller knows where to find it
    coin_address
}

// Calculate transaction fee
public fun calculate_transaction_fee(amount: u64): u64 {
    (amount * TRANSACTION_FEE_BPS) / BPS_DENOMINATOR
}

// === Buy functionality ===
public fun buy_tokens_helper(
    launchpad: &token_launcher::Launchpad,
    supply: u64,
    amount: u64,
    payment: &mut Coin<SUI>,
    reserve_balance: &mut Balance<SUI>,
    ctx: &mut TxContext,
): u64 {
    let base_cost = bonding_curve::calculate_purchase_cost(supply, amount);
    let fee = calculate_transaction_fee(base_cost);
    let total_cost = base_cost + fee;

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

    // Add remaining to reserve
    balance::join(reserve_balance, paid_balance);
    base_cost
}

public entry fun buy_tokens<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    payment: &mut Coin<SUI>,
    amount: u64,
    ctx: &mut TxContext,
) {
    // Validate amount
    assert!(amount >= MIN_TRADE_AMOUNT, E_AMOUNT_TOO_SMALL);
    let cost = buy_tokens_helper(
        launchpad,
        coin_info.supply,
        amount,
        payment,
        &mut coin_info.reserve_balance,
        ctx,
    );

    // Mint new tokens
    let treasury_cap = &mut coin_info.treasury_cap;
    coin::mint_and_transfer(treasury_cap, amount, tx_context::sender(ctx), ctx);

    // Update supply
    coin_info.supply = coin_info.supply + amount;

    event::emit(TokensPurchased {
        coin_address: object::uid_to_address(&coin_info.id),
        buyer: tx_context::sender(ctx),
        amount,
        cost,
        new_supply: coin_info.supply,
        new_price: bonding_curve::calculate_price(coin_info.supply),
    });
}

// === Sell functionality ===
public fun sell_tokens_helper(
    launchpad: &token_launcher::Launchpad,
    supply: u64,
    amount: u64,
    reserve_balance: &mut Balance<SUI>,
    ctx: &mut TxContext,
): (u64, u64, Coin<SUI>) {
    // Calculate return amount
    let return_amount = bonding_curve::calculate_sale_return(supply, amount);

    // Validate reserve has enough
    assert!(balance::value(reserve_balance) >= return_amount, E_INSUFFICIENT_BALANCE);

    // Calculate fee and final return amount
    let fee = calculate_transaction_fee(return_amount);
    let final_return_amount = return_amount - fee;

    // Update supply
    let new_supply = supply - amount;

    // Take fee and return amount from reserve
    let fee_payment = balance::split(reserve_balance, fee);
    let return_payment = balance::split(reserve_balance, final_return_amount);

    // Transfer fee to admin
    transfer::public_transfer(
        coin::from_balance(fee_payment, ctx),
        token_launcher::get_admin(launchpad),
    );

    let return_coin = coin::from_balance(return_payment, ctx);
    (new_supply, return_amount, return_coin)
}

public entry fun sell_tokens<T>(
    launchpad: &token_launcher::Launchpad,
    coin_info: &mut CoinInfo<T>,
    tokens: Coin<T>,
    ctx: &mut TxContext,
) {
    let amount = coin::value(&tokens);

    // Burn the tokens
    let treasury_cap = &mut coin_info.treasury_cap;
    coin::burn(treasury_cap, tokens);

    let (new_supply, return_amount, return_coin) = sell_tokens_helper(
        launchpad,
        coin_info.supply,
        amount,
        &mut coin_info.reserve_balance,
        ctx,
    );

    // Transfer return amount to seller
    transfer::public_transfer(return_coin, tx_context::sender(ctx));

    // Update supply
    coin_info.supply = new_supply;

    event::emit(TokensSold {
        coin_address: object::uid_to_address(&coin_info.id),
        seller: tx_context::sender(ctx),
        amount,
        return_amount,
        new_supply: coin_info.supply,
        new_price: bonding_curve::calculate_price(coin_info.supply),
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
        balance::value(&info.reserve_balance),
    )
}

// Get current spot price of the coin
public fun get_current_price<T>(coin_info: &CoinInfo<T>): u64 {
    bonding_curve::calculate_price(coin_info.supply)
}

// Get cost to buy specific amount
public fun get_purchase_cost<T>(coin_info: &CoinInfo<T>, amount: u64): u64 {
    bonding_curve::calculate_purchase_cost(coin_info.supply, amount)
}

// Get return amount for selling specific amount
public fun get_sale_return<T>(coin_info: &CoinInfo<T>, amount: u64): u64 {
    bonding_curve::calculate_sale_return(coin_info.supply, amount)
}

// Get just the supply
public fun get_supply<T>(info: &CoinInfo<T>): u64 {
    info.supply
}

// Get just the reserve balance
public fun get_reserve<T>(info: &CoinInfo<T>): u64 {
    balance::value(&info.reserve_balance)
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
