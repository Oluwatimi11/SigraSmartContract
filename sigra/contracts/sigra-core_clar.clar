;; Sigra Multisig Wallet Smart Contract
;; This contract implements a multi-signature wallet that requires M-of-N signatures to execute transactions.

;; ===============================================
;; Constants and Error Codes
;; ===============================================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant CONTRACT_ADDRESS (as-contract tx-sender))

;; Error codes - prefixed by category for better organization
;; Authorization errors (100-119)
(define-constant ERROR_NOT_AUTHORIZED (err u100))
(define-constant ERROR_NOT_CONTRACT_CALL (err u101))
(define-constant ERROR_NOT_OWNER (err u102))
(define-constant ERROR_CONTRACT_ALREADY_INITIALIZED (err u103))

;; Member management errors (120-139)
(define-constant ERROR_INVALID_SIGNER_THRESHOLD (err u120))
(define-constant ERROR_INVALID_WALLET_MEMBER (err u121))
(define-constant ERROR_MEMBER_ALREADY_EXISTS (err u122))
(define-constant ERROR_MEMBER_DOES_NOT_EXIST (err u123))
(define-constant ERROR_CANNOT_REMOVE_LAST_MEMBER (err u124))
(define-constant ERROR_EMPTY_MEMBER_LIST (err u125))

;; Transaction errors (140-159)
(define-constant ERROR_INSUFFICIENT_SIGNATURES (err u140))
(define-constant ERROR_INVALID_SIGNATURE_FORMAT (err u141))
(define-constant ERROR_TRANSACTION_EXECUTION_FAILED (err u142))
(define-constant ERROR_TRANSACTION_ID_NOT_FOUND (err u143))
(define-constant ERROR_DUPLICATE_SIGNATURE (err u144))
(define-constant ERROR_TRANSACTION_EXPIRED (err u145))
(define-constant ERROR_INVALID_DEADLINE (err u146))
(define-constant ERROR_INVALID_RECIPIENT (err u147))
(define-constant ERROR_INVALID_AMOUNT (err u148))

;; Time-lock errors (160-179)
(define-constant ERROR_TIME_LOCK_ACTIVE (err u160))
(define-constant ERROR_INVALID_TIME_LOCK (err u161))
(define-constant ERROR_NOT_TIME_LOCKED (err u162))

;; Fund management errors (180-199)
(define-constant ERROR_INSUFFICIENT_FUNDS (err u180))
(define-constant ERROR_FUND_TRANSFER_FAILED (err u181))
(define-constant ERROR_ZERO_AMOUNT (err u182))

;; ===============================================
;; Data Variables
;; ===============================================

;; Contract state management
(define-data-var contract-initialized bool false)

;; Wallet membership tracking
(define-map wallet-members principal bool)
(define-data-var member-count uint u0)
(define-data-var signature-threshold uint u0)

;; Transaction management
(define-data-var tx-counter uint u0)
(define-map pending-transactions 
  { transaction-id: uint } 
  {
    recipient: principal,
    stx-amount: uint,
    contract-to-call: (optional principal),
    function-name: (optional (string-ascii 128)),
    deadline: uint,
    approval-count: uint,
    is-executed: bool,
    is-cancelled: bool,
    time-lock: uint,
    proposer: principal,
    created-at: uint
  }
)

;; Track signatures for each transaction
(define-map transaction-approvals 
  { transaction-id: uint, approver: principal } 
  { 
    has-approved: bool,
    approved-at: uint
  }
)

;; ===============================================
;; Helper Functions
;; ===============================================

;; Helper function to check if contract has been initialized
(define-private (is-initialized)
  (var-get contract-initialized)
)

;; Helper function to check if called by contract owner
(define-private (is-owner)
  (is-eq tx-sender CONTRACT_OWNER)
)

;; Helper function to check if a principal is a wallet member
(define-private (is-wallet-member (address principal))
  (default-to false (map-get? wallet-members address))
)

;; Helper function to check if called by the contract itself
(define-private (is-self-call)
  (is-eq tx-sender CONTRACT_ADDRESS)
)

;; Helper function to add a member during initialization
(define-private (add-member-internal (wallet-member principal))
  (begin
    ;; Check if member already exists - if so, skip
    (if (is-wallet-member wallet-member)
      false
      (begin
        ;; Add the member
        (map-set wallet-members wallet-member true)
        (var-set member-count (+ (var-get member-count) u1))
        true
      )
    )
  )
)

