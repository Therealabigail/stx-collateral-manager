# Collateral Vault Smart Contract

A Clarity smart contract for the Stacks blockchain that enables users to create collateralized debt positions (CDPs). Users can deposit STX tokens as collateral, borrow against them, and manage their positions in a decentralized manner.

## Overview

The Collateral Vault contract implements a lending protocol where users can deposit collateral (STX tokens) and borrow against it. The system enforces a minimum collateralization ratio to ensure the protocol remains solvent. If a user's position becomes undercollateralized, it can be liquidated by other participants.

### Key Parameters

- **Collateralization Ratio**: 150% (users must maintain at least $1.50 worth of collateral for every $1.00 borrowed)
- **Liquidation Threshold**: 130% (positions can be liquidated if the collateral ratio falls below this level)
- **Protocol Fee**: 1% (charged on repayments, adjustable by contract owner)

## Features

- **Vault Creation**: Users can create individual vaults to manage their collateral and debt positions
- **Collateral Management**: Deposit and withdraw STX tokens as collateral
- **Borrowing**: Borrow against collateral up to the maximum allowed by the collateralization ratio
- **Repayment**: Repay outstanding debt with a small protocol fee
- **Liquidation**: Undercollateralized positions can be liquidated by any user
- **Price Feeds**: Oracle functionality to update asset prices
- **Administrative Controls**: Contract owner can manage protocol parameters

## Contract Architecture

### Data Structures

The contract uses the following key data structures:

- **Vaults Map**: Stores user vault information, including collateral amount, debt amount, and last update time
- **Price Feeds Map**: Stores price data for different assets
- **Global Variables**: Tracks total collateral, total debt, vault count, and protocol fee

### Constants

- `ERR_UNAUTHORIZED`: Error code for unauthorized operations (u1)
- `ERR_INSUFFICIENT_COLLATERAL`: Error code for insufficient collateral (u2)
- `ERR_INSUFFICIENT_LIQUIDITY`: Error code for insufficient contract liquidity (u3)
- `ERR_VAULT_UNDERCOLLATERALIZED`: Error code for undercollateralized operations (u4)
- `ERR_NO_VAULT`: Error code when vault doesn't exist (u5)
- `ERR_VAULT_ALREADY_EXISTS`: Error code when vault already exists (u6)
- `COLLATERAL_RATIO`: Required collateralization ratio (u150, representing 150%)
- `LIQUIDATION_RATIO`: Threshold for liquidation (u130, representing 130%)

## Function Reference

### Read-Only Functions

#### `get-vault`

```clarity
(define-read-only (get-vault (owner principal))
  (map-get? vaults { owner: owner })
)
```

Retrieves a user's vault information.

**Parameters:**
- `owner`: The principal (wallet address) of the vault owner

**Returns:**
- Vault information if it exists, or `none` if it doesn't

#### `get-collateral-ratio`

```clarity
(define-read-only (get-collateral-ratio (owner principal))
  (let (
    (vault (unwrap! (get-vault owner) (err ERR_NO_VAULT)))
    (collateral-value (* (get collateral-amount vault) (get-stx-price)))
    (debt-amount (get debt-amount vault))
  )
  (if (is-eq debt-amount u0)
    u0
    (/ (* collateral-value u100) debt-amount)
  ))
)
```

Calculates the current collateralization ratio for a vault.

**Parameters:**
- `owner`: The principal (wallet address) of the vault owner

**Returns:**
- The collateralization ratio as a percentage (e.g., u150 for 150%), or u0 if there's no debt

#### `get-stx-price`

```clarity
(define-read-only (get-stx-price)
  (default-to u100 (get price (map-get? price-feeds { asset: "STX" })))
)
```

Gets the current price of STX tokens.

**Returns:**
- The current STX price, defaulting to u100 if not set

#### `get-max-borrow-amount`

```clarity
(define-read-only (get-max-borrow-amount (owner principal))
  (let (
    (vault (unwrap! (get-vault owner) u0))
    (collateral-value (* (get collateral-amount vault) (get-stx-price)))
  )
  (/ (* collateral-value u100) COLLATERAL_RATIO)
  )
)
```

Calculates the maximum amount a user can borrow based on their collateral.

**Parameters:**
- `owner`: The principal (wallet address) of the vault owner

**Returns:**
- The maximum borrowable amount

### Public Functions

#### `create-vault`

```clarity
(define-public (create-vault)
  (let (
    (owner tx-sender)
    (existing-vault (get-vault owner))
  )
  (asserts! (is-none existing-vault) (err ERR_VAULT_ALREADY_EXISTS))
  
  (map-set vaults
    { owner: owner }
    {
      collateral-amount: u0,
      debt-amount: u0,
      last-update: block-height
    }
  )
  
  (var-set vault-count (+ (var-get vault-count) u1))
  (ok true))
)
```

Creates a new vault for the caller.

**Returns:**
- `(ok true)` on success, or an error if the vault already exists

#### `deposit-collateral`

