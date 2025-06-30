;; LiquidityForge: Advanced DeFi Lending Protocol with Dynamic Yield Calculations

(define-fungible-token forge-token)

;; Storage for liquidity provider positions with enhanced yield tracking
(define-map liquidity-positions 
  {provider: principal} 
  {
    deposited-amount: uint, 
    yield-rate: uint, 
    last-compound-block: uint,
    lifetime-earnings: uint
  }
)

(define-map debt-positions
  {borrower: principal}
  {
    principal-owed: uint, 
    security-deposit: uint, 
    borrow-rate: uint,
    last-compound-block: uint,
    lifetime-interest-owed: uint
  }
)

;; Protocol Configuration
(define-constant protocol-owner tx-sender)
(define-constant min-security-ratio u150) ;; 150% collateral requirement
(define-constant foundation-yield-rate u5) ;; 5% base annual yield rate
(define-constant max-borrowing-ratio u70) ;; 70% maximum loan-to-collateral ratio
(define-constant annual-block-count u525600) ;; Approximate blocks per year

;; Protocol Errors
(define-constant err-insufficient-funds (err u1))
(define-constant err-inadequate-collateral (err u2))
(define-constant err-excessive-borrowing (err u3))
(define-constant err-access-denied (err u4))
(define-constant err-yield-computation-failed (err u5))

;; Calculate Dynamic Yield/Interest
(define-private (compute-yield-interest 
  (base-amount uint) 
  (annual-rate uint) 
  (last-compound-block uint)
)
  (let 
    (
      ;; Calculate blocks elapsed since last compounding
      (blocks-passed (- block-height last-compound-block))
      
      ;; Calculate yield/interest proportional to time passed
      ;; Annual rate divided by blocks per year, multiplied by blocks elapsed
      (yield-amount 
        (/ 
          (* base-amount annual-rate blocks-passed) 
          (* annual-block-count u100)
        )
      )
    )
    
    ;; Return calculated yield/interest
    yield-amount
  )
)

;; Update Liquidity Provider Position with Accrued Yield
(define-public (compound-liquidity-yield (provider principal))
  (let 
    ((current-position (unwrap! (map-get? liquidity-positions {provider: provider}) err-insufficient-funds))
     (current-deposit (get deposited-amount current-position))
     (current-yield-rate (get yield-rate current-position))
     (last-compound-block (get last-compound-block current-position))
     
     ;; Calculate new yield
     (earned-yield 
       (compute-yield-interest 
         current-deposit 
         current-yield-rate 
         last-compound-block
       )
     )
    )
    
    ;; Update position with new yield and current block
    (map-set liquidity-positions 
      {provider: provider}
      {
        deposited-amount: (+ current-deposit earned-yield),
        yield-rate: current-yield-rate,
        last-compound-block: block-height,
        lifetime-earnings: 
          (+ 
            (get lifetime-earnings current-position) 
            earned-yield
          )
      }
    )
    
    (ok true)
  )
)

;; Update Debt Position with Accrued Interest
(define-public (compound-debt-interest (borrower principal))
  (let 
    ((current-debt (unwrap! (map-get? debt-positions {borrower: borrower}) err-access-denied))
     (current-principal (get principal-owed current-debt))
     (current-borrow-rate (get borrow-rate current-debt))
     (last-compound-block (get last-compound-block current-debt))
     
     ;; Calculate new interest
     (accrued-interest 
       (compute-yield-interest 
         current-principal 
         current-borrow-rate 
         last-compound-block
       )
     )
    )
    
    ;; Update debt position with new interest
    (map-set debt-positions 
      {borrower: borrower}
      {
        principal-owed: (+ current-principal accrued-interest),
        security-deposit: (get security-deposit current-debt),
        borrow-rate: current-borrow-rate,
        last-compound-block: block-height,
        lifetime-interest-owed: 
          (+ 
            (get lifetime-interest-owed current-debt) 
            accrued-interest
          )
      }
    )
    
    (ok true)
  )
)

