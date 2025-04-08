module wagmint::token_launcher;

use sui::event;

// Constants
const PLATFORM_FEE_BPS: u64 = 100; // 1%
const CREATION_FEE: u64 = 500_000_000; // 0.5 SUI
const CURRENT_VERSION: u64 = 1;

public struct Configuration has copy, store {
    version: u64,
    platform_fee: u64,
    creation_fee: u64,
    graduation_fee: u64,
}

public struct Launchpad has key, store {
    id: UID,
    admin: address,
    launched_coins_count: u64,
    config: Configuration,
}

public struct LaunchedCoinsRegistry has key {
    id: UID,
    coins: vector<address>,
}

public struct LaunchpadInitializedEvent has copy, drop {
    admin: address,
}

public struct ConfigurationUpdatedEvent has copy, drop {
    old_version: u64,
    old_platform_fee: u64,
    old_creation_fee: u64,
    old_graduation_fee: u64,
    new_version: u64,
    new_platform_fee: u64,
    new_creation_fee: u64,
    new_graduation_fee: u64,
}

const E_NOT_ADMIN: u64 = 0;

fun init(ctx: &mut TxContext) {
    let config = Configuration {
        version: CURRENT_VERSION,
        platform_fee: PLATFORM_FEE_BPS,
        creation_fee: CREATION_FEE,
        graduation_fee: 0,
    };

    let launchpad = Launchpad {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
        launched_coins_count: 0,
        config: config,
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
    lp: &mut Launchpad,
    new_admin: address,
    ctx: &mut TxContext,
) {
    assert!(lp.admin == tx_context::sender(ctx), E_NOT_ADMIN);
    lp.admin = new_admin;
}

public entry fun update_launchpad_config(
    lp: &mut Launchpad,
    version: u64,
    platform_fee: u64,
    creation_fee: u64,
    graduation_fee: u64,
    ctx: &mut TxContext,
) {
    assert!(lp.admin == tx_context::sender(ctx), E_NOT_ADMIN);
    let old_version = lp.config.version;
    let old_platform_fee = lp.config.platform_fee;
    let old_creation_fee = lp.config.creation_fee;
    let old_graduation_fee = lp.config.graduation_fee;

    lp.config.version = version;
    lp.config.platform_fee = platform_fee;
    lp.config.creation_fee = creation_fee;
    lp.config.graduation_fee = graduation_fee;

    // Emit an event when launchpad config is updated
    event::emit(ConfigurationUpdatedEvent {
        old_version: old_version,
        old_platform_fee: old_platform_fee,
        old_creation_fee: old_creation_fee,
        old_graduation_fee: old_graduation_fee,
        new_version: version,
        new_platform_fee: platform_fee,
        new_creation_fee: creation_fee,
        new_graduation_fee: graduation_fee,
    });
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

public fun get_config(launchpad: &Launchpad): Configuration {
    launchpad.config
}

public fun get_platform_fee(launchpad: &Launchpad): u64 {
    launchpad.config.platform_fee
}

public fun get_creation_fee(launchpad: &Launchpad): u64 {
    launchpad.config.creation_fee
}

public fun get_graduation_fee(launchpad: &Launchpad): u64 {
    launchpad.config.graduation_fee
}

public fun get_version(launchpad: &Launchpad): u64 {
    launchpad.config.version
}

// Add test helper function
#[test_only]
public(package) fun create_launchpad_for_testing(ctx: &mut TxContext) {
    init(ctx)
}
