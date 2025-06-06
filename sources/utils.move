module wagmint::utils;

use std::ascii;
use std::string;

const BPS_DENOMINATOR: u64 = 10000;

// High precision representation of numbers
// We use u128 for increased precision in calculations
// For very large numbers, we could extend this to handle even larger values

/// Convert a u64 to a u128 for higher precision calculations
public fun from_u64(value: u64): u128 {
    (value as u128)
}

/// Convert a u128 back to u64, truncating if necessary
/// Warning: This will truncate values larger than u64::MAX
public fun as_u64(value: u128): u64 {
    if (value > 18446744073709551615) {
        // u64::MAX
        18446744073709551615 // Return max u64 value if overflow
    } else {
        (value as u64)
    }
}

/// Multiply two u128 values
public fun mul(a: u128, b: u128): u128 {
    a * b
}

/// Safely divide two u128 values, handling division by zero
public fun div(a: u128, b: u128): u128 {
    if (b == 0) {
        return 0
    };
    a / b
}

/// Add two u128 values
public fun add(a: u128, b: u128): u128 {
    a + b
}

/// Subtract b from a, returning 0 if b > a
public fun sub(a: u128, b: u128): u128 {
    if (b > a) {
        0
    } else {
        a - b
    }
}

/// Compute a percentage of a value using basis points
/// (1% = 100 basis points)
public fun percentage_of(value: u128, bps: u64): u128 {
    div(
        mul(value, from_u64(bps)),
        from_u64(BPS_DENOMINATOR),
    )
}

/// Calculate square root for u128 values
/// Used in some advanced bonding curve calculations
public fun sqrt(x: u128): u128 {
    if (x == 0) {
        return 0
    };

    // Initial guess - a power of 2 close to the square root
    let mut bit_length = 0;
    let mut temp = x;
    while (temp > 0) {
        temp = temp >> 1;
        bit_length = bit_length + 1;
    };
    let mut guess = 1 << ((bit_length >> 1) + 1);

    // Newton's method for square root
    // Iteratively improve the guess
    let mut prev_guess = 0;
    while (guess != prev_guess) {
        prev_guess = guess;
        guess = (guess + div(x, guess)) >> 1;
    };

    guess
}

/// Check if a u64 value is safe to perform operations on without overflow
public fun is_safe_u64(value: u64): bool {
    value <= 9223372036854775807 // 2^63 - 1, half of u64::MAX for safe operations
}

/// Calculate a power function (base^exponent) for integer exponents
public fun pow(base: u128, exponent: u64): u128 {
    if (exponent == 0) {
        return 1
    };

    let mut result: u128 = 1;
    let mut b = base;
    let mut e = exponent;

    while (e > 0) {
        if (e & 1 == 1) {
            result = result * b;
        };
        e = e >> 1;
        if (e > 0) {
            b = b * b;
        };
    };

    result
}

public fun ascii_to_string(ascii_str: &ascii::String): string::String {
    // Get the bytes from the ASCII string
    let bytes = ascii::as_bytes(ascii_str);

    // Create a UTF-8 string from those bytes
    // This is safe because ASCII is a subset of UTF-8
    string::utf8(*bytes)
}
