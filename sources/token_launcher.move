module wagmint::token_launcher;

use sui::event;

const MIN_TRADE_AMOUNT: u64 = 1;
const PLATFORM_FEE_BPS: u64 = 50; // 0.5%
const BPS_DENOMINATOR: u64 = 10000;
const DEFAULT_INIT_VIRTUAL_SUI: u64 = 3_000_000_000_000; // 3,000 SUI
const DEFAULT_INIT_VIRTUAL_TOKEN: u64 = 10_000_000_000_000_000; // 10T tokens
const DEFAULT_REMAIN_TOKEN: u64 = 2_000_000_000_000_000; // 2T tokens
const DEFAULT_DECIMAL: u8 = 6;
const GRADUATION_THRESHOLD: u64 = 6_000_000_000_000; // 6,000 SUI
const CURRENT_VERSION: u64 = 5;

// Configuration for all tokens
public struct Configuration has key, store {
    id: UID,
    version: u64,
    admin: address,
    platform_fee: u64,
    graduated_fee: u64,
    initial_virtual_sui_reserves: u64,
    initial_virtual_token_reserves: u64,
    remain_token_reserves: u64,
    token_decimals: u8,
}

public struct Launchpad has key, store {
    id: UID,
    admin: address,
    launched_coins_count: u64,
    conifg: Configuration,
}

public struct LaunchedCoinsRegistry has key {
    id: UID,
    coins: vector<address>,
}

public struct LaunchpadInitializedEvent has copy, drop {
    admin: address,
}

const E_NOT_ADMIN: u64 = 0;

fun init(ctx: &mut TxContext) {
    let config = Configuration {
        id: object::new(ctx),
        version: CURRENT_VERSION,
        admin: tx_context::sender(ctx),
        platform_fee: PLATFORM_FEE_BPS,
        graduated_fee: 0,
        initial_virtual_sui_reserves: DEFAULT_INIT_VIRTUAL_SUI,
        initial_virtual_token_reserves: DEFAULT_INIT_VIRTUAL_TOKEN,
        remain_token_reserves: DEFAULT_REMAIN_TOKEN,
        token_decimals: DEFAULT_DECIMAL,
    };

    let launchpad = Launchpad {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
        launched_coins_count: 0,
        conifg: config,
    };

    let registry = LaunchedCoinsRegistry {
        id: object::new(ctx),
        coins: vector::empty(),
    };

    // Emit an event when launchpad is initialized
    event::emit(LaunchpadInitializedEvent {
        admin: tx_context::sender(ctx),
    });

    transfer::public_share_object(launchpad);
    transfer::share_object(registry);
}

public entry fun update_launchpad_admin(
    lp: &mut Launchpad, // passed by value so we own it
    new_admin: address,
    ctx: &mut TxContext,
) {
    assert!(lp.admin == tx_context::sender(ctx), E_NOT_ADMIN);
    lp.admin = new_admin;
}

public fun increment_coins_count(launchpad: &mut Launchpad) {
    launchpad.launched_coins_count = launchpad.launched_coins_count + 1;
}

public fun add_to_registry(registry: &mut LaunchedCoinsRegistry, coin_address: address) {
    vector::push_back(&mut registry.coins, coin_address);
}

// === View Functions ===
public fun launched_coins_count(launchpad: &Launchpad): u64 {
    launchpad.launched_coins_count
}

public fun get_launched_coins(registry: &LaunchedCoinsRegistry): vector<address> {
    *&registry.coins
}

public fun get_admin(launchpad: &Launchpad): address {
    launchpad.admin
}

// Add test helper function
#[test_only]
public(package) fun create_launchpad_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
