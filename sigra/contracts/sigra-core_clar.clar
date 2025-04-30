;; Sigra Multisig Wallet Smart Contract
;; This contract implements a multi-signature wallet that requires M-of-N signatures to execute transactions.

;; ===============================================
;; Constants and Error Codes
;; ===============================================

(define-constant CONTRACT_DEPLOYER tx-sender)
(define-constant ERROR_NOT_AUTHORIZED (err u100))
(define-constant ERROR_INVALID_SIGNER_THRESHOLD (err u101))
(define-constant ERROR_INVALID_WALLET_MEMBER (err u102))
(define-constant ERROR_INSUFFICIENT_SIGNATURES (err u103))
(define-constant ERROR_INVALID_SIGNATURE_FORMAT (err u104))
(define-constant ERROR_TRANSACTION_EXECUTION_FAILED (err u105))
(define-constant ERROR_TRANSACTION_ID_NOT_FOUND (err u106))
(define-constant ERROR_DUPLICATE_SIGNATURE (err u107))
(define-constant ERROR_TRANSACTION_EXPIRED (err u108))
(define-constant ERROR_TIME_LOCK_ACTIVE (err u109))
(define-constant ERROR_INVALID_TIME_LOCK (err u110))

;; ===============================================
;; Data Structures
;; ===============================================

;; Wallet membership tracking
(define-map wallet-members principal bool)
(define-data-var member-count uint u0)
(define-data-var signature-threshold uint u0)
(define-data-var tx-counter uint u0)

;; Transaction structure stored in a map
(define-map pending-transactions 
  { transaction-id: uint } 
  {
    recipient: principal,
    stx-amount: uint,
    call-data: (optional (buff 512)),
    deadline: uint,
    approval-count: uint,
    is-executed: bool,
    time-lock: uint
  }
)

;; Track signatures for each transaction
(define-map transaction-approvals 
  { transaction-id: uint, approver: principal } 
  { has-approved: bool }
)

;; ===============================================
;; Helper Functions
;; ===============================================

;; Helper function to check if a principal is a wallet member
(define-private (is-wallet-member (address principal))
  (default-to false (map-get? wallet-members address))
)

;; Private function to add members during initialization
(define-private (add-member-internal (wallet-member principal))
  (begin
    (map-set wallet-members wallet-member true)
    (var-set member-count (+ (var-get member-count) u1))
    true
  )
)