;; Existing deposit function - now compounds yield before deposit
(define-public (provide-liquidity (amount uint))
  (begin
    ;; Compound any existing position first
    (try! (compound-liquidity-yield tx-sender))
    
    ;; Transfer tokens to protocol
    (try! (ft-transfer? forge-token amount tx-sender (as-contract tx-sender)))
    
    ;; Update liquidity positions with current block
    (map-set liquidity-positions 
      {provider: tx-sender} 
      {
        deposited-amount: amount, 
        yield-rate: foundation-yield-rate,
        last-compound-block: block-height,
        lifetime-earnings: u0
      }
    )
    
    (ok true)
  )
)

;; Liquidity Withdrawal Function
(define-public (withdraw-liquidity (amount uint))
  (let 
    (
      ;; Compound the provider's position to accrue latest yield
      (compounded-position (try! (compound-liquidity-yield tx-sender)))
      
      ;; Retrieve the current liquidity position
      (current-position 
        (unwrap! 
          (map-get? liquidity-positions {provider: tx-sender}) 
          err-insufficient-funds
        )
      )
      
      ;; Get the current total amount (principal + accumulated yield)
      (current-total-liquidity (get deposited-amount current-position))
    )
    
    ;; Validate withdrawal amount
    (asserts! (<= amount current-total-liquidity) err-insufficient-funds)
    
    ;; Update the liquidity position
    (map-set liquidity-positions 
      {provider: tx-sender}
      {
        deposited-amount: (- current-total-liquidity amount),
        yield-rate: (get yield-rate current-position),
        last-compound-block: block-height,
        lifetime-earnings: (get lifetime-earnings current-position)
      }
    )
    
    ;; Transfer tokens back to the provider
    (try! 
      (as-contract 
        (ft-transfer? forge-token amount tx-sender tx-sender)
      )
    )
    
    (ok true)
  )
)

;; Partial Debt Settlement Function
(define-public (settle-partial-debt (payment-amount uint))
  (let 
    (
      ;; Compound the borrower's debt to accrue latest interest
      (compounded-debt (try! (compound-debt-interest tx-sender)))
      
      ;; Retrieve the current debt position
      (current-debt 
        (unwrap! 
          (map-get? debt-positions {borrower: tx-sender}) 
          err-access-denied
        )
      )
      
      ;; Get the current total owed amount (principal + accrued interest)
      (current-total-owed (get principal-owed current-debt))
      
      ;; Calculate remaining balance after payment
      (remaining-debt 
        (if (>= current-total-owed payment-amount)
            (- current-total-owed payment-amount)
            u0
        )
      )
    )
    
    ;; Validate payment amount
    (asserts! (> payment-amount u0) err-insufficient-funds)
    (asserts! (<= payment-amount current-total-owed) err-excessive-borrowing)
    
    ;; Transfer tokens from borrower to protocol
    (try! 
      (ft-transfer? forge-token payment-amount tx-sender (as-contract tx-sender))
    )
    
    ;; Update the debt position
    (map-set debt-positions 
      {borrower: tx-sender}
      {
        principal-owed: remaining-debt,
        security-deposit: (get security-deposit current-debt),
        borrow-rate: (get borrow-rate current-debt),
        last-compound-block: block-height,
        lifetime-interest-owed: (get lifetime-interest-owed current-debt)
      }
    )
    
    (ok true)
  )
)