;; Execute a transaction that has received enough approvals
(define-private (execute-transaction-internal (transaction-id uint))
  (let
    (
      (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
      (recipient-principal (get recipient transaction))
    )
    ;; Check that the transaction hasn't been executed or cancelled
    (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    (asserts! (not (get is-cancelled transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    
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
      (begin
        ;; Check that we have enough funds
        (asserts! (>= (stx-get-balance CONTRACT_ADDRESS) (get stx-amount transaction)) ERROR_INSUFFICIENT_FUNDS)
        ;; Transfer STX to the recipient
        (match (as-contract (stx-transfer? (get stx-amount transaction) CONTRACT_ADDRESS recipient-principal))
          success (ok true)
          error ERROR_FUND_TRANSFER_FAILED
        )
      )
      ;; No STX transfer, just return success for contract calls
      (ok true)
    )
  )
)

;; ===============================================
;; Initialization Functions
;; ===============================================

;; Initialize contract with member list and threshold
(define-public (initialize (member-list (list 20 principal)) (required-approvals uint))
  (begin
    ;; Only contract owner can initialize
    (asserts! (is-owner) ERROR_NOT_AUTHORIZED)
    
    ;; Check if already initialized
    (asserts! (not (is-initialized)) ERROR_CONTRACT_ALREADY_INITIALIZED)
    
    ;; Validate member list
    (asserts! (> (len member-list) u0) ERROR_EMPTY_MEMBER_LIST)
    
    ;; Validate signature threshold (must be > 0 and <= number of members)
    (asserts! (and (> required-approvals u0) (<= required-approvals (len member-list))) ERROR_INVALID_SIGNER_THRESHOLD)
    
    ;; Clear any existing data
    (var-set member-count u0)
    (var-set signature-threshold required-approvals)
    
    ;; Add members
    (map add-member-internal member-list)
    
    ;; Check that member count matches expected (no duplicate members)
    (asserts! (>= (var-get member-count) u1) ERROR_EMPTY_MEMBER_LIST)
    
    ;; Mark contract as initialized
    (var-set contract-initialized true)
    
    (ok true)
  )
)

;; ===============================================
;; Membership Management Functions
;; ===============================================

;; Add a new wallet member
(define-public (add-wallet-member (new-member principal))
  (begin
    ;; Must be called through multisig execution
    (asserts! (is-self-call) ERROR_NOT_AUTHORIZED)
    
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Check if member already exists
    (asserts! (not (is-wallet-member new-member)) ERROR_MEMBER_ALREADY_EXISTS)
    
    ;; Add new member
    (map-set wallet-members new-member true)
    (var-set member-count (+ (var-get member-count) u1))
    
    (ok true)
  )
)

;; Remove a wallet member
(define-public (remove-wallet-member (member-to-remove principal))
  (begin
    ;; Must be called through multisig execution
    (asserts! (is-self-call) ERROR_NOT_AUTHORIZED)
    
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Check if member exists
    (asserts! (is-wallet-member member-to-remove) ERROR_MEMBER_DOES_NOT_EXIST)
    
    ;; Prevent removing the last member
    (asserts! (> (var-get member-count) u1) ERROR_CANNOT_REMOVE_LAST_MEMBER)
    
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
    (asserts! (is-self-call) ERROR_NOT_AUTHORIZED)
    
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
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

;; Propose a new STX transfer transaction
(define-public (propose-stx-transfer (recipient principal) (stx-amount uint) (deadline uint))
  (let
    (
      (transaction-id (var-get tx-counter))
      (current-height block-height)
    )
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Only wallet members can propose transactions
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Validate amount
    (asserts! (> stx-amount u0) ERROR_INVALID_AMOUNT)
    
    ;; Validate deadline (must be in the future)
    (asserts! (> deadline current-height) ERROR_INVALID_DEADLINE)
    
    ;; Create new transaction
    (map-set pending-transactions 
      { transaction-id: transaction-id }
      {
        recipient: recipient,
        stx-amount: stx-amount,
        contract-to-call: none,
        function-name: none,
        deadline: deadline,
        approval-count: u0,
        is-executed: false,
        is-cancelled: false,
        time-lock: u0,
        proposer: tx-sender,
        created-at: current-height
      }
    )
    
    ;; Increment transaction counter
    (var-set tx-counter (+ transaction-id u1))
    
    ;; Automatically approve the transaction by the proposer
    (try! (approve-transaction transaction-id))
    
    (ok transaction-id)
  )
)

;; Propose a new contract call transaction
(define-public (propose-contract-call (contract-to-call principal) (function-name (string-ascii 128)) (deadline uint))
  (let
    (
      (transaction-id (var-get tx-counter))
      (current-height block-height)
    )
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Only wallet members can propose transactions
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Validate deadline (must be in the future)
    (asserts! (> deadline current-height) ERROR_INVALID_DEADLINE)
    
    ;; Create new transaction
    (map-set pending-transactions 
      { transaction-id: transaction-id }
      {
        recipient: contract-to-call,
        stx-amount: u0,
        contract-to-call: (some contract-to-call),
        function-name: (some function-name),
        deadline: deadline,
        approval-count: u0,
        is-executed: false,
        is-cancelled: false,
        time-lock: u0,
        proposer: tx-sender,
        created-at: current-height
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
(define-public (propose-time-locked-stx-transfer (recipient principal) (stx-amount uint) (deadline uint) (release-height uint))
  (let
    (
      (transaction-id (var-get tx-counter))
      (current-height block-height)
    )
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Only wallet members can propose transactions
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Validate amount
    (asserts! (> stx-amount u0) ERROR_INVALID_AMOUNT)
    
    ;; Validate deadline (must be in the future)
    (asserts! (> deadline current-height) ERROR_INVALID_DEADLINE)
    
    ;; Validate time-lock (must be in the future and before deadline)
    (asserts! (and (> release-height current-height) (<= release-height deadline)) ERROR_INVALID_TIME_LOCK)
    
    ;; Create new time-locked transaction
    (map-set pending-transactions 
      { transaction-id: transaction-id }
      {
        recipient: recipient,
        stx-amount: stx-amount,
        contract-to-call: none,
        function-name: none,
        deadline: deadline,
        approval-count: u0,
        is-executed: false,
        is-cancelled: false,
        time-lock: release-height,
        proposer: tx-sender,
        created-at: current-height
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
      (current-height block-height)
    )
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Only wallet members can approve
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Check that the transaction hasn't been executed or cancelled
    (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    (asserts! (not (get is-cancelled transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    
    ;; Check that the transaction hasn't expired
    (asserts! (<= current-height (get deadline transaction)) ERROR_TRANSACTION_EXPIRED)
    
    ;; Check that the approver hasn't already approved
    (asserts! (or (is-none (map-get? transaction-approvals approval-key)) 
                 (not (get has-approved (default-to { has-approved: false, approved-at: u0 } (map-get? transaction-approvals approval-key))))) 
             ERROR_DUPLICATE_SIGNATURE)
    
    ;; Record the approval
    (map-set transaction-approvals approval-key { has-approved: true, approved-at: current-height })
    
    ;; Update approval count
    (map-set pending-transactions
      { transaction-id: transaction-id }
      (merge transaction { approval-count: (+ (get approval-count transaction) u1) })
    )
    
    ;; Check if we have enough approvals to execute automatically
    (let
      (
        (new-approval-count (+ (get approval-count transaction) u1))
        (threshold (var-get signature-threshold))
        (time-lock (get time-lock transaction))
      )
      (if (and (>= new-approval-count threshold) 
               (or (is-eq time-lock u0) (>= current-height time-lock)))
        ;; Auto-execute if we have enough approvals and no active time-lock
        (execute-transaction-internal transaction-id)
        ;; Otherwise just record the approval
        (ok true)
      )
    )
  )
)

;; Execute a pending transaction with sufficient approvals
(define-public (execute-transaction (transaction-id uint))
  (begin
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Only wallet members can trigger execution
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    (execute-transaction-internal transaction-id)
  )
)

;; Cancel a transaction
(define-public (cancel-transaction (transaction-id uint))
  (let
    (
      (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
    )
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Only wallet members can cancel
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Check that the transaction hasn't been executed or already cancelled
    (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    (asserts! (not (get is-cancelled transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    
    ;; Special permission: proposer can always cancel their own transactions
    ;; Otherwise, requires multisig approval through contract call
    (asserts! (or (is-eq tx-sender (get proposer transaction)) (is-self-call)) ERROR_NOT_AUTHORIZED)
    
    ;; Mark as cancelled
    (map-set pending-transactions
      { transaction-id: transaction-id }
      (merge transaction { is-cancelled: true })
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
      (current-height block-height)
    )
    (if (is-eq time-lock u0)
      ;; No time-lock
      (ok { has-time-lock: false, release-height: u0, is-released: true, blocks-remaining: u0 })
      ;; Has time-lock
      (ok { 
        has-time-lock: true, 
        release-height: time-lock, 
        is-released: (>= current-height time-lock),
        blocks-remaining: (if (>= current-height time-lock) 
                             u0 
                             (- time-lock current-height))
      })
    )
  )
)

;; Update the time-lock on a transaction (requires multisig approval)
(define-public (update-time-lock (transaction-id uint) (new-release-height uint))
  (begin
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Must be called through multisig execution
    (asserts! (is-self-call) ERROR_NOT_AUTHORIZED)
    
    (let
      (
        (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
        (current-height block-height)
      )
      
      ;; Check that the transaction hasn't been executed or cancelled
      (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
      (asserts! (not (get is-cancelled transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
      
      ;; Validate new time-lock (must be in the future and before deadline)
      (asserts! (and (> new-release-height current-height) (<= new-release-height (get deadline transaction))) ERROR_INVALID_TIME_LOCK)
      
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
      (current-height block-height)
    )
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Only wallet members can trigger execution
    (asserts! (is-wallet-member tx-sender) ERROR_NOT_AUTHORIZED)
    
    ;; Check that the transaction hasn't been executed or cancelled
    (asserts! (not (get is-executed transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    (asserts! (not (get is-cancelled transaction)) ERROR_TRANSACTION_EXECUTION_FAILED)
    
    ;; Check that the transaction hasn't expired
    (asserts! (<= current-height (get deadline transaction)) ERROR_TRANSACTION_EXPIRED)
    
    ;; Check that we have enough approvals
    (asserts! (>= (get approval-count transaction) (var-get signature-threshold)) ERROR_INSUFFICIENT_SIGNATURES)
    
    ;; Check that this is a time-locked transaction
    (asserts! (not (is-eq (get time-lock transaction) u0)) ERROR_NOT_TIME_LOCKED)
    
    ;; Check time-lock - only execute if current block-height is past the time-lock
    (asserts! (>= current-height (get time-lock transaction)) ERROR_TIME_LOCK_ACTIVE)
    
    ;; Execute the transaction
    (execute-transaction-internal transaction-id)
  )
)

;; ===============================================
;; Fund Management Functions
;; ===============================================

;; Deposit STX to the wallet
(define-public (deposit-funds (stx-amount uint))
  (begin
    ;; Amount must be greater than zero
    (asserts! (> stx-amount u0) ERROR_ZERO_AMOUNT)
    
    ;; Transfer STX to the contract
    (match (stx-transfer? stx-amount tx-sender CONTRACT_ADDRESS)
      success (ok true)
      error ERROR_FUND_TRANSFER_FAILED
    )
  )
)

;; Withdraw funds from wallet (requires multisig approval via executing a transaction)
;; This function isn't directly callable - must go through the transaction process
(define-public (withdraw-funds (recipient principal) (stx-amount uint))
  (begin
    ;; Must be called through multisig execution
    (asserts! (is-self-call) ERROR_NOT_AUTHORIZED)
    
    ;; Check if contract initialized
    (asserts! (is-initialized) ERROR_NOT_AUTHORIZED)
    
    ;; Amount must be greater than zero
    (asserts! (> stx-amount u0) ERROR_ZERO_AMOUNT)
    
    ;; Check if we have sufficient funds
    (asserts! (>= (stx-get-balance CONTRACT_ADDRESS) stx-amount) ERROR_INSUFFICIENT_FUNDS)
    
    ;; Transfer STX to the recipient
    (match (as-contract (stx-transfer? stx-amount CONTRACT_ADDRESS recipient))
      success (ok true)
      error ERROR_FUND_TRANSFER_FAILED
    )
  )
)

;; ===============================================
;; Read-Only Functions
;; ===============================================

;; Check if contract is initialized
(define-read-only (get-contract-initialized)
  (var-get contract-initialized)
)

;; Check if an address is a wallet member
(define-read-only (check-member-status (address principal))
  (default-to false (map-get? wallet-members address))
)

;; Get the total number of members
(define-read-only (get-member-count)
  (var-get member-count)
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
    { has-approved: false, approved-at: u0 } 
    (map-get? transaction-approvals { transaction-id: transaction-id, approver: approver })
  )
)

;; Get the total number of transactions ever created
(define-read-only (get-total-transactions)
  (var-get tx-counter)
)

;; Get the current STX balance of the wallet
(define-read-only (get-wallet-balance)
  (stx-get-balance CONTRACT_ADDRESS)
)

;; Get all approvers for a transaction
(define-read-only (get-transaction-approvers (transaction-id uint))
  (let
    (
      (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
    )
    (ok (get approval-count transaction))
  )
)

;; Check if a transaction is executable
(define-read-only (is-transaction-executable (transaction-id uint))
  (let
    (
      (transaction (unwrap! (map-get? pending-transactions { transaction-id: transaction-id }) ERROR_TRANSACTION_ID_NOT_FOUND))
      (current-height block-height)
    )
    (ok (and 
          (not (get is-executed transaction))
          (not (get is-cancelled transaction))
          (<= current-height (get deadline transaction))
          (>= (get approval-count transaction) (var-get signature-threshold))
          (or 
            (is-eq (get time-lock transaction) u0)
            (>= current-height (get time-lock transaction))
          )
        ))
  )
)