;; Execute a transaction that has received enough approvals
(define-private (execute-transaction (transaction-id uint))
  (let
    (
      (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
    )
    ;; Check that the transaction hasn't been executed
    (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    
    ;; Check that the transaction hasn't expired
    (asserts! (<= block-height (get deadline transaction)) ERROR_TRANSACTION_EXPIRED)
    
    ;; Check that we have enough approvals
    (asserts! (>= (get approval-count transaction) (var-get signature-threshold)) ERROR_INSUFFICIENT_SIGNATURES)
    
    ;; Check time-lock - only execute if current block-height is past the time-lock
    (asserts! (or (is-eq (get time-lock transaction) u0) (>= block-height (get time-lock transaction))) ERROR_TIME_LOCK_ACTIVE)
    
    ;; Mark as executed
    (map-set pending-transactions
      { transaction-id: transaction-id }
      (merge transaction { is-executed: true })
    )
    
    ;; Execute the transaction
    (if (> (get stx-amount transaction) u0)
      ;; Transfer STX to the recipient
      (as-contract (stx-transfer? (get stx-amount transaction) (as-contract tx-sender) (get recipient transaction)))
      ;; Just a contract call with no STX transfer
      (match (get call-data transaction)
        function-data (as-contract (contract-call? (get recipient transaction) execute function-data))
        (ok true)  ;; No call data, just return success
      )
    )
  )
)

;; ===============================================
;; Initialization Functions
;; ===============================================

;; Initialize contract
(define-public (initialize (member-list (list 20 principal)) (required-approvals uint))
  (begin
    ;; Only contract deployer can initialize
    (asserts! (is-eq tx-sender CONTRACT_DEPLOYER) ERROR_NOT_AUTHORIZED)
    
    ;; Validate signature threshold (must be > 0 and <= number of members)
    (asserts! (and (> required-approvals u0) (<= required-approvals (len member-list))) ERROR_INVALID_SIGNER_THRESHOLD)
    
    ;; Clear any existing data
    (var-set member-count u0)
    (var-set signature-threshold required-approvals)
    
    ;; Add members
    (map add-member-internal member-list)
    
    (ok true)
  )
)

;; ===============================================
;; Membership Management Functions
;; ===============================================

;; Public function to add a new wallet member
(define-public (add-wallet-member (new-member principal))
  (begin
    ;; Must be called through multisig execution
    (asserts! (is-eq tx-sender (as-contract tx-sender)) ERROR_NOT_AUTHORIZED)
    
    ;; Check if member already exists
    (asserts! (is-none (map-get? wallet-members new-member)) ERROR_INVALID_WALLET_MEMBER)
    
    ;; Add new member
    (map-set wallet-members new-member true)
    (var-set member-count (+ (var-get member-count) u1))
    
    (ok true)
  )
)

;; Public function to remove a wallet member
(define-public (remove-wallet-member (member-to-remove principal))
  (begin
    ;; Must be called through multisig execution
    (asserts! (is-eq tx-sender (as-contract tx-sender)) ERROR_NOT_AUTHORIZED)
    
    ;; Check if member exists
    (asserts! (is-some (map-get? wallet-members member-to-remove)) ERROR_INVALID_WALLET_MEMBER)
    
    ;; Remove member
    (map-delete wallet-members member-to-remove)
    (var-set member-count (- (var-get member-count) u1))
    
    ;; Ensure signature threshold is still valid
    (asserts! (<= (var-get signature-threshold) (var-get member-count)) ERROR_INVALID_SIGNER_THRESHOLD)
    
    (ok true)
  )
)

;; Change the required signature threshold
(define-public (update-signature-threshold (new-threshold uint))
  (begin
    ;; Must be called through multisig execution
    (asserts! (is-eq tx-sender (as-contract tx-sender)) ERROR_NOT_AUTHORIZED)
    
    ;; Validate new threshold
    (asserts! (and (> new-threshold u0) (<= new-threshold (var-get member-count))) ERROR_INVALID_SIGNER_THRESHOLD)
    
    ;; Set new threshold
    (var-set signature-threshold new-threshold)
    
    (ok true)
  )
)

;; ===============================================
;; Transaction Management Functions
;; ===============================================

;; Propose a new transaction
(define-public (propose-transaction (recipient principal) (stx-amount uint) (call-data (optional (buff 512))) (deadline uint))
  (let
    (
      (transaction-id (var-get tx-counter))
    )
    ;; Only wallet members can propose transactions
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Validate deadline (must be in the future)
    (asserts! (> deadline block-height) ERROR_TRANSACTION_EXPIRED)
    
    ;; Create new transaction
    (map-set pending-transactions 
      { transaction-id: transaction-id }
      {
        recipient: recipient,
        stx-amount: stx-amount,
        call-data: call-data,
        deadline: deadline,
        approval-count: u0,
        is-executed: false,
        time-lock: u0  ;; Default to no time-lock
      }
    )
    
    ;; Increment transaction counter
    (var-set tx-counter (+ transaction-id u1))
    
    ;; Automatically approve the transaction by the proposer
    (try! (approve-transaction transaction-id))
    
    (ok transaction-id)
  )
)

;; Propose a new time-locked transaction
(define-public (propose-time-locked-transaction (recipient principal) (stx-amount uint) (call-data (optional (buff 512))) (deadline uint) (release-height uint))
  (let
    (
      (transaction-id (var-get tx-counter))
    )
    ;; Only wallet members can propose transactions
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Validate deadline (must be in the future)
    (asserts! (> deadline block-height) ERROR_TRANSACTION_EXPIRED)
    
    ;; Validate time-lock (must be in the future and before deadline)
    (asserts! (and (> release-height block-height) (<= release-height deadline)) ERROR_INVALID_TIME_LOCK)
    
    ;; Create new time-locked transaction
    (map-set pending-transactions 
      { transaction-id: transaction-id }
      {
        recipient: recipient,
        stx-amount: stx-amount,
        call-data: call-data,
        deadline: deadline,
        approval-count: u0,
        is-executed: false,
        time-lock: release-height
      }
    )
    
    ;; Increment transaction counter
    (var-set tx-counter (+ transaction-id u1))
    
    ;; Automatically approve the transaction by the proposer
    (try! (approve-transaction transaction-id))
    
    (ok transaction-id)
  )
)

;; Approve a proposed transaction
(define-public (approve-transaction (transaction-id uint))
  (let
    (
      (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
      (approval-key { transaction-id: transaction-id, approver: tx-sender })
    )
    ;; Only wallet members can approve
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Check that the transaction hasn't been executed
    (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    
    ;; Check that the transaction hasn't expired
    (asserts! (<= block-height (get deadline transaction)) ERROR_TRANSACTION_EXPIRED)
    
    ;; Check that the approver hasn't already approved
    (asserts! (or (is-none (map-get? transaction-approvals approval-key)) 
                 (not (get has-approved (default-to { has-approved: false } (map-get? transaction-approvals approval-key))))) 
             ERROR_DUPLICATE_SIGNATURE)
    
    ;; Record the approval
    (map-set transaction-approvals approval-key { has-approved: true })
    
    ;; Update approval count
    (map-set pending-transactions
      { transaction-id: transaction-id }
      (merge transaction { approval-count: (+ (get approval-count transaction) u1) })
    )
    
    ;; Check if we have enough approvals to execute
    (if (>= (+ (get approval-count transaction) u1) (var-get signature-threshold))
      (execute-transaction transaction-id)
      (ok true)
    )
  )
)

;; Cancel a transaction
(define-public (cancel-transaction (transaction-id uint))
  (let
    (
      (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
    )
    ;; Only wallet members can cancel
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Check that the transaction hasn't been executed
    (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    
    ;; Mark as executed (to prevent future execution)
    (map-set pending-transactions
      { transaction-id: transaction-id }
      (merge transaction { is-executed: true })
    )
    
    (ok true)
  )
)

;; ===============================================
;; Time-Lock Functions
;; ===============================================

;; Get the time-lock status of a transaction
(define-read-only (get-time-lock-status (transaction-id uint))
  (let
    (
      (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
      (time-lock (get time-lock transaction))
    )
    (if (is-eq time-lock u0)
      ;; No time-lock
      (ok { has-time-lock: false, release-height: u0, is-released: true })
      ;; Has time-lock
      (ok { 
        has-time-lock: true, 
        release-height: time-lock, 
        is-released: (>= block-height time-lock),
        blocks-remaining: (if (>= block-height time-lock) 
                             u0 
                             (- time-lock block-height))
      })
    )
  )
)

;; Update the time-lock on a transaction (requires multisig approval)
(define-public (update-time-lock (transaction-id uint) (new-release-height uint))
  (begin
    ;; Must be called through multisig execution
    (asserts! (is-eq tx-sender (as-contract tx-sender)) ERROR_NOT_AUTHORIZED)
    
    (let
      (
        (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
      )
      
      ;; Check that the transaction hasn't been executed
      (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
      
      ;; Validate new time-lock (must be in the future and before deadline)
      (asserts! (and (> new-release-height block-height) (<= new-release-height (get deadline transaction))) ERROR_INVALID_TIME_LOCK)
      
      ;; Update time-lock
      (map-set pending-transactions
        { transaction-id: transaction-id }
        (merge transaction { time-lock: new-release-height })
      )
      
      (ok true)
    )
  )
)

;; Try to manually execute a transaction after time-lock has passed
(define-public (execute-time-locked-transaction (transaction-id uint))
  (let
    (
      (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
    )
    ;; Only wallet members can trigger execution
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Check that the transaction hasn't been executed
    (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    
    ;; Check that the transaction hasn't expired
    (asserts! (<= block-height (get deadline transaction)) ERROR_TRANSACTION_EXPIRED)
    
    ;; Check that we have enough approvals
    (asserts! (>= (get approval-count transaction) (var-get signature-threshold)) ERROR_INSUFFICIENT_SIGNATURES)
    
    ;; Check that this is a time-locked transaction
    (asserts! (not (is-eq (get time-lock transaction) u0)) ERROR_INVALID_TIME_LOCK)
    
    ;; Check time-lock - only execute if current block-height is past the time-lock
    (asserts! (>= block-height (get time-lock transaction)) ERROR_TIME_LOCK_ACTIVE)
    
    ;; Mark as executed
    (map-set pending-transactions
      { transaction-id: transaction-id }
      (merge transaction { is-executed: true })
    )
    
    ;; Execute the transaction
    (if (> (get stx-amount transaction) u0)
      ;; Transfer STX to the recipient
      (as-contract (stx-transfer? (get stx-amount transaction) (as-contract tx-sender) (get recipient transaction)))
      ;; Just a contract call with no STX transfer
      (match (get call-data transaction)
        function-data (as-contract (contract-call? (get recipient transaction) execute function-data))
        (ok true)  ;; No call data, just return success
      )
    )
  )
)

;; ===============================================
;; Fund Management Functions
;; ===============================================

;; Deposit STX to the wallet
(define-public (deposit-funds (stx-amount uint))
  (begin
    (try! (stx-transfer? stx-amount tx-sender (as-contract tx-sender)))
    (ok true)
  )
)

;; ===============================================
;; Read-Only Functions
;; ===============================================

;; Check if an address is a wallet member
(define-read-only (check-member-status (address principal))
  (default-to false (map-get? wallet-members address))
)

;; Get the current signature threshold
(define-read-only (get-signature-threshold)
  (var-get signature-threshold)
)

;; Get details for a specific transaction
(define-read-only (get-transaction-details (transaction-id uint))
  (map-get? pending-transactions { transaction-id: transaction-id })
)

;; Check if a specific member has approved a transaction
(define-read-only (get-approval-status (transaction-id uint) (approver principal))
  (default-to 
    { has-approved: false } 
    (map-get? transaction-approvals { transaction-id: transaction-id, approver: approver })
  )
)

;; Get the total number of transactions ever created
(define-read-only (get-total-transactions)
  (var-get tx-counter)
)

;; Get the current STX balance of the wallet
(define-read-only (get-wallet-balance)
  (stx-get-balance (as-contract tx-sender))
)