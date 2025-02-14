module wagmint::wagmint;

// const TRANSACTION_FEE: u64 = 100;
// const INITIAL_FEE: u64 = 10;

use std::string::String;

// use sui::coin::{Self, Coin, TreasuryCap};
// use sui::tx_context::{Self, TxContext};
// use sui::transfer;
use sui::object::{Self, UID};
use sui::url::{Self, Url};

/// Capability that represents ownership of the contract
public struct LAUNCHPAD has key, store {
    id: UID,
    admin: address,
    launched_coins_count: u64
}

/// Metadata for each launched coin
public struct CoinMetadata has key, store {
    id: UID,
    name: String,
    symbol: String,
    image_url: Url,
    creator: address,
    launch_time: u64,
    total_supply: u64,
    current_price: u64  // Based on bonding curve
}

/// Registry to keep track of all launched coins
public struct LaunchedCoinsRegistry has key {
    id: UID,
    coins: vector<address>  // Stores addresses of all CoinMetadata objects
}

/// Struct that will represent the coin type
/// This needs to be unique for each launched coin
public struct COIN_TYPE has drop {}

/// Bonding curve parameters
public struct BondingCurveConfig has store {
    initial_price: u64,
    slope: u64,
    reserve_ratio: u64
}