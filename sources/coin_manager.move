module wagmint::coin_manager;

use std::string::{Self, String, as_bytes};
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
use sui::event;
use sui::object::{Self, UID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};
use sui::url::{Self, Url};
use wagmint::token_launcher::{Self, LaunchedCoinsRegistry};

// Error codes
const E_NOT_COIN_CREATOR: u64 = 0;
const E_INVALID_NAME_LENGTH: u64 = 1;
const E_INVALID_SYMBOL_LENGTH: u64 = 2;

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
    current_supply: u64,
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
        current_supply: 0,
    };

    // Emit creation event
    event::emit(CoinCreated {
        name,
        symbol,
        creator: tx_context::sender(ctx),
        coin_address: object::uid_to_address(&coin_info.id),
    });

    token_launcher::add_to_registry(registry, object::uid_to_address(&coin_info.id));
    coin_info
}

// View functions
public fun get_coin_info(info: &CoinInfo): (String, String, Url, address, u64) {
    (info.name, info.symbol, info.image_url, info.creator, info.current_supply)
}
