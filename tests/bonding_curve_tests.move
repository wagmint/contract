module wagmint::bonding_curve_tests;

use wagmint::bonding_curve;

// Test error codes
const E_WRONG_CONSTANT_PRODUCT: u64 = 100;
const E_WRONG_PRICE: u64 = 101;
const E_WRONG_TOKENS_TO_MINT: u64 = 102;
const E_WRONG_SALE_RETURN: u64 = 103;

#[test]
fun test_calculate_constant_product() {
    let initial_virtual_sui = 1000;
    let initial_virtual_tokens = 2000;
    let k = bonding_curve::calculate_constant_product(initial_virtual_sui, initial_virtual_tokens);
    
    assert!(k == 2000000, E_WRONG_CONSTANT_PRODUCT);
}

#[test]
fun test_calculate_price() {
    // Test with zero token reserves
    assert!(bonding_curve::calculate_price(1000, 0) == 0, E_WRONG_PRICE);
    
    // Test with normal values
    assert!(bonding_curve::calculate_price(1000, 2000) == 0, E_WRONG_PRICE);
    assert!(bonding_curve::calculate_price(2000, 1000) == 2, E_WRONG_PRICE);
}

#[test]
fun test_calculate_tokens_to_mint() {
    let virtual_sui = 1000;
    let virtual_tokens = 2000;
    let sui_amount = 100;
    
    let tokens_to_mint = bonding_curve::calculate_tokens_to_mint(virtual_sui, virtual_tokens, sui_amount);
    
    // Using the formula: tokens_to_mint = virtual_token_reserves - (virtual_sui_reserves * virtual_token_reserves) / (virtual_sui_reserves + sui_amount)
    // 2000 - (1000 * 2000) / (1000 + 100) = 2000 - 2000000/1100 = 2000 - 1818.18... = ~182
    assert!(tokens_to_mint == 181, E_WRONG_TOKENS_TO_MINT);
}

#[test]
fun test_calculate_sale_return() {
    let virtual_sui = 1000;
    let virtual_tokens = 2000;
    let token_amount = 100;
    
    let sale_return = bonding_curve::calculate_sale_return(virtual_sui, virtual_tokens, token_amount);
    
    // Using the formula: sui_to_return = virtual_sui_reserves - (virtual_sui_reserves * virtual_token_reserves) / (virtual_token_reserves + token_amount)
    // 1000 - (1000 * 2000) / (2000 + 100) = 1000 - 2000000/2100 = 1000 - 952.38... = ~48
    assert!(sale_return == 47, E_WRONG_SALE_RETURN);
}

#[test]
#[expected_failure(abort_code = 0)] // E_ZERO_SUPPLY
fun test_sale_return_amount_exceeds_supply() {
    bonding_curve::calculate_sale_return(1000, 100, 200);
}

#[test]
fun test_tokens_and_sale_impact() {
    // Setup initial reserves
    let virtual_sui = 1000;
    let virtual_tokens = 2000;
    let sui_to_spend = 100;
    
    // Buy tokens
    let tokens_minted = bonding_curve::calculate_tokens_to_mint(virtual_sui, virtual_tokens, sui_to_spend);
    
    // Updated virtual reserves after purchase
    let new_virtual_sui = virtual_sui + sui_to_spend;
    let new_virtual_tokens = virtual_tokens - tokens_minted;
    
    // Sell the same tokens back
    let sui_returned = bonding_curve::calculate_sale_return(new_virtual_sui, new_virtual_tokens, tokens_minted);
    
    // There should be some "slippage" due to the bonding curve mechanics
    assert!(sui_returned < sui_to_spend, E_WRONG_SALE_RETURN);
}

#[test]
fun test_has_reached_graduation_threshold() {
    let graduation_threshold = 1000;
    
    assert!(bonding_curve::has_reached_graduation_threshold(900, graduation_threshold) == false, 0);
    assert!(bonding_curve::has_reached_graduation_threshold(1000, graduation_threshold) == true, 0);
    assert!(bonding_curve::has_reached_graduation_threshold(1100, graduation_threshold) == true, 0);
}