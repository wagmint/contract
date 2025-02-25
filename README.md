# Contract

A decentralized token launching platform built on the SUI blockchain inspired by pump.fun, allowing users to create and trade tokens using a bonding curve pricing model.

## Overview

This project implements a token creation and trading platform on SUI blockchain using Move language. The platform allows:

- Creating custom tokens with name, symbol, and image URL
- Trading tokens using a quadratic bonding curve (price = supply²/2,000,000)
- Automated market making with built-in liquidity
- Fee collection for platform sustainability

## Modules

### 1. Token Launcher (`token_launcher.move`)

Core registry for the platform that keeps track of launched tokens.

- Maintains the launchpad object and admin controls
- Tracks all launched coins
- Provides admin functionality

### 2. Coin Manager (`coin_manager.move`)

Handles token creation and trading operations.

- Creating new tokens with custom metadata
- Buying tokens (minting via bonding curve)
- Selling tokens (burning via bonding curve)
- View functions for prices and token info

### 3. Bonding Curve (`bonding_curve.move`)

Implements the mathematical pricing model.

- Calculation of token prices based on supply
- Purchase cost calculation
- Sale return calculation

## Key Features

### Bonding Curve

The platform uses a quadratic bonding curve where:
- Price = supply² / 2,000,000
- Early tokens are cheaper
- Price increases as supply increases
- Provides automated price discovery

### Fee Structure

- Creation Fee: 1 SUI to create a new token
- Transaction Fee: 1% on all trades
- Fees go to the platform admin

### Object Model

- `Launchpad`: Shared object for platform management
- `LaunchedCoinsRegistry`: Shared registry of all tokens
- `CoinInfo<T>`: Shared object for each token's data and trading

## Usage

### Creating a Token

```move
// Define your token type
struct MYCOIN has drop {}

// Create the token
let witness = MYCOIN {};
let coin_address = coin_manager::create_coin(
    witness,
    &mut launchpad,
    &mut registry,
    &mut payment,
    "My Awesome Token",
    "AWESOME",
    "A token for awesome people",
    image_url_bytes,
    option::none(), // Use default fee
    ctx
);
```

### Buying Tokens

```move
coin_manager::buy_tokens(
    &launchpad,
    &mut coin_info,
    &mut payment,
    100, // Amount to buy
    ctx
);
```

### Selling Tokens

```move
coin_manager::sell_tokens(
    &launchpad,
    &mut coin_info,
    tokens_to_sell,
    ctx
);
```

## Testing

The codebase includes comprehensive tests:
- Unit tests for calculations
- Tests for token creation
- Tests for buying/selling
- Tests for admin functions

To run tests:
```bash
sui move test
```

## Security Considerations

- Proper validation for inputs
- Access control for admin functions 
- Safe math operations
- Reserve balance management
