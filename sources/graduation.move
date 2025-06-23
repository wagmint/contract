module wagmint::graduation;

use cetus_clmm::config::GlobalConfig;
use cetus_clmm::factory::{Self, Pools};
use cetus_clmm::pool_creator;
use std::string::{Self, String};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, TreasuryCap, CoinMetadata};
use sui::event;
use sui::sui::SUI;
use wagmint::token_launcher;
use wagmint::utils;

// === Error Codes ===
const E_ALREADY_GRADUATED: u64 = 0;
const E_NOT_ELIGIBLE_FOR_GRADUATION: u64 = 1;

// === Events ===
public struct TokenGraduatedEvent has copy, drop {
    coin_address: address,
    graduation_time: u64,
    final_bonding_curve_price: u64,
    accumulated_sui_amount: u64,
    amm_reserve_tokens_minted: u64,
    total_supply_in_circulation: u64,
    amm_pool_id: Option<address>,
}

public struct CetusPoolCreatedEvent has copy, drop {
    pool_id: address,
    position_id: address,
    token_a_type: String,
    token_b_type: String,
    initial_liquidity_a: u64,
    initial_liquidity_b: u64,
    tick_spacing: u32,
    sqrt_price: u128,
}

// === Core Graduation Functions ===

/// Check if token meets graduation requirements
public fun check_graduation_eligibility(
    launchpad: &token_launcher::Launchpad,
    real_sui_reserves: u64,
    graduated: bool,
): bool {
    if (graduated) return false;

    // Use real SUI reserves as graduation criteria
    let graduation_threshold = token_launcher::get_graduation_threshold(launchpad);
    real_sui_reserves >= graduation_threshold
}

/// Calculate sqrt price from token amounts (simplified)
public fun calculate_initial_sqrt_price(sui_amount: u64, token_amount: u64): u128 {
    let price_ratio = utils::div(
        utils::mul(utils::from_u64(sui_amount), utils::from_u64(1000000)),
        utils::from_u64(token_amount),
    );

    let sqrt_ratio = utils::sqrt(price_ratio);

    // Convert to Q64.64 format using bit shift (2^64)
    sqrt_ratio << 64
}

/// Calculate full range ticks for maximum liquidity coverage
fun calculate_full_range_ticks(): (u32, u32) {
    pool_creator::full_range_tick_range(200)
}