```clarity
(define-public (deposit-collateral (amount uint))
  (let (
    (owner tx-sender)
    (vault (unwrap! (get-vault owner) (err ERR_NO_VAULT)))
  )
  ;; Transfer STX from user to contract
  (try! (stx-transfer? amount owner (as-contract tx-sender)))
  
  ;; Update vault
  (map-set vaults
    { owner: owner }
    {
      collateral-amount: (+ (get collateral-amount vault) amount),
      debt-amount: (get debt-amount vault),
      last-update: block-height
    }
  )
  
  ;; Update total collateral
  (var-set total-collateral (+ (var-get total-collateral) amount))
  (ok true))
)
```

Deposits STX tokens as collateral into the user's vault.

**Parameters:**
- `amount`: The amount of STX to deposit

**Returns:**
- `(ok true)` on success, or an error if the transaction fails

#### `withdraw-collateral`

```clarity
(define-public (withdraw-collateral (amount uint))
  (let (
    (owner tx-sender)
    (vault (unwrap! (get-vault owner) (err ERR_NO_VAULT)))
    (current-collateral (get collateral-amount vault))
    (current-debt (get debt-amount vault))
  )
  ;; Assert user has enough collateral
  (asserts! (<= amount current-collateral) (err ERR_INSUFFICIENT_COLLATERAL))
  
  ;; Calculate new collateral ratio after withdrawal
  (let (
    (new-collateral (- current-collateral amount))
    (new-collateral-value (* new-collateral (get-stx-price)))
    (new-ratio (if (is-eq current-debt u0)
                    u0
                    (/ (* new-collateral-value u100) current-debt)))
  )
  ;; Check if withdrawal would make vault undercollateralized
  (asserts! (or (is-eq current-debt u0) (>= new-ratio COLLATERAL_RATIO)) (err ERR_VAULT_UNDERCOLLATERALIZED))
  
  ;; Transfer STX from contract to user
  (try! (as-contract (stx-transfer? amount (as-contract tx-sender) owner)))
  
  ;; Update vault
  (map-set vaults
    { owner: owner }
    {
      collateral-amount: new-collateral,
      debt-amount: current-debt,
      last-update: block-height
    }
  )
  
  ;; Update total collateral
  (var-set total-collateral (- (var-get total-collateral) amount))
  (ok true))
)
```

Withdraws STX tokens from the user's vault.

**Parameters:**
- `amount`: The amount of STX to withdraw

**Returns:**
- `(ok true)` on success, or an error if the withdrawal would make the vault undercollateralized

#### `borrow`

```clarity
(define-public (borrow (amount uint))
  (let (
    (owner tx-sender)
    (vault (unwrap! (get-vault owner) (err ERR_NO_VAULT)))
    (current-collateral (get collateral-amount vault))
    (current-debt (get debt-amount vault))
    (collateral-value (* current-collateral (get-stx-price)))
    (max-borrow (/ (* collateral-value u100) COLLATERAL_RATIO))
    (new-debt (+ current-debt amount))
  )
  ;; Check if user can borrow the requested amount
  (asserts! (<= new-debt max-borrow) (err ERR_VAULT_UNDERCOLLATERALIZED))
  
  ;; Check if contract has enough liquidity
  (asserts! (<= amount (stx-get-balance (as-contract tx-sender))) (err ERR_INSUFFICIENT_LIQUIDITY))
  
  ;; Transfer STX from contract to user
  (try! (as-contract (stx-transfer? amount (as-contract tx-sender) owner)))
  
  ;; Update vault
  (map-set vaults
    { owner: owner }
    {
      collateral-amount: current-collateral,
      debt-amount: new-debt,
      last-update: block-height
    }
  )
  
  ;; Update total debt
  (var-set total-debt (+ (var-get total-debt) amount))
  (ok true))
)
```

Borrows STX tokens against the user's collateral.

**Parameters:**
- `amount`: The amount of STX to borrow

**Returns:**
- `(ok true)` on success, or an error if the borrowing would make the vault undercollateralized

#### `repay`

```clarity
(define-public (repay (amount uint))
  (let (
    (owner tx-sender)
    (vault (unwrap! (get-vault owner) (err ERR_NO_VAULT)))
    (current-debt (get debt-amount vault))
    (repay-amount (if (> amount current-debt) current-debt amount))
    (fee (/ (* repay-amount (var-get protocol-fee-percent)) u100))
    (actual-repay (- repay-amount fee))
  )
  ;; Transfer STX from user to contract
  (try! (stx-transfer? repay-amount owner (as-contract tx-sender)))
  
  ;; Update vault
  (map-set vaults
    { owner: owner }
    {
      collateral-amount: (get collateral-amount vault),
      debt-amount: (- current-debt actual-repay),
      last-update: block-height
    }
  )
  
  ;; Update total debt
  (var-set total-debt (- (var-get total-debt) actual-repay))
  (ok true))
)
```

Repays debt from a user's vault.

