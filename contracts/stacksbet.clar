;; Title: StacksBet - Decentralized Bitcoin Price Oracle & Prediction Markets
;; Summary: A trustless, community-driven prediction platform built on Stacks Layer 2
;;          enabling users to stake STX on Bitcoin price movements with automated
;;          settlement and transparent reward distribution.
;;
;; Description: StacksBet revolutionizes Bitcoin prediction markets by leveraging 
;;              Stacks' unique Bitcoin-native capabilities. Users can participate 
;;              in time-bound prediction rounds, staking STX tokens on Bitcoin's 
;;              price direction. Our oracle-based settlement system ensures fair, 
;;              automated payouts while maintaining full decentralization. Winners 
;;              receive proportional rewards from the total pool, creating an 
;;              engaging and profitable DeFi experience directly tied to Bitcoin's 
;;              market dynamics.
;;
;; Features:- Oracle-driven price feeds for accurate settlement
;;          - Proportional reward distribution among winners  
;;          - Configurable market parameters and fee structures
;;          - Anti-manipulation safeguards and minimum stake requirements
;;          - Full Bitcoin Layer 2 integration via Stacks blockchain

;; CONSTANTS & ERROR HANDLING

;; Administrative Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant MAX-FEE-PERCENTAGE u10) ;; 10% maximum platform fee

;; Comprehensive Error Code System
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-NOT-FOUND (err u101))
(define-constant ERR-INVALID-PREDICTION (err u102))
(define-constant ERR-MARKET-CLOSED (err u103))
(define-constant ERR-ALREADY-CLAIMED (err u104))
(define-constant ERR-INSUFFICIENT-BALANCE (err u105))
(define-constant ERR-INVALID-PARAMETER (err u106))
(define-constant ERR-MARKET-NOT-RESOLVED (err u107))
(define-constant ERR-UNAUTHORIZED-ORACLE (err u108))

;; STATE VARIABLES & CONFIGURATION

;; Platform Configuration Variables
(define-data-var oracle-address principal 'ST1PQHQKV0RJXZFY1DGX8MNSNYVE3VGZJSRTPGZGM)
(define-data-var minimum-stake uint u1000000) ;; 1 STX minimum (1,000,000 microSTX)
(define-data-var platform-fee-rate uint u250) ;; 2.5% platform fee (250 basis points)
(define-data-var market-counter uint u0) ;; Global market identifier counter
(define-data-var total-volume uint u0) ;; Cumulative platform volume tracking

;; CORE DATA STRUCTURES

;; Market State Management
(define-map markets
  uint ;; market-id
  {
    start-price: uint, ;; Bitcoin price at market open (satoshis)
    end-price: uint, ;; Bitcoin price at resolution (satoshis)
    total-up-stake: uint, ;; Total STX staked on bullish predictions
    total-down-stake: uint, ;; Total STX staked on bearish predictions
    start-block: uint, ;; Block height when predictions open
    end-block: uint, ;; Block height when predictions close
    resolution-block: uint, ;; Block height when market was resolved
    resolved: bool, ;; Market resolution status flag
    creator: principal, ;; Market creator address
  }
)

;; User Participation Tracking
(define-map user-predictions
  {
    market-id: uint,
    user: principal,
  }
  {
    prediction-type: (string-ascii 4), ;; "up" or "down" direction
    stake-amount: uint, ;; STX amount staked (microSTX)
    timestamp: uint, ;; Block height of prediction
    claimed: bool, ;; Reward claim status
    potential-payout: uint, ;; Calculated potential winnings
  }
)

;; User Statistics Tracking
(define-map user-stats
  principal
  {
    total-predictions: uint, ;; Total number of predictions made
    total-staked: uint, ;; Lifetime STX staked
    total-won: uint, ;; Total winnings claimed
    win-rate: uint, ;; Win percentage (basis points)
  }
)

;; PUBLIC FUNCTIONS - MARKET MANAGEMENT

;; Create New Bitcoin Price Prediction Market
;; Initializes a new prediction market with specified parameters and validation
(define-public (create-market
    (start-price uint)
    (start-block uint)
    (end-block uint)
  )
  (let (
      (new-market-id (var-get market-counter))
      (current-block stacks-block-height)
    )
    ;; Authorization and parameter validation
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (> end-block start-block) ERR-INVALID-PARAMETER)
    (asserts! (> start-price u0) ERR-INVALID-PARAMETER)
    (asserts! (>= start-block current-block) ERR-INVALID-PARAMETER)
    (asserts! (> (- end-block start-block) u10) ERR-INVALID-PARAMETER)
    ;; Minimum 10 block duration
    ;; Initialize market with comprehensive data structure
    (map-set markets new-market-id {
      start-price: start-price,
      end-price: u0,
      total-up-stake: u0,
      total-down-stake: u0,
      start-block: start-block,
      end-block: end-block,
      resolution-block: u0,
      resolved: false,
      creator: tx-sender,
    })
    ;; Increment global counter for next market
    (var-set market-counter (+ new-market-id u1))
    (ok new-market-id)
  )
)