/// Graduate token to AMM (Cetus integration)
public fun execute_graduation<T>(
    launchpad: &mut token_launcher::Launchpad,
    treasury_cap: &mut TreasuryCap<T>,
    accumulated_sui_balance: Balance<SUI>,
    amm_reserve_tokens_amount: u64,
    coin_address: address,
    coin_type: String,
    final_bc_price: u64,
    total_supply_in_circulation: u64,
    graduated: bool,
    real_sui_reserves: u64,
    cetus_config: &GlobalConfig,
    cetus_pools: &mut Pools,
    coin_a_metadata: &CoinMetadata<SUI>,
    coin_b_metadata: &CoinMetadata<T>,
    clock: &Clock,
    ctx: &mut TxContext,
): (u64, u64, address) {
    // Validation at the start
    assert!(!graduated, E_ALREADY_GRADUATED);
    assert!(
        check_graduation_eligibility(launchpad, real_sui_reserves, graduated),
        E_NOT_ELIGIBLE_FOR_GRADUATION,
    );

    let accumulated_sui_amount = balance::value(&accumulated_sui_balance);

    // Mint reserved tokens for AMM (20% of total supply)
    let amm_reserve_tokens = coin::mint(
        treasury_cap,
        amm_reserve_tokens_amount,
        ctx,
    );
    let amm_reserve_tokens_minted = coin::value(&amm_reserve_tokens);

    // Calculate sqrt price
    let sqrt_price = calculate_initial_sqrt_price(
        accumulated_sui_amount,
        amm_reserve_tokens_minted,
    );

    // Step 1: Create pool creation capability
    let pool_creator_cap = factory::mint_pool_creation_cap<T>(
        cetus_config,
        cetus_pools,
        treasury_cap,
        ctx,
    );

    // Step 2: Register the permission pair (Token/SUI with tick spacing 200)
    factory::register_permission_pair<T, SUI>(
        cetus_config,
        cetus_pools,
        200, // tick spacing
        &pool_creator_cap,
        ctx,
    );

    // Step 3: Generate the pool key to get the pool ID later
    let pool_key = factory::new_pool_key<T, SUI>(200);

    // Step 4: Create pool with the creation cap
    let (tick_lower, tick_upper) = calculate_full_range_ticks();
    let (position, return_sui, return_tokens) = pool_creator::create_pool_v2_with_creation_cap<
        T,
        SUI,
    >(
        cetus_config,
        cetus_pools,
        &pool_creator_cap,
        200, // tick spacing
        sqrt_price,
        string::utf8(b""), // pool icon URL
        tick_lower,
        tick_upper,
        amm_reserve_tokens, // Token liquidity (coin A)
        coin::from_balance(accumulated_sui_balance, ctx), // SUI liquidity (coin B)
        coin_b_metadata, // Token metadata
        coin_a_metadata, // SUI metadata
        false, // fix_amount_a
        clock,
        ctx,
    );

    // Step 5: Get the actual pool ID using the pool key
    let pool_info = factory::pool_simple_info(cetus_pools, pool_key);
    let actual_pool_id = factory::pool_id(pool_info);
    let pool_address = object::id_to_address(&actual_pool_id);

    // Emit Cetus pool creation event with correct pool ID
    event::emit(CetusPoolCreatedEvent {
        pool_id: pool_address,
        position_id: object::id_to_address(&object::id(&position)),
        token_a_type: coin_type, // T comes first in T,SUI pair
        token_b_type: string::utf8(b"SUI"),
        initial_liquidity_a: amm_reserve_tokens_minted,
        initial_liquidity_b: accumulated_sui_amount,
        tick_spacing: 200,
        sqrt_price,
    });

    // Transfer LP position and creation cap to dead address (burn them)
    let dead_address = @0x0000000000000000000000000000000000000000000000000000000000000000;
    transfer::public_transfer(position, dead_address);
    transfer::public_transfer(pool_creator_cap, dead_address);

    // Handle returned coins - send any returns to protocol treasury
    let protocol_treasury = token_launcher::get_admin(launchpad);
    if (coin::value(&return_sui) > 0) {
        transfer::public_transfer(return_sui, protocol_treasury);
    } else {
        coin::destroy_zero(return_sui);
    };

    if (coin::value(&return_tokens) > 0) {
        transfer::public_transfer(return_tokens, protocol_treasury);
    } else {
        coin::destroy_zero(return_tokens);
    };

    // Emit graduation event with correct pool ID
    event::emit(TokenGraduatedEvent {
        coin_address,
        graduation_time: tx_context::epoch_timestamp_ms(ctx),
        final_bonding_curve_price: final_bc_price,
        accumulated_sui_amount,
        amm_reserve_tokens_minted,
        total_supply_in_circulation,
        amm_pool_id: option::some(pool_address), // Use actual pool address
    });

    (accumulated_sui_amount, amm_reserve_tokens_minted, pool_address)
}

// === View Functions ===

/// Get graduation progress information
public fun get_graduation_progress(
    launchpad: &token_launcher::Launchpad,
    current_sui_reserves: u64,
): (u64, u64, u64) {
    let graduation_threshold = token_launcher::get_graduation_threshold(launchpad);

    let progress_percentage = if (graduation_threshold > 0) {
        utils::as_u64(
            utils::div(
                utils::mul(utils::from_u64(current_sui_reserves), utils::from_u64(10000)),
                utils::from_u64(graduation_threshold),
            ),
        )
    } else { 0 };

    (current_sui_reserves, graduation_threshold, progress_percentage)
}

/// Get estimated AMM liquidity upon graduation
public fun get_estimated_amm_liquidity(
    real_sui_reserves: u64,
    amm_reserve_tokens: u64,
): (u64, u64) {
    (real_sui_reserves, amm_reserve_tokens)
}