**Parameters:**
- `amount`: The amount of STX to repay

**Returns:**
- `(ok true)` on success

#### `liquidate`

```clarity
(define-public (liquidate (user principal))
  (let (
    (liquidator tx-sender)
    (vault (unwrap! (get-vault user) (err ERR_NO_VAULT)))
    (collateral-amount (get collateral-amount vault))
    (debt-amount (get debt-amount vault))
    (ratio (get-collateral-ratio user))
  )
  ;; Check if vault is below liquidation threshold
  (asserts! (< ratio LIQUIDATION_RATIO) (err u7))
  
  ;; Transfer debt amount from liquidator to contract to pay off the user's debt
  (try! (stx-transfer? debt-amount liquidator (as-contract tx-sender)))
  
  ;; Transfer all collateral to liquidator as reward (with a discount)
  (try! (as-contract (stx-transfer? collateral-amount (as-contract tx-sender) liquidator)))
  
  ;; Clear the vault
  (map-set vaults
    { owner: user }
    {
      collateral-amount: u0,
      debt-amount: u0,
      last-update: block-height
    }
  )
  
  ;; Update totals
  (var-set total-collateral (- (var-get total-collateral) collateral-amount))
  (var-set total-debt (- (var-get total-debt) debt-amount))
  (ok true))
)
```

Liquidates an undercollateralized vault.

**Parameters:**
- `user`: The principal (wallet address) of the vault to liquidate

**Returns:**
- `(ok true)` on success, or an error if the vault cannot be liquidated

### Administrative Functions

#### `set-price-feed`

```clarity
(define-public (set-price-feed (asset (string-ascii 32)) (price uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
    (map-set price-feeds { asset: asset } { price: price })
    (ok true))
)
```

Sets or updates the price of an asset.

**Parameters:**
- `asset`: The asset identifier (string)
- `price`: The price value

**Returns:**
- `(ok true)` on success, or an error if the caller is not the contract owner

#### `set-protocol-fee`

```clarity
(define-public (set-protocol-fee (new-fee uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
    (asserts! (<= new-fee u10) (err u8)) ;; Max fee 10%
    (var-set protocol-fee-percent new-fee)
    (ok true))
)
```

Updates the protocol fee percentage.

**Parameters:**
- `new-fee`: The new fee percentage (cannot exceed 10%)

**Returns:**
- `(ok true)` on success, or an error if the caller is not the contract owner

#### `transfer-ownership`

```clarity
(define-public (transfer-ownership (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
    (var-set contract-owner new-owner)
    (ok true))
)
```

Transfers contract ownership to a new principal.

**Parameters:**
- `new-owner`: The principal (wallet address) of the new owner

**Returns:**
- `(ok true)` on success, or an error if the caller is not the current contract owner

## Usage Examples

### Creating a Vault and Depositing Collateral

```clarity
;; Create a new vault
(contract-call? .collateral-vault create-vault)

;; Deposit 1000 STX as collateral
(contract-call? .collateral-vault deposit-collateral u1000)
```

### Borrowing Against Collateral

```clarity
;; Check maximum borrowable amount
(contract-call? .collateral-vault get-max-borrow-amount tx-sender)

;; Borrow 500 STX
(contract-call? .collateral-vault borrow u500)
```

### Repaying Debt

```clarity
;; Repay 100 STX of debt
(contract-call? .collateral-vault repay u100)
```

### Withdrawing Collateral

```clarity
;; Withdraw 200 STX of collateral
(contract-call? .collateral-vault withdraw-collateral u200)
```

### Liquidating an Undercollateralized Position

```clarity
;; Liquidate a user's position
(contract-call? .collateral-vault liquidate 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)
```

## Security Considerations

### Risks

1. **Oracle Risk**: The contract relies on accurate price feeds. Malicious or incorrect price data could lead to improper liquidations or excessive borrowing.
2. **Smart Contract Risk**: As with any smart contract, there is a risk of bugs or vulnerabilities in the code.
3. **Liquidation Risk**: Users' collateral can be liquidated if their positions fall below the liquidation threshold.
4. **Market Risk**: Rapid price fluctuations could lead to widespread liquidations.

### Best Practices for Users

1. **Maintain Safe Collateral Ratios**: Keep your collateral ratio well above the liquidation threshold to avoid being liquidated during market volatility.
2. **Monitor Your Position**: Regularly check your vault's health and add collateral or repay debt as needed.
3. **Understand the Risks**: Only borrow amounts you can comfortably manage and repay.

## Deployment Guide

### Prerequisites

- Clarity CLI tools installed
- A Stacks wallet with sufficient STX for deployment

### Deployment Steps

1. **Compile the Contract**
2. **Deploy to Testnet**
3. **Deploy to Mainnet**

### Post-Deployment Setup

After deployment, the contract owner should:

1. Set up initial price feeds
2. Configure any other protocol parameters as needed.

## Contributing

1. Fork the repository
2. Create your feature branch
3. Commit your changes
5. Open a Pull Request