;; Oracle-Driven Market Resolution
;; Authorized oracle resolves market with final Bitcoin price for settlement
(define-public (resolve-market
    (market-id uint)
    (final-price uint)
  )
  (let (
      (market-data (unwrap! (map-get? markets market-id) ERR-NOT-FOUND))
      (current-block stacks-block-height)
    )
    ;; Oracle authorization and timing validation
    (asserts! (is-eq tx-sender (var-get oracle-address)) ERR-UNAUTHORIZED-ORACLE)
    (asserts! (>= current-block (get end-block market-data)) ERR-MARKET-CLOSED)
    (asserts! (not (get resolved market-data)) ERR-MARKET-CLOSED)
    (asserts! (> final-price u0) ERR-INVALID-PARAMETER)
    ;; Update market with resolution data
    (map-set markets market-id
      (merge market-data {
        end-price: final-price,
        resolution-block: current-block,
        resolved: true,
      })
    )
    (ok true)
  )
)

;; PUBLIC FUNCTIONS - USER PARTICIPATION

;; Submit Price Prediction with Stake
;; Allows users to stake STX tokens on Bitcoin price direction within active markets
(define-public (make-prediction
    (market-id uint)
    (prediction-direction (string-ascii 4))
    (stake-amount uint)
  )
  (let (
      (market-data (unwrap! (map-get? markets market-id) ERR-NOT-FOUND))
      (current-block stacks-block-height)
      (user-balance (stx-get-balance tx-sender))
    )
    ;; Market timing and parameter validation
    (asserts!
      (and
        (>= current-block (get start-block market-data))
        (< current-block (get end-block market-data))
      )
      ERR-MARKET-CLOSED
    )
    (asserts!
      (or (is-eq prediction-direction "up") (is-eq prediction-direction "down"))
      ERR-INVALID-PREDICTION
    )
    (asserts! (>= stake-amount (var-get minimum-stake)) ERR-INVALID-PARAMETER)
    (asserts! (<= stake-amount user-balance) ERR-INSUFFICIENT-BALANCE)
    ;; Execute STX transfer to contract for escrow
    (try! (stx-transfer? stake-amount tx-sender (as-contract tx-sender)))
    ;; Record comprehensive user prediction data
    (map-set user-predictions {
      market-id: market-id,
      user: tx-sender,
    } {
      prediction-type: prediction-direction,
      stake-amount: stake-amount,
      timestamp: current-block,
      claimed: false,
      potential-payout: u0,
    })
    ;; Update market stake totals for proper pool calculation
    (map-set markets market-id
      (merge market-data {
        total-up-stake: (if (is-eq prediction-direction "up")
          (+ (get total-up-stake market-data) stake-amount)
          (get total-up-stake market-data)
        ),
        total-down-stake: (if (is-eq prediction-direction "down")
          (+ (get total-down-stake market-data) stake-amount)
          (get total-down-stake market-data)
        ),
      })
    )
    ;; Update platform volume tracking
    (var-set total-volume (+ (var-get total-volume) stake-amount))
    ;; Update user statistics
    (update-user-stats tx-sender stake-amount)
    (ok true)
  )
)

