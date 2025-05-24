# WagMint Token Launcher

A decentralized token launchpad built on the Sui blockchain featuring bonding curve mechanics and competitive Battle Royale events.

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Getting Started](#getting-started)
- [Configuration](#configuration)
- [Battle Royale System](#battle-royale-system)
- [API Reference](#api-reference)
- [Fee Structure](#fee-structure)
- [Security](#security)

## Overview

WagMint enables users to create and trade tokens using an automated market maker (AMM) with bonding curve pricing. The platform includes a unique Battle Royale system where token creators compete for prize pools based on their token's performance.

## Features

### 🚀 **Easy Token Creation**

- One-click token deployment with customizable metadata
- Automatic liquidity provision through virtual reserves
- No complex DEX setup required

### 📈 **Bonding Curve Trading**

- Fair price discovery through mathematical curves
- Immediate liquidity for all tokens
- Automatic slippage protection

### 🏆 **Battle Royale Competitions**

- Timed competitions with prize pools
- Performance-based rankings
- Community-driven events

### 💰 **Automated Fee Management**

- Transparent fee collection
- Battle Royale prize pool contributions
- Admin treasury management

## Architecture

### Core Modules

```
wagmint/
├── token_launcher.move    # Platform configuration & treasury
├── coin_manager.move      # Token creation & trading logic
├── bonding_curve.move     # Price calculation algorithms
├── battle_royale.move     # Competition mechanics
└── utils.move            # Mathematical utilities
```

#### Token Launcher (`token_launcher.move`)

- Configuration management (fees, reserves, decimals)
- Treasury system for collected fees
- Registry of all launched tokens
- Admin controls and withdrawals

#### Coin Manager (`coin_manager.move`)

- Token creation with metadata
- Buy/sell trading engine
- Battle Royale integration
- Protected treasury cap management

#### Bonding Curve (`bonding_curve.move`)

- Constant product formula (x \* y = k)
- Dynamic price calculations
- Token minting/burning logic
- Graduation threshold management

#### Battle Royale (`battle_royale.move`)

- Competition lifecycle management
- Prize pool distribution
- Winner registry and claims
- Fee collection from trades

## Getting Started

### Prerequisites

- Sui CLI installed
- Sui wallet with SUI tokens
- Move compiler setup

### Deployment

```bash
# Build the project
sui move build

# Deploy to network
sui client publish --gas-budget 100000000
```

### Creating Your First Token

```move
// Create a new token
public entry fun create_coin<T>(
    launchpad: &mut Launchpad,
    treasury_cap: TreasuryCap<T>,
    registry: &mut LaunchedCoinsRegistry,
    payment: Coin<SUI>,
    name: String,
    symbol: String,
    description: String,
    website: String,
    image_url: String,
    coin_type: String,
    ctx: &mut TxContext,
)
```

### Trading Tokens

```move
// Buy tokens
public entry fun buy_tokens<T>(
    launchpad: &mut Launchpad,
    coin_info: &mut CoinInfo<T>,
    payment: Coin<SUI>,
    sui_amount: u64,
    ctx: &mut TxContext,
)

// Sell tokens
public entry fun sell_tokens<T>(
    launchpad: &mut Launchpad,
    coin_info: &mut CoinInfo<T>,
    tokens: Coin<T>,
    ctx: &mut TxContext,
)
```

## Configuration

### Default Settings

| Parameter      | Value     | Description                |
| -------------- | --------- | -------------------------- |
| Platform Fee   | 1%        | Trading fee percentage     |
| Creation Fee   | 0.01 SUI  | Cost to create new token   |
| Virtual SUI    | 2,500 SUI | Initial virtual reserves   |
| Virtual Tokens | 1B        | Initial token supply       |
| Token Decimals | 6         | Precision for calculations |

### Admin Functions

```move
// Update platform configuration
public entry fun update_launchpad_config(
    lp: &mut Launchpad,
    version: u64,
    platform_fee: u64,
    creation_fee: u64,
    // ... other parameters
)

// Withdraw treasury funds
public entry fun withdraw_treasury(
    launchpad: &mut Launchpad,
    amount: u64,
    to_address: address,
    ctx: &mut TxContext,
)
```

## Battle Royale System

### Competition Flow

1. **🏁 Event Creation**

   ```move
   public entry fun create_battle_royale(
       launchpad: &Launchpad,
       name: String,
       description: String,
       start_time: u64,
       end_time: u64,
       // ... configuration parameters
   )
   ```

2. **📝 Registration**

   ```move
   public entry fun register_participant(
       launchpad: &mut Launchpad,
       br: &mut BattleRoyale,
       payment: Coin<SUI>,
       ctx: &mut TxContext,
   )
   ```

3. **🎯 Competition Trading**

   ```move
   public entry fun buy_tokens_with_br<T>(
       launchpad: &mut Launchpad,
       coin_info: &mut CoinInfo<T>,
       payment: &mut Coin<SUI>,
       sui_amount: u64,
       br: &mut BattleRoyale,
       ctx: &mut TxContext,
   )
   ```

4. **🏆 Finalization & Claims**

   ```move
   public entry fun finalize_battle_royale(
       br: &mut BattleRoyale,
       first_place_coin: address,
       second_place_coin: address,
       third_place_coin: address,
       ctx: &mut TxContext,
   )

   public entry fun claim_prize(
       winner_registry: &mut WinnerRegistry,
       ctx: &mut TxContext,
   )
   ```

### Prize Distribution

| Rank         | Prize Share | Default % |
| ------------ | ----------- | --------- |
| 🥇 1st Place | 55%         | 5,500 BPS |
| 🥈 2nd Place | 30%         | 3,000 BPS |
| 🥉 3rd Place | 15%         | 1,500 BPS |

## API Reference

### View Functions

```move
// Get token information
public fun get_coin_info<T>(info: &CoinInfo<T>): (String, String, Url, address, u64, u64)

// Get current token price
public fun get_current_price<T>(coin_info: &CoinInfo<T>): u64

// Calculate market cap
public fun calculate_market_cap<T>(coin_info: &CoinInfo<T>): u64

// Check Battle Royale status
public fun is_battle_royale_active(br: &BattleRoyale, current_time: u64): bool
```

### Events

```move
// Token creation
public struct CoinCreatedEvent has copy, drop {
    name: String,
    symbol: String,
    creator: address,
    coin_address: address,
    // ... other fields
}

// Trading activity
public struct TradeEvent has copy, drop {
    is_buy: bool,
    coin_address: address,
    user_address: address,
    token_amount: u64,
    sui_amount: u64,
    // ... other fields
}

// Battle Royale events
public struct BattleRoyaleCreatedEvent has copy, drop { /* ... */ }
public struct WinnerRegistryCreatedEvent has copy, drop { /* ... */ }
public struct PrizeClaimedEvent has copy, drop { /* ... */ }
```

## Fee Structure

### Platform Fees

- **Creation Fee**: 0.01 SUI per token
- **Trading Fee**: 1% of transaction value
- **Battle Royale Participation**: 0.1 SUI

### Battle Royale Fee Distribution

- **Platform**: 10% of participation fees
- **Prize Pool**: 90% of participation fees + 50% of trading fees during event

## Security

### Access Controls

- **Admin-only functions**: Configuration updates, treasury withdrawals, competition management
- **Time-based validations**: Prevents manipulation during active competitions
- **Balance assertions**: Ensures sufficient funds for all operations

### Protected Assets

- **Treasury Caps**: Secured in protected structs to prevent unauthorized minting
- **Prize Pools**: Isolated in winner registries with claim verification
- **Virtual Reserves**: Mathematical constraints prevent price manipulation

### Error Handling

```move
// Common error codes
const E_NOT_ADMIN: u64 = 0;
const E_INSUFFICIENT_PAYMENT: u64 = 1;
const E_BR_NOT_OPEN: u64 = 2;
const E_ALREADY_REGISTERED: u64 = 4;
const E_COIN_NOT_REGISTERED: u64 = 5;
// ... additional error codes
```
