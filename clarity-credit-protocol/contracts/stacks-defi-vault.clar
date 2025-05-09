;; A smart contract that allows users to deposit assets as collateral and borrow against them

;; Error codes
(define-constant ERR_UNAUTHORIZED u1)
(define-constant ERR_INSUFFICIENT_COLLATERAL u2)
(define-constant ERR_INSUFFICIENT_LIQUIDITY u3)
(define-constant ERR_VAULT_UNDERCOLLATERALIZED u4)
(define-constant ERR_NO_VAULT u5)
(define-constant ERR_VAULT_ALREADY_EXISTS u6)
(define-constant ERR_INVALID_AMOUNT u7)
(define-constant ERR_LIQUIDATION_FAILED u8)
(define-constant ERR_MAX_FEE_EXCEEDED u9)
(define-constant ERR_ZERO_AMOUNT u10)

;; Constants
(define-constant COLLATERAL_RATIO u150) ;; 150% collateralization ratio
(define-constant LIQUIDATION_RATIO u130) ;; 130% liquidation threshold
(define-constant MAX_UINT u340282366920938463463374607431768211455) ;; Maximum possible uint value

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-collateral uint u0)
(define-data-var total-debt uint u0)
(define-data-var vault-count uint u0)
(define-data-var protocol-fee-percent uint u1) ;; 1% fee

;; Maps
(define-map vaults
  { owner: principal }
  {
    collateral-amount: uint,
    debt-amount: uint,
    last-update: uint
  }
)

(define-map price-feeds
  { asset: (string-ascii 32) }
  { price: uint }
)

;; Read-only functions
(define-read-only (get-vault (owner principal))
  (map-get? vaults { owner: owner })
)

(define-read-only (get-collateral-ratio (owner principal))
  (let (
    (vault (get-vault owner))
  )
  (if (is-none vault)
    u0  ;; Return 0 if vault doesn't exist
    (let (
      (unwrapped-vault (unwrap-panic vault))
      (collateral-value (* (get collateral-amount unwrapped-vault) (get-stx-price)))
      (debt-amount (get debt-amount unwrapped-vault))
    )
    (if (is-eq debt-amount u0)
      u0
      (/ (* collateral-value u100) debt-amount)
    )))
  )
)

(define-read-only (get-stx-price)
  (default-to u100 (get price (map-get? price-feeds { asset: "STX" })))
)

(define-read-only (get-max-borrow-amount (owner principal))
  (let (
    (vault (get-vault owner))
  )
  (if (is-none vault)
    u0  ;; Return 0 if vault doesn't exist
    (let (
      (unwrapped-vault (unwrap-panic vault))
      (collateral-value (* (get collateral-amount unwrapped-vault) (get-stx-price)))
    )
    (/ (* collateral-value u100) COLLATERAL_RATIO)
    ))
  )
)

;; Public functions
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

(define-public (deposit-collateral (amount uint))
  (let (
    (owner tx-sender)
    (vault (unwrap! (get-vault owner) (err ERR_NO_VAULT)))
    (current-collateral (get collateral-amount vault))
  )
  ;; Validate the amount is greater than zero
  (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
  
  ;; Check for potential overflow
  (asserts! (<= (+ current-collateral amount) MAX_UINT) (err ERR_INVALID_AMOUNT))
  
  ;; Also check total-collateral for overflow
  (asserts! (<= (+ (var-get total-collateral) amount) MAX_UINT) (err ERR_INVALID_AMOUNT))
  
  ;; Transfer STX from user to contract
  (try! (stx-transfer? amount owner (as-contract tx-sender)))
  
  ;; Update vault
  (map-set vaults
    { owner: owner }
    {
      collateral-amount: (+ current-collateral amount),
      debt-amount: (get debt-amount vault),
      last-update: block-height
    }
  )
  
  ;; Update total collateral
  (var-set total-collateral (+ (var-get total-collateral) amount))
  (ok true))
)

(define-public (withdraw-collateral (amount uint))
  (let (
    (owner tx-sender)
    (vault (unwrap! (get-vault owner) (err ERR_NO_VAULT)))
    (current-collateral (get collateral-amount vault))
    (current-debt (get debt-amount vault))
  )
    ;; Validate the amount is greater than zero
    (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
    
    ;; Assert user has enough collateral
    (asserts! (<= amount current-collateral) (err ERR_INSUFFICIENT_COLLATERAL))
    
    ;; Calculate new values
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
      (ok true)
    ))
)

(define-public (borrow (amount uint))
  (let (
    (owner tx-sender)
    (vault (unwrap! (get-vault owner) (err ERR_NO_VAULT)))
    (current-collateral (get collateral-amount vault))
    (current-debt (get debt-amount vault))
  )
  ;; Validate the amount is greater than zero
  (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
  
  ;; Check for potential overflow
  (asserts! (<= (+ current-debt amount) MAX_UINT) (err ERR_INVALID_AMOUNT))
  
  ;; Calculate borrowing limits
  (let (
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
    (ok true)
  ))
)

(define-public (repay (amount uint))
  (let (
    (owner tx-sender)
    (vault (unwrap! (get-vault owner) (err ERR_NO_VAULT)))
    (current-debt (get debt-amount vault))
  )
  ;; Validate the amount is greater than zero
  (asserts! (> amount u0) (err ERR_ZERO_AMOUNT))
  
  ;; Calculate repayment details
  (let (
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
    (ok true)
  ))
)

(define-public (liquidate (user principal))
  (let (
    (liquidator tx-sender)
    (vault (unwrap! (get-vault user) (err ERR_NO_VAULT)))
    (collateral-amount (get collateral-amount vault))
    (debt-amount (get debt-amount vault))
  )
  ;; Validate the vault has collateral and debt
  (asserts! (> collateral-amount u0) (err ERR_INVALID_AMOUNT))
  (asserts! (> debt-amount u0) (err ERR_INVALID_AMOUNT))
  
  ;; Calculate ratio
  (let (
    (collateral-value (* collateral-amount (get-stx-price)))
    (ratio (/ (* collateral-value u100) debt-amount))
  )
    ;; Check if vault is below liquidation threshold
    (asserts! (< ratio LIQUIDATION_RATIO) (err ERR_LIQUIDATION_FAILED))
    
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
    (ok true)
  ))
)

;; Admin functions
(define-public (set-price-feed (asset (string-ascii 32)) (price uint))
  (begin
    ;; Check authorization
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
    
    ;; Validate price is greater than zero
    (asserts! (> price u0) (err ERR_ZERO_AMOUNT))
    
    ;; Validate asset name is not empty
    (asserts! (> (len asset) u0) (err ERR_INVALID_AMOUNT))
    
    ;; Use a local variable to avoid the warning
    (let ((validated-asset asset))
      ;; Set the price feed
      (map-set price-feeds { asset: validated-asset } { price: price })
      (ok true))
  )
)

(define-public (set-protocol-fee (new-fee uint))
  (begin
    ;; Check authorization
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
    
    ;; Max fee 10%
    (asserts! (<= new-fee u10) (err ERR_MAX_FEE_EXCEEDED))
    
    ;; Set fee
    (var-set protocol-fee-percent new-fee)
    (ok true))
)

(define-public (transfer-ownership (new-owner principal))
  (begin
    ;; Check authorization
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR_UNAUTHORIZED))
    
    ;; Ensure new-owner is not null (in Clarity principals cannot be null, but for clarity)
    (asserts! (not (is-eq new-owner 'SP000000000000000000002Q6VF78)) (err ERR_UNAUTHORIZED))
    
    ;; Transfer ownership
    (var-set contract-owner new-owner)
    (ok true))
)