;; Claim Proportional Winnings from Resolved Markets
;; Enables winners to claim their proportional share of the total prize pool
(define-public (claim-winnings (market-id uint))
  (let (
      (market-data (unwrap! (map-get? markets market-id) ERR-NOT-FOUND))
      (user-prediction (unwrap!
        (map-get? user-predictions {
          market-id: market-id,
          user: tx-sender,
        })
        ERR-NOT-FOUND
      ))
    )
    ;; Resolution and claim status validation
    (asserts! (get resolved market-data) ERR-MARKET-NOT-RESOLVED)
    (asserts! (not (get claimed user-prediction)) ERR-ALREADY-CLAIMED)
    (let (
        ;; Determine winning prediction based on price movement
        (winning-direction (if (> (get end-price market-data) (get start-price market-data))
          "up"
          "down"
        ))
        (total-pool (+ (get total-up-stake market-data) (get total-down-stake market-data)))
        (winning-pool (if (is-eq winning-direction "up")
          (get total-up-stake market-data)
          (get total-down-stake market-data)
        ))
        (user-stake (get stake-amount user-prediction))
      )
      ;; Verify user made winning prediction
      (asserts! (is-eq (get prediction-type user-prediction) winning-direction)
        ERR-INVALID-PREDICTION
      )
      (asserts! (> winning-pool u0) ERR-INVALID-PARAMETER)
      ;; Prevent division by zero
      (let (
          ;; Calculate proportional winnings and platform fees
          (gross-winnings (/ (* user-stake total-pool) winning-pool))
          (platform-fee (/ (* gross-winnings (var-get platform-fee-rate)) u10000))
          (net-payout (- gross-winnings platform-fee))
        )
        ;; Execute payout transfers
        (try! (as-contract (stx-transfer? net-payout (as-contract tx-sender) tx-sender)))
        (try! (as-contract (stx-transfer? platform-fee (as-contract tx-sender) CONTRACT-OWNER)))
        ;; Mark prediction as claimed to prevent double-spending
        (map-set user-predictions {
          market-id: market-id,
          user: tx-sender,
        }
          (merge user-prediction {
            claimed: true,
            potential-payout: net-payout,
          })
        )
        ;; Update user win statistics
        (update-user-win-stats tx-sender net-payout)
        (ok net-payout)
      )
    )
  )
)

;; READ-ONLY FUNCTIONS - DATA QUERIES

;; Retrieve Complete Market Information
;; Returns comprehensive market data including all parameters and current state
(define-read-only (get-market-details (market-id uint))
  (map-get? markets market-id)
)

;; Get User's Specific Prediction Data
;; Returns detailed prediction information for user in specific market
(define-read-only (get-user-prediction-details
    (market-id uint)
    (user-address principal)
  )
  (map-get? user-predictions {
    market-id: market-id,
    user: user-address,
  })
)

;; Calculate Potential Winnings for Active Predictions
;; Estimates potential payout based on current pool ratios
(define-read-only (calculate-potential-winnings
    (market-id uint)
    (user-address principal)
  )
  (let (
      (market-data (unwrap! (map-get? markets market-id) (err u0)))
      (user-prediction (unwrap!
        (map-get? user-predictions {
          market-id: market-id,
          user: user-address,
        })
        (err u0)
      ))
    )
    (let (
        (total-pool (+ (get total-up-stake market-data) (get total-down-stake market-data)))
        (user-stake (get stake-amount user-prediction))
        (relevant-pool (if (is-eq (get prediction-type user-prediction) "up")
          (get total-up-stake market-data)
          (get total-down-stake market-data)
        ))
      )
      (if (> relevant-pool u0)
        (ok (/ (* user-stake total-pool) relevant-pool))
        (ok u0)
      )
    )
  )
)

