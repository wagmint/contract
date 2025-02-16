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

// Event emitted when new coin is created
public struct CoinCreated has copy, drop {
    name: String,
    symbol: String,
    creator: address,
    coin_address: address,
}

// First we need function to create a new coin type
public fun create_coin(
    launchpad: &mut token_launcher::Launchpad,
    registry: &mut LaunchedCoinsRegistry,
    name: String,
    symbol: String,
    description: String,
    image_url: vector<u8>,
    ctx: &mut TxContext,
): CoinInfo {
    // Validate inputs
    assert!(
        std::string::length(&name) > 0 && std::string::length(&name) <= 32,
        E_INVALID_NAME_LENGTH,
    );
    assert!(
        std::string::length(&symbol) > 0 && std::string::length(&symbol) <= 10,
        E_INVALID_SYMBOL_LENGTH,
    );

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
    });

    token_launcher::increment_coins_count(launchpad);
    token_launcher::add_to_registry(registry, object::uid_to_address(&coin_info.id));
    coin_info
}

// === Buy functionality ===
public entry fun buy_tokens(
    coin_info: &mut CoinInfo,
    payment: &mut Coin<SUI>,
    amount: u64,
    ctx: &mut TxContext,
) {
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
}

// === Sell functionality ===
public entry fun sell_tokens(coin_info: &mut CoinInfo, tokens: Coin<COIN>, ctx: &mut TxContext) {
    let amount = coin::value(&tokens);

    // Calculate return amount
    let return_amount = bonding_curve::calculate_sale_return(coin_info.supply, amount);
    assert!(return_amount <= balance::value(&coin_info.reserve_balance), E_INSUFFICIENT_PAYMENT);

    // Burn the tokens
    let treasury_cap = &mut coin_info.treasury_cap;
    coin::burn(treasury_cap, tokens);

    // Update supply
    coin_info.supply = coin_info.supply - amount;

    // Take SUI from reserve and send to seller
    let return_coin = coin::from_balance(
        balance::split(&mut coin_info.reserve_balance, return_amount),
        ctx,
    );
    transfer::public_transfer(return_coin, tx_context::sender(ctx)); // Changed to public_transfer
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