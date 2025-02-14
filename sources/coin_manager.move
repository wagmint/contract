module wagmint::coin_manager;

use std::string::String;
use sui::object::{Self, UID};
use sui::url::{Self, Url};

public struct CoinMetadata has key, store {
    id: UID,
    name: String,
    symbol: String,
    image_url: Url,
    creator: address,
    launch_time: u64,
    total_supply: u64,
    current_price: u64,
}