;; Function to Increase Collateral
(define-public (boost-security-deposit (additional-collateral uint))
  (let 
    (
      ;; Retrieve the current debt position
      (current-debt 
        (unwrap! 
          (map-get? debt-positions {borrower: tx-sender}) 
          err-access-denied
        )
      )
      
      ;; Calculate new total collateral
      (enhanced-collateral 
        (+ 
          (get security-deposit current-debt) 
          additional-collateral
        )
      )
      
      ;; Retrieve current principal owed (with accrued interest)
      (current-principal 
        (get principal-owed current-debt)
      )
    )
    
    ;; Validate collateral addition
    (asserts! (> additional-collateral u0) err-insufficient-funds)
    
    ;; Transfer collateral tokens to protocol
    (try! 
      (ft-transfer? forge-token additional-collateral tx-sender (as-contract tx-sender))
    )
    
    ;; Check collateralization ratio after addition
    (asserts! 
      (>= 
        (/ (* enhanced-collateral u100) current-principal) 
        min-security-ratio
      ) 
      err-inadequate-collateral
    )
    
    ;; Update debt position with new collateral
    (map-set debt-positions 
      {borrower: tx-sender}
      {
        principal-owed: current-principal,
        security-deposit: enhanced-collateral,
        borrow-rate: (get borrow-rate current-debt),
        last-compound-block: block-height,
        lifetime-interest-owed: (get lifetime-interest-owed current-debt)
      }
    )
    
    (ok true)
  )
)

;; Function to Reduce Collateral
(define-public (reduce-security-deposit (collateral-reduction uint))
  (let 
    (
      ;; Compound debt to accrue latest interest
      (compounded-debt (try! (compound-debt-interest tx-sender)))
      
      ;; Retrieve the current debt position
      (current-debt 
        (unwrap! 
          (map-get? debt-positions {borrower: tx-sender}) 
          err-access-denied
        )
      )
      
      ;; Calculate new total collateral
      (current-total-collateral (get security-deposit current-debt))
      
      ;; Ensure enough collateral remains
      (reduced-collateral (- current-total-collateral collateral-reduction))
      
      ;; Get current principal owed (with accrued interest)
      (current-principal 
        (get principal-owed current-debt)
      )
    )
    
    ;; Validate collateral reduction
    (asserts! (> collateral-reduction u0) err-insufficient-funds)
    (asserts! (<= collateral-reduction current-total-collateral) err-inadequate-collateral)
    
    ;; Check collateralization ratio after reduction
    (asserts! 
      (>= 
        (/ (* reduced-collateral u100) current-principal) 
        min-security-ratio
      ) 
      err-inadequate-collateral
    )
    
    ;; Update debt position with reduced collateral
    (map-set debt-positions 
      {borrower: tx-sender}
      {
        principal-owed: current-principal,
        security-deposit: reduced-collateral,
        borrow-rate: (get borrow-rate current-debt),
        last-compound-block: block-height,
        lifetime-interest-owed: (get lifetime-interest-owed current-debt)
      }
    )
    
    ;; Transfer collateral tokens back to borrower
    (try! 
      (as-contract 
        (ft-transfer? forge-token collateral-reduction tx-sender tx-sender)
      )
    )
    
    (ok true)
  )
)

;; Function to Liquidate Undercollateralized Positions
(define-public (execute-liquidation (target-borrower principal))
  (let 
    (
      ;; Compound debt to accrue latest interest
      (compounded-debt (try! (compound-debt-interest target-borrower)))
      
      ;; Retrieve the debt position to be liquidated
      (target-debt 
        (unwrap! 
          (map-get? debt-positions {borrower: target-borrower}) 
          err-access-denied
        )
      )
      
      ;; Current principal owed and collateral
      (current-principal (get principal-owed target-debt))
      (current-collateral (get security-deposit target-debt))
      
      ;; Calculate current collateralization ratio
      (current-security-ratio 
        (/ (* current-collateral u100) current-principal)
      )
    )
    
    ;; Ensure the position is undercollateralized
    (asserts! (< current-security-ratio min-security-ratio) err-inadequate-collateral)
    
    ;; Ensure only authorized liquidator (protocol owner) can trigger liquidation
    (asserts! (is-eq tx-sender protocol-owner) err-access-denied)
    
    ;; Transfer remaining collateral to protocol owner
    (try! 
      (as-contract 
        (ft-transfer? forge-token current-collateral tx-sender protocol-owner)
      )
    )
    
    ;; Remove the liquidated debt position
    (map-delete debt-positions {borrower: target-borrower})
    
    (ok true)
  )
)