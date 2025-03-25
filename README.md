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

### Manual Testing
Prerequisites
1. You need SUI wallet setup
1. You need `sui cli` setup, follow this [link](https://docs.sui.io/guides/developer/getting-started)
1. Connect to `sui testnet` follow this [guide](https://docs.sui.io/guides/developer/getting-started/connect)
1. When you type `sui client envs` the testnet should be selected, and when you type `sui client addresses` you should see your wallet public address show up as the output
1. If you don't have funds in your wallet, make sure to request for some via their discord channel
1. Now you are ready to make some calls to the testnet SUI blockchain

#### Creating a coin
1. Ask a friend for a boilerplate coin module folder
1. `cd` into that directory and do `sui client publish`
1. Once that is done, it will give you bunch of objects that has been created with its IDs. Make sure you capture these somewhere, if not, you can always use [suiscan](https://suiscan.xyz/testnet/home) to get these values at any time
1. Now to go makefile and take a look at `create-coin` command
1. `$(COIN_TYPE)` (i.e. can be found in column called objectType 0xaee85f74364926024c664e043e4f237e5b3f681a1e9ad3e9dd9ee50efa9104b3::my_token::MY_TOKEN) && `$(TREASURY_CAP_ID)` (ObjectID of TreasuryCap object) are fetched from the objects returned from when you published your boilerplate coin module. 
1. `$(PAYMENT_COIN_ID)` is going to be from your wallet. Use command `sui client gas` and pick a gasCoinId that has the most mist balance
1. The rest inputs can fetched from makefile defined variables at the top
1. Now copy the same struct of cli script from `make create-coin` fill in these inputs and run it
1. From the output, save the ObjectID of ObjectType `CoinInfo`, you will need it to buy coin

#### Buying a coin
1. Copy template from `make buy-tokens` command
1. Fill in the fields with the same values you used for creating a coin script
1. But for `$(COIN_INFO_ID)` fill this one in with the ObjectID of `CoinInfo` you got from `create-coin` step
1. Now run the script

#### Selling a coin
1. Copy template from `make sell-tokens` command
1. All fields are same except `$(TOKEN_COIN_ID)`
1. Here you need the objectID of the token you want to sell. There isn't an easy way to fetch this manually, so you have to get it from [suiscan](https://suiscan.xyz/testnet/home)

## Security Considerations

- Proper validation for inputs
- Access control for admin functions 
- Safe math operations
- Reserve balance management
