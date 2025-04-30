
---

# 🧾 Sigra – Multisig Wallet Smart Contract

**Sigra** is a secure, programmable multi-signature wallet on the **Stacks blockchain**, written in **Clarity**. This smart contract enforces an M-of-N signature policy to authorize fund transfers and smart contract calls, ensuring high levels of decentralization and safety.

**Version:** 1.0

---

## 📌 Features

- ✅ M-of-N multisignature execution model  
- ✅ Supports STX transfers and Clarity contract calls  
- ✅ On-chain transaction proposal, approval, and execution  
- ✅ Time-locks and deadlines for secure, scheduled execution  
- ✅ Wallet member management (add/remove)  
- ✅ Signature threshold configuration  
- ✅ Strong access control and verbose error handling

---

## 🛠️ Initialization

Only the contract deployer (owner) can initialize **Sigra**.

```clarity
(initialize (member-list (list 20 principal)) (required-approvals uint))
```

- `member-list`: Initial wallet members (at least one)
- `required-approvals`: M in M-of-N required to authorize a transaction  
❗ Initialization is one-time only.

---

## 🧑‍🤝‍🧑 Membership Management

All member changes must be executed through the Sigra multisig process.

### ➕ Add a Wallet Member
```clarity
(add-wallet-member (new-member principal))
```

### ➖ Remove a Wallet Member
```clarity
(remove-wallet-member (member-to-remove principal))
```

- Cannot remove the last member  
- Signature threshold must remain valid after changes  

### 🔁 Update Signature Threshold
```clarity
(update-signature-threshold (new-threshold uint))
```

---

## 💸 Transaction Lifecycle

Transactions in Sigra follow a secure multi-step process:

1. **Propose Transaction**  
   *(To be implemented)*  
   ```clarity
   (propose-transaction (recipient principal) (amount uint) (call-data (optional (buff 512))) (deadline uint) (time-lock uint))
   ```

2. **Approve Transaction**  
   *(To be implemented)*  
   Members approve proposals via signature verification.

3. **Execute Transaction**  
   ```clarity
   (execute-transaction (transaction-id uint))
   ```
   - Checks approvals, time-lock, and deadline  
   - Executes STX transfer or Clarity contract call  
   - Prevents replay or double-execution  

---

## ⏳ Time-Locks & Deadlines

Each transaction can specify:
- `time-lock`: Minimum block height before execution  
- `deadline`: Maximum block height for validity  

These protect against premature or stale execution.

---

## ⚠️ Error Codes

Sigra uses categorized, human-readable error codes:

| Category              | Range     | Example                        |
|-----------------------|-----------|--------------------------------|
| Authorization         | 100–119   | `ERR_NOT_AUTHORIZED`           |
| Member Management     | 120–139   | `ERR_MEMBER_ALREADY_EXISTS`    |
| Transaction Logic     | 140–159   | `ERR_INSUFFICIENT_SIGNATURES`  |
| Time-lock Enforcement | 160–179   | `ERR_TIME_LOCK_ACTIVE`         |
| Fund Management       | 180–199   | `ERR_INSUFFICIENT_FUNDS`       |

---

## 🔒 Access Control

- Only the contract owner can initialize  
- Only the contract logic can manage members and thresholds  

---

## 🔧 Internal Logic (Private Functions)

- `is-initialized`: Ensures one-time setup  
- `is-owner`: Validates caller is deployer  
- `is-wallet-member`: Confirms signer identity  
- `add-member-internal`: Safe addition during setup  
- `execute-transaction-internal`: Secure execution handler  

---

## 🧪 Testing Recommendations

Suggested tests:
- Initialization edge cases (e.g., zero members, invalid threshold)  
- Unauthorized member management attempts  
- Approval and execution flow (M-of-N)  
- Time-lock and deadline compliance  
- Double execution prevention  

---

## 🚀 Deployment Notes

- Deploy from a secure principal  
- Initialize **Sigra** immediately post-deployment  
- Avoid using default system principal: `SP000000000000000000002Q6VF78`

---

## 📄 License

**MIT License** – Freely usable with attribution.

---

