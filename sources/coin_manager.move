module wagmint::coin_manager;

use std::string::{Self, String, as_bytes};
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

public struct COIN has drop {}

// This represents our custom coin properties
public struct CoinInfo has key, store {
    id: UID,
    name: String,
    symbol: String,
    image_url: Url,
    creator: address,
    launch_time: u64,
    treasury_cap: TreasuryCap<COIN>, // We'll need to make this generic
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
public fun create_coin(
    launchpad: &mut token_launcher::Launchpad,
    registry: &mut LaunchedCoinsRegistry,
    payment: &mut Coin<SUI>, // Added payment parameter
    name: String,
    symbol: String,
    description: String,
    image_url: vector<u8>,
    ctx: &mut TxContext,
): CoinInfo {
    // Validate inputs
    assert!(
        std::string::length(&name) > 0 && std::string::length(&name) <= MAX_NAME_LENGTH,
        E_INVALID_NAME_LENGTH,
    );
    assert!(
        std::string::length(&symbol) > 0 && std::string::length(&symbol) <= MAX_SYMBOL_LENGTH,
        E_INVALID_SYMBOL_LENGTH,
    );

    // Validate payment
    let payment_amount = coin::value(payment);
    assert!(payment_amount >= MIN_CREATION_FEE, E_INSUFFICIENT_PAYMENT);

    // Take creation fee
    let payment_amount = coin::value(payment);
    assert!(payment_amount >= MIN_CREATION_FEE, E_INSUFFICIENT_PAYMENT);

    let fee = coin::split(payment, payment_amount, ctx);
    transfer::public_transfer(fee, token_launcher::get_admin(launchpad));

    // Create coin object
    let witness = COIN {};

    // Create the coin with treasury cap
    let (treasury_cap, metadata) = coin::create_currency(
        witness, // We'll need to handle this
        9, // decimals
        *as_bytes(&symbol),
        *as_bytes(&name),
        *as_bytes(&description),
        option::some(url::new_unsafe_from_bytes(image_url)),
        ctx,
    );
    transfer::public_share_object(metadata);

    let coin_info = CoinInfo {
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

    // Emit creation event
    event::emit(CoinCreated {
        name,
        symbol,
        creator: tx_context::sender(ctx),
        coin_address: object::uid_to_address(&coin_info.id),
        launch_time: tx_context::epoch(ctx),
    });

    token_launcher::increment_coins_count(launchpad);
    token_launcher::add_to_registry(registry, object::uid_to_address(&coin_info.id));
    coin_info
}

// Calculate transaction fee
fun calculate_transaction_fee(amount: u64): u64 {
    (amount * TRANSACTION_FEE_BPS) / BPS_DENOMINATOR
}

// === Buy functionality ===
public entry fun buy_tokens(
    launchpad: &token_launcher::Launchpad,
    coin_info: &mut CoinInfo,
    payment: &mut Coin<SUI>,
    amount: u64,
    ctx: &mut TxContext,
) {
    // Validate amount
    assert!(amount >= MIN_TRADE_AMOUNT, E_AMOUNT_TOO_SMALL);

    // Calculate base cost and fee
    let base_cost = bonding_curve::calculate_purchase_cost(coin_info.supply, amount);
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
    balance::join(&mut coin_info.reserve_balance, paid_balance);

    // Calculate cost in SUI
    let cost = bonding_curve::calculate_purchase_cost(coin_info.supply, amount);

    // Extract payment
    let paid = coin::split(payment, cost, ctx);
    let paid_balance = coin::into_balance(paid);
    balance::join(&mut coin_info.reserve_balance, paid_balance);

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
public entry fun sell_tokens(
    launchpad: &token_launcher::Launchpad,
    coin_info: &mut CoinInfo,
    tokens: Coin<COIN>,
    ctx: &mut TxContext,
) {
    let amount = coin::value(&tokens);

    // Calculate return amount and fee
    let return_amount = bonding_curve::calculate_sale_return(coin_info.supply, amount);
    let fee = calculate_transaction_fee(return_amount);
    let final_return_amount = return_amount - fee;

    // Validate reserve has enough balance
    assert!(balance::value(&coin_info.reserve_balance) >= return_amount, E_INSUFFICIENT_BALANCE);

    // Burn the tokens
    let treasury_cap = &mut coin_info.treasury_cap;
    coin::burn(treasury_cap, tokens);

    // Update supply
    coin_info.supply = coin_info.supply - amount;

    // Take fee and return amount from reserve
    let fee_payment = balance::split(&mut coin_info.reserve_balance, fee);
    let return_payment = balance::split(&mut coin_info.reserve_balance, final_return_amount);

    // Transfer fee to admin
    transfer::public_transfer(
        coin::from_balance(fee_payment, ctx),
        token_launcher::get_admin(launchpad),
    );

    // Send remaining amount to seller
    transfer::public_transfer(
        coin::from_balance(return_payment, ctx),
        tx_context::sender(ctx),
    );

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
public fun get_coin_info(info: &CoinInfo): (String, String, Url, address, u64, u64) {
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
public fun get_current_price(coin_info: &CoinInfo): u64 {
    bonding_curve::calculate_price(coin_info.supply)
}

// Get cost to buy specific amount
public fun get_purchase_cost(coin_info: &CoinInfo, amount: u64): u64 {
    bonding_curve::calculate_purchase_cost(coin_info.supply, amount)
}

// Get return amount for selling specific amount
public fun get_sale_return(coin_info: &CoinInfo, amount: u64): u64 {
    bonding_curve::calculate_sale_return(coin_info.supply, amount)
}

// Get just the supply
public fun get_supply(info: &CoinInfo): u64 {
    info.supply
}

// Get just the reserve balance
public fun get_reserve(info: &CoinInfo): u64 {
    balance::value(&info.reserve_balance)
}

// Get creator address
public fun get_creator(info: &CoinInfo): address {
    info.creator
}

// Get launch time
public fun get_launch_time(info: &CoinInfo): u64 {
    info.launch_time
}