;; Get Current Platform Statistics
;; Returns overall platform metrics and configuration
(define-read-only (get-platform-stats)
  {
    total-markets: (var-get market-counter),
    total-volume: (var-get total-volume),
    minimum-stake: (var-get minimum-stake),
    platform-fee-rate: (var-get platform-fee-rate),
    oracle-address: (var-get oracle-address),
    contract-balance: (stx-get-balance (as-contract tx-sender)),
  }
)

;; Get User Performance Statistics
;; Returns comprehensive user performance metrics
(define-read-only (get-user-performance (user-address principal))
  (map-get? user-stats user-address)
)

;; Check Market Status and Eligibility
;; Determines if market is accepting predictions
(define-read-only (get-market-status (market-id uint))
  (let (
      (market-data (unwrap! (map-get? markets market-id) (err "Market not found")))
      (current-block stacks-block-height)
    )
    (ok {
      is-active: (and
        (>= current-block (get start-block market-data))
        (< current-block (get end-block market-data))
        (not (get resolved market-data))
      ),
      is-resolved: (get resolved market-data),
      blocks-remaining: (if (< current-block (get end-block market-data))
        (- (get end-block market-data) current-block)
        u0
      ),
    })
  )
)

;; ADMINISTRATIVE FUNCTIONS - PLATFORM MANAGEMENT

;; Update Authorized Oracle Address
;; Changes the oracle address authorized to resolve prediction markets
(define-public (update-oracle-address (new-oracle-address principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (ok (var-set oracle-address new-oracle-address))
  )
)

;; Adjust Minimum Stake Requirements
;; Updates the minimum STX amount required for predictions
(define-public (update-minimum-stake (new-minimum-amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (> new-minimum-amount u0) ERR-INVALID-PARAMETER)
    (asserts! (<= new-minimum-amount u100000000) ERR-INVALID-PARAMETER) ;; Max 100 STX
    (ok (var-set minimum-stake new-minimum-amount))
  )
)

;; Modify Platform Fee Structure
;; Updates the platform fee percentage within acceptable limits
(define-public (update-platform-fee (new-fee-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (<= new-fee-rate u1000) ERR-INVALID-PARAMETER) ;; Maximum 10%
    (ok (var-set platform-fee-rate new-fee-rate))
  )
)

;; Withdraw Accumulated Platform Fees
;; Allows contract owner to withdraw earned platform fees
(define-public (withdraw-platform-fees (withdrawal-amount uint))
  (let ((contract-balance (stx-get-balance (as-contract tx-sender))))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (<= withdrawal-amount contract-balance) ERR-INSUFFICIENT-BALANCE)
    (asserts! (> withdrawal-amount u0) ERR-INVALID-PARAMETER)
    (try! (as-contract (stx-transfer? withdrawal-amount (as-contract tx-sender) CONTRACT-OWNER)))
    (ok withdrawal-amount)
  )
)

;; PRIVATE UTILITY FUNCTIONS

;; Update User Statistical Data
;; Internal function to maintain user participation statistics
(define-private (update-user-stats
    (user-address principal)
    (stake-amount uint)
  )
  (let ((current-stats (default-to {
      total-predictions: u0,
      total-staked: u0,
      total-won: u0,
      win-rate: u0,
    }
      (map-get? user-stats user-address)
    )))
    (map-set user-stats user-address {
      total-predictions: (+ (get total-predictions current-stats) u1),
      total-staked: (+ (get total-staked current-stats) stake-amount),
      total-won: (get total-won current-stats),
      win-rate: (get win-rate current-stats),
    })
  )
)

;; Update User Win Statistics
;; Internal function to update win-related statistics
(define-private (update-user-win-stats
    (user-address principal)
    (payout-amount uint)
  )
  (let ((current-stats (unwrap-panic (map-get? user-stats user-address))))
    (map-set user-stats user-address
      (merge current-stats { total-won: (+ (get total-won current-stats) payout-amount) })
    )
  )
)