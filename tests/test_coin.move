module wagmint::test_coin {
    public struct TEST_COIN has drop {}
    
    // This is required for normal module init
    fun init(_: TEST_COIN, _: &mut TxContext) {}
    
    // Add a test-only function to create a fresh witness for testing
    #[test_only]
    public fun get_witness(): TEST_COIN {
        TEST_COIN {}
    }
}