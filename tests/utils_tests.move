module wagmint::utils_tests;

use wagmint::utils::{add, as_u64, div, from_u64, is_safe_u64, mul, percentage_of, pow, sqrt, sub};

#[test]
fun test_arithmetic_operations() {
    // Test from_u64 and as_u64
    assert!(as_u64(from_u64(100)) == 100, 0);

    // Test mul
    assert!(mul(from_u64(7), from_u64(6)) == 42, 0);

    // Test div
    assert!(div(from_u64(42), from_u64(7)) == 6, 0);
    assert!(div(from_u64(5), from_u64(2)) == 2, 0); // Integer division

    // Test add
    assert!(add(from_u64(40), from_u64(2)) == 42, 0);

    // Test sub
    assert!(sub(from_u64(50), from_u64(8)) == 42, 0);
    assert!(sub(from_u64(5), from_u64(10)) == 0, 0); // Underflow protection

    // Test percentage_of
    assert!(percentage_of(from_u64(10000), 1000) == 1000, 0); // 10% of 10000
    assert!(percentage_of(from_u64(1000), 50) == 5, 0); // 0.5% of 1000

    // Test sqrt
    assert!(sqrt(from_u64(16)) == 4, 0);
    assert!(sqrt(from_u64(100)) == 10, 0);

    // Test is_safe_u64
    assert!(is_safe_u64(100), 0);
    assert!(is_safe_u64(9223372036854775807), 0); // Max safe value

    // Test pow
    assert!(pow(2, 3) == 8, 0);
    assert!(pow(10, 3) == 1000, 0);
}
