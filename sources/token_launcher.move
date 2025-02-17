module wagmint::token_launcher;

use sui::event;

public struct Launchpad has key, store {
    id: UID,
    admin: address,
    launched_coins_count: u64,
}

public struct LaunchedCoinsRegistry has key {
    id: UID,
    coins: vector<address>,
}

public struct LaunchpadInitialized has copy, drop {
    admin: address,
}

const E_NOT_ADMIN: u64 = 0;

fun init(ctx: &mut TxContext) {
    let launchpad = Launchpad {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
        launched_coins_count: 0,
    };

    let registry = LaunchedCoinsRegistry {
        id: object::new(ctx),
        coins: vector::empty(),
    };

    // Emit an event when launchpad is initialized
    event::emit(LaunchpadInitialized {
        admin: tx_context::sender(ctx),
    });

    transfer::share_object(launchpad);
    transfer::share_object(registry);
}

public entry fun update__launchpad_admin(